//! Just enough property-list reading to answer one question: what version is
//! this framework?
//!
//! D3DMetal's version is the single most important thing to record about an
//! environment — the D3D12 shim is 108 KB in one release and 192 KB in the
//! next, and anything hooking it is pinned to a version whether it knows so or
//! not. So this needs to work on the file Apple actually ships, and Apple
//! ships a *binary* plist: `Info.plist` inside `D3DMetal.framework` begins
//! `bplist00`, not `<?xml`.
//!
//! Both encodings are read here, dispatched on the magic. Neither reader is a
//! general plist parser and neither should become one: the whole requirement
//! is "give me the string value of this top-level key", and everything outside
//! that answers null rather than growing a feature.

const std = @import("std");

const binary_magic = "bplist00";

/// The string value of top-level key `name`, from either plist encoding.
/// Returns a slice into `bytes`.
pub fn stringValue(bytes: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, binary_magic)) return binaryStringValue(bytes, name);
    return xmlStringValue(bytes, name);
}

/// The `<string>` immediately following `<key>name</key>`.
///
/// Whitespace between the two elements is skipped; anything else between them
/// means the key's value is not a string, and null is the right answer.
fn xmlStringValue(xml: []const u8, name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, xml, search, "<key>")) |key_start| {
        const open = key_start + "<key>".len;
        const key_end = std.mem.indexOfPos(u8, xml, open, "</key>") orelse return null;
        search = key_end + "</key>".len;
        if (!std.mem.eql(u8, xml[open..key_end], name)) continue;

        var i = search;
        while (i < xml.len and std.ascii.isWhitespace(xml[i])) i += 1;
        if (!std.mem.startsWith(u8, xml[i..], "<string>")) return null;
        const val = i + "<string>".len;
        const val_end = std.mem.indexOfPos(u8, xml, val, "</string>") orelse return null;
        return xml[val..val_end];
    }
    return null;
}

/// Binary plist v0. The trailer says how wide offsets and references are and
/// where the offset table lives; the top object is a dictionary whose keys and
/// values are two consecutive runs of references.
///
/// Only ASCII strings are returned. A UTF-16 value answers null rather than
/// allocating a converted copy — every version string is ASCII, and a reader
/// that never allocates cannot leak.
fn binaryStringValue(bytes: []const u8, name: []const u8) ?[]const u8 {
    if (bytes.len < binary_magic.len + 32) return null;
    const trailer = bytes[bytes.len - 32 ..];

    const offset_size: usize = trailer[6];
    const ref_size: usize = trailer[7];
    if (offset_size == 0 or offset_size > 8) return null;
    if (ref_size == 0 or ref_size > 8) return null;

    const num_objects = std.mem.readInt(u64, trailer[8..16], .big);
    const top = std.mem.readInt(u64, trailer[16..24], .big);
    const table_off = std.mem.readInt(u64, trailer[24..32], .big);

    const table = struct {
        bytes: []const u8,
        off: u64,
        size: usize,
        count: u64,

        fn offsetOf(self: @This(), index: u64) ?usize {
            if (index >= self.count) return null;
            const at = self.off + index * self.size;
            const end = at + self.size;
            if (end > self.bytes.len) return null;
            return @intCast(readBig(self.bytes[@intCast(at)..@intCast(end)]));
        }
    }{ .bytes = bytes, .off = table_off, .size = offset_size, .count = num_objects };

    const dict = objectAt(bytes, table.offsetOf(top) orelse return null) orelse return null;
    if (dict.kind != 0xD0) return null;

    const keys_at = dict.body;
    const vals_at = keys_at + @as(usize, @intCast(dict.count)) * ref_size;

    var i: usize = 0;
    while (i < dict.count) : (i += 1) {
        const key_ref = refAt(bytes, keys_at + i * ref_size, ref_size) orelse return null;
        const key = asciiAt(bytes, table.offsetOf(key_ref) orelse continue) orelse continue;
        if (!std.mem.eql(u8, key, name)) continue;

        const val_ref = refAt(bytes, vals_at + i * ref_size, ref_size) orelse return null;
        return asciiAt(bytes, table.offsetOf(val_ref) orelse return null);
    }
    return null;
}

const Object = struct {
    /// The marker's high nibble: 0x5 ASCII string, 0xD dictionary, and so on.
    kind: u8,
    /// Element count for a collection, byte length for a string.
    count: u64,
    /// Where the object's contents begin.
    body: usize,
};

fn objectAt(bytes: []const u8, off: usize) ?Object {
    if (off >= bytes.len) return null;
    const marker = bytes[off];
    var count: u64 = marker & 0x0F;
    var body = off + 1;

    // A low nibble of 0xF means the real count is the integer object that
    // follows, whose own low nibble is the log2 of its width.
    if (count == 0x0F) {
        if (body >= bytes.len) return null;
        const int_marker = bytes[body];
        if (int_marker & 0xF0 != 0x10) return null;
        const width = @as(usize, 1) << @intCast(int_marker & 0x0F);
        body += 1;
        if (body + width > bytes.len or width > 8) return null;
        count = readBig(bytes[body .. body + width]);
        body += width;
    }
    return .{ .kind = marker & 0xF0, .count = count, .body = body };
}

fn asciiAt(bytes: []const u8, off: usize) ?[]const u8 {
    const obj = objectAt(bytes, off) orelse return null;
    if (obj.kind != 0x50) return null;
    const end = obj.body + @as(usize, @intCast(obj.count));
    if (end > bytes.len) return null;
    return bytes[obj.body..end];
}

fn refAt(bytes: []const u8, at: usize, size: usize) ?u64 {
    if (at + size > bytes.len) return null;
    return readBig(bytes[at .. at + size]);
}

/// A big-endian integer of 1 to 8 bytes, which is how every width in a binary
/// plist is written.
fn readBig(slice: []const u8) u64 {
    var v: u64 = 0;
    for (slice) |b| v = (v << 8) | b;
    return v;
}

const testing = std.testing;

const xml_sample =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleName</key>
    \\  <string>D3DMetal</string>
    \\  <key>CFBundleShortVersionString</key>
    \\  <string>4.0b2</string>
    \\  <key>DTPlatformVersion</key>
    \\  <string>26.4</string>
    \\</dict>
    \\</plist>
;

/// A real binary plist, produced by `plutil -convert binary1` from the same
/// keys as `xml_sample`. Hand-writing one would test this reader against my
/// idea of the format rather than against Apple's.
const binary_sample_hex =
    "62706c6973743030d401020304050607085f101a434642756e646c6553686f7274" ++
    "56657273696f6e537472696e675f10114454506c6174666f726d56657273696f6e" ++
    "5f1013434642756e646c655061636b616765547970655c434642756e646c654e61" ++
    "6d6555342e3062325432362e3454464d574b584433444d6574616c08112e425865" ++
    "6b707500000000000001010000000000000009000000000000000000000000" ++
    "0000007e";

fn binarySample(buf: []u8) ![]const u8 {
    return try std.fmt.hexToBytes(buf, binary_sample_hex);
}

test "a version is read from the XML encoding" {
    try testing.expectEqualStrings("4.0b2", stringValue(xml_sample, "CFBundleShortVersionString").?);
    try testing.expectEqualStrings("26.4", stringValue(xml_sample, "DTPlatformVersion").?);
    try testing.expectEqualStrings("D3DMetal", stringValue(xml_sample, "CFBundleName").?);
}

test "a version is read from the binary encoding Apple actually ships" {
    var buf: [256]u8 = undefined;
    const bytes = try binarySample(&buf);
    try testing.expect(std.mem.startsWith(u8, bytes, "bplist00"));

    // Long keys use the 0x5F extended-length form; short ones do not. Both
    // appear here, and both must resolve.
    try testing.expectEqualStrings("4.0b2", stringValue(bytes, "CFBundleShortVersionString").?);
    try testing.expectEqualStrings("26.4", stringValue(bytes, "DTPlatformVersion").?);
    try testing.expectEqualStrings("D3DMetal", stringValue(bytes, "CFBundleName").?);
    try testing.expectEqualStrings("FMWK", stringValue(bytes, "CFBundlePackageType").?);
}

test "an absent key answers null in both encodings" {
    var buf: [256]u8 = undefined;
    const bytes = try binarySample(&buf);
    try testing.expectEqual(@as(?[]const u8, null), stringValue(bytes, "CFBundleVersion"));
    try testing.expectEqual(@as(?[]const u8, null), stringValue(xml_sample, "CFBundleVersion"));
}

test "a truncated binary plist answers null rather than reading past its end" {
    var buf: [256]u8 = undefined;
    const bytes = try binarySample(&buf);
    try testing.expectEqual(@as(?[]const u8, null), stringValue(bytes[0 .. bytes.len - 16], "CFBundleName"));
    try testing.expectEqual(@as(?[]const u8, null), stringValue("bplist00", "CFBundleName"));
}

test "a key whose name is a prefix of another does not match it" {
    const both =
        \\<key>CFBundleVersionLong</key>
        \\<string>wrong</string>
        \\<key>CFBundleVersion</key>
        \\<string>right</string>
    ;
    try testing.expectEqualStrings("right", stringValue(both, "CFBundleVersion").?);
}

test "an XML value that is not a string answers null" {
    const not_a_string =
        \\<key>CFBundleDocumentTypes</key>
        \\<array><string>nope</string></array>
    ;
    try testing.expectEqual(@as(?[]const u8, null), stringValue(not_a_string, "CFBundleDocumentTypes"));
}
