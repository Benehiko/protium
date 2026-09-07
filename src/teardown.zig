//! Bringing down the Wine that is running in a prefix.
//!
//! Two things have to be worked out before anything can be signalled: which
//! directory Wine made for this prefix, and which processes belong to it.
//! Both are pure — one is path arithmetic, the other is parsing a buffer the
//! kernel hands back — so both are decided here and tested here. `main.zig`
//! does the opening, the asking and the signalling.

const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

/// Wine puts its per-user directory under `/tmp`, not under `TMPDIR`: the
/// path is compiled in, and on macOS `TMPDIR` is a per-user path already, so
/// Wine would nest one inside the other. Looking anywhere else finds nothing.
pub const tmp_dir = "/tmp";

/// The file the wineserver holds a write lock on for as long as it is
/// running. Asking who owns that lock is how a wineserver is identified
/// without searching the process table for a name.
pub const lock_file = "lock";

/// Wine names the directory for a prefix from the prefix directory's device
/// and inode, in lowercase hex with no padding, inside a per-user directory
/// named from the numeric uid.
///
/// Checked against a running prefix rather than taken from the source: the
/// prefix at `~/.local/share/protium/prefixes/eldenring` has device 16777232
/// and inode 22138619, and the directory Wine had made for it was
/// `/tmp/.wine-501/server-1000010-151cefb`.
pub fn serverDir(
    gpa: std.mem.Allocator,
    tmp: []const u8,
    uid: u32,
    dev: u64,
    ino: u64,
) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/.wine-{d}/server-{x}-{x}", .{ tmp, uid, dev, ino });
}

/// macOS returns a process's arguments and environment as one buffer:
///
///     u32   argc
///     the executable path, NUL-terminated, then NUL padding
///     argc arguments, each NUL-terminated
///     the environment, each NUL-terminated
///
/// Returns the value of `name`, or null when the buffer does not carry it.
/// A truncated buffer — which is what a process whose environment is larger
/// than the size asked for produces — reads as "not carried" rather than as
/// an error, because a process that cannot be identified must not be
/// signalled.
pub fn findEnv(buf: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (buf.len < @sizeOf(u32)) return null;
    const argc = std.mem.readInt(u32, buf[0..4], native_endian);

    // The executable path, and then however many NULs pad it out to the
    // start of the arguments.
    var i = skipString(buf, @sizeOf(u32)) orelse return null;
    while (i < buf.len and buf[i] == 0) i += 1;

    var n: u32 = 0;
    while (n < argc) : (n += 1) i = skipString(buf, i) orelse return null;

    // What is left is the environment, and it runs to the end of the buffer.
    // NUL padding appears between the sections — after the executable path,
    // and again between the last argument and the first variable — so a run
    // of it is stepped over rather than read as the end of the list.
    //
    // Reading it as the end is a quiet failure rather than a loud one: the
    // variable is there, the answer comes back "not carried", and a process
    // that belongs to the prefix looks like somebody else's. That is how a
    // teardown came to report a prefix stopped while Steam was still running.
    while (i < buf.len) {
        while (i < buf.len and buf[i] == 0) i += 1;
        if (i >= buf.len) break;
        // An unterminated entry is the truncated case: stop, and report the
        // variable as not carried rather than matching half of one.
        const end = std.mem.indexOfScalarPos(u8, buf, i, 0) orelse break;
        const entry = buf[i..end];
        if (entry.len > name.len and
            entry[name.len] == '=' and
            std.mem.startsWith(u8, entry, name))
        {
            return entry[name.len + 1 ..];
        }
        i = end + 1;
    }
    return null;
}

/// Step past one NUL-terminated string, returning the index after its
/// terminator. Null when the string is unterminated, which means the buffer
/// was cut short.
fn skipString(buf: []const u8, from: usize) ?usize {
    if (from >= buf.len) return null;
    const end = std.mem.indexOfScalarPos(u8, buf, from, 0) orelse return null;
    return end + 1;
}

/// Whether a process belongs to a prefix. Wine's own rule is the value of
/// `WINEPREFIX`, and it is compared as a path with any trailing separator
/// ignored, because `protium run` and a shell's tab-completion disagree about
/// that one character and both are the same prefix.
pub fn belongsTo(buf: []const u8, prefix_dir: []const u8) bool {
    const have = findEnv(buf, "WINEPREFIX") orelse return false;
    return std.mem.eql(u8, trimSlash(have), trimSlash(prefix_dir));
}

fn trimSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

/// `proc_listallpids` answers with the number of process ids it wrote, not
/// the number of bytes — the two differ by a factor of four, and reading it
/// as bytes silently scans a quarter of the process table and reports the
/// rest as not running.
///
/// Checked on the machine rather than taken from the header: a host with 617
/// processes answered 625 for a buffer of 647 slots, where a byte count would
/// have been near 2500.
///
/// Clamped to the buffer, because the process table can grow between asking
/// how big it is and reading it.
pub fn pidCount(returned: c_int, capacity: usize) usize {
    if (returned <= 0) return 0;
    return @min(@as(usize, @intCast(returned)), capacity);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "serverDir names the directory Wine made" {
    const got = try serverDir(testing.allocator, tmp_dir, 501, 16777232, 22138619);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/tmp/.wine-501/server-1000010-151cefb", got);
}

test "serverDir writes hex in lower case and without padding" {
    const got = try serverDir(testing.allocator, "/tmp", 0, 0xAB, 0xF);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/tmp/.wine-0/server-ab-f", got);
}

/// Build the buffer macOS would return, so the parser is tested against the
/// shape it actually meets: a count, a padded executable path, the arguments,
/// then the environment.
fn procArgs(
    buf: []u8,
    argc: u32,
    exec_path: []const u8,
    pad: usize,
    argv: []const []const u8,
    environ: []const []const u8,
) []const u8 {
    var i: usize = 0;
    std.mem.writeInt(u32, buf[0..4], argc, native_endian);
    i += 4;
    @memcpy(buf[i..][0..exec_path.len], exec_path);
    i += exec_path.len;
    for (0..pad + 1) |_| {
        buf[i] = 0;
        i += 1;
    }
    for ([_][]const []const u8{ argv, environ }) |list| {
        for (list) |s| {
            @memcpy(buf[i..][0..s.len], s);
            i += s.len;
            buf[i] = 0;
            i += 1;
        }
    }
    return buf[0..i];
}

test "findEnv reads a variable past the padding and the arguments" {
    var buf: [512]u8 = undefined;
    const b = procArgs(&buf, 2, "/usr/bin/wine", 7, &.{ "wine", "steam.exe" }, &.{
        "PATH=/usr/bin",
        "WINEPREFIX=/home/a/prefixes/eldenring",
        "WINEMSYNC=1",
    });
    try testing.expectEqualStrings("/home/a/prefixes/eldenring", findEnv(b, "WINEPREFIX").?);
    try testing.expectEqualStrings("1", findEnv(b, "WINEMSYNC").?);
    try testing.expectEqualStrings("/usr/bin", findEnv(b, "PATH").?);
}

test "findEnv does not match a name that is only a prefix of one" {
    var buf: [512]u8 = undefined;
    const b = procArgs(&buf, 1, "/usr/bin/wine", 0, &.{"wine"}, &.{"WINEPREFIX=/a"});
    try testing.expectEqual(@as(?[]const u8, null), findEnv(b, "WINE"));
    try testing.expectEqual(@as(?[]const u8, null), findEnv(b, "WINEPREFIXES"));
}

test "findEnv accepts an empty value" {
    var buf: [512]u8 = undefined;
    const b = procArgs(&buf, 1, "/usr/bin/wine", 0, &.{"wine"}, &.{"WINEDEBUG="});
    try testing.expectEqualStrings("", findEnv(b, "WINEDEBUG").?);
}

test "findEnv reports nothing rather than guessing when the buffer is cut short" {
    var buf: [512]u8 = undefined;
    const b = procArgs(&buf, 1, "/usr/bin/wine", 0, &.{"wine"}, &.{"WINEPREFIX=/home/a/prefixes/eldenring"});

    // Every truncation of a buffer that does carry the variable.
    for (0..b.len) |cut| {
        try testing.expectEqual(@as(?[]const u8, null), findEnv(b[0..cut], "NOTHERE"));
    }
    try testing.expectEqual(@as(?[]const u8, null), findEnv(b[0 .. b.len - 1], "WINEPREFIX"));
    try testing.expectEqual(@as(?[]const u8, null), findEnv(&.{}, "WINEPREFIX"));
}

test "findEnv steps over the padding between the arguments and the environment" {
    // This is the shape a real Wine process has, and the one that was read
    // wrongly: `wine` re-executes itself, so the executable path and the
    // first argument differ, and the kernel pads between the sections. A
    // parser that treats the first empty entry as the end of the list stops
    // before it reaches WINEPREFIX and reports the process as not ours.
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    std.mem.writeInt(u32, buf[0..4], 2, native_endian);
    i += 4;
    for ([_][]const u8{
        "/opt/wine/lib/wine/x86_64-unix/wine", // the executable path
        "", // padding after it
        "wine",
        "C:\\Program Files (x86)\\Steam\\steam.exe",
        "", // padding before the environment
        "",
        "PWD=/home/a",
        "WINEPREFIX=/home/a/prefixes/eldenring",
    }) |s| {
        @memcpy(buf[i..][0..s.len], s);
        i += s.len;
        buf[i] = 0;
        i += 1;
    }
    const b = buf[0..i];
    try testing.expectEqualStrings("/home/a/prefixes/eldenring", findEnv(b, "WINEPREFIX").?);
    try testing.expectEqualStrings("/home/a", findEnv(b, "PWD").?);
}

test "belongsTo compares paths, not spellings" {
    var buf: [512]u8 = undefined;
    const b = procArgs(&buf, 1, "/usr/bin/wine", 0, &.{"wine"}, &.{"WINEPREFIX=/home/a/prefixes/eldenring/"});
    try testing.expect(belongsTo(b, "/home/a/prefixes/eldenring"));
    try testing.expect(belongsTo(b, "/home/a/prefixes/eldenring/"));
    try testing.expect(!belongsTo(b, "/home/a/prefixes/eldenrin"));
    try testing.expect(!belongsTo(b, "/home/a/prefixes/other"));
}

test "belongsTo says no when the process carries no WINEPREFIX" {
    var buf: [512]u8 = undefined;
    const b = procArgs(&buf, 1, "/bin/ls", 0, &.{"ls"}, &.{"PATH=/usr/bin"});
    try testing.expect(!belongsTo(b, "/home/a/prefixes/eldenring"));
}

test "pidCount reads the answer as a count of ids, not of bytes" {
    // The observed answer from a host with 617 processes and a 647-slot
    // buffer. Read as bytes this would be 156, and three quarters of the
    // process table would go unlooked-at.
    try testing.expectEqual(@as(usize, 625), pidCount(625, 647));
}

test "pidCount never runs past the buffer" {
    try testing.expectEqual(@as(usize, 8), pidCount(9, 8));
    try testing.expectEqual(@as(usize, 8), pidCount(8, 8));
}

test "pidCount treats a failure as nothing found" {
    try testing.expectEqual(@as(usize, 0), pidCount(-1, 64));
    try testing.expectEqual(@as(usize, 0), pidCount(0, 64));
}
