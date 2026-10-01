//! D3DMetal, Apple's half of the environment: the shape of the payload in
//! Apple's Game Porting Toolkit, how to recognise the disk images it comes in,
//! and where protium keeps the Wine modules it replaces.
//!
//! The payload is deliberately not described as a fixed file list, because it
//! is not one: D3DMetal 3.0 ships `atidxx64.dll` and `nvngx.dll`, 4.0b2 drops
//! the first, renames the second to `nvngx-on-metalfx.dll` and adds
//! `d3d10.dll`. A checker written against one release would reject the next.
//!
//! What does hold across releases is the *structure*, and that is what is
//! verified here:
//!
//!   * `external/` holds the framework and one shared library;
//!   * every PE shim in `wine/x86_64-windows/` has a unix-side counterpart of
//!     the same stem in `wine/x86_64-unix/`;
//!   * every one of those counterparts is a symlink to the single shared
//!     library, reached by a path relative to its own directory.
//!
//! That last point is why the tree must be installed with its layout intact —
//! `wine/x86_64-unix/d3d12.so` resolves `../../external/libd3dshared.dylib`
//! against where it sits, so flattening the tree breaks every shim at once.

const std = @import("std");

/// Paths within the redistributable's `lib/` directory.
pub const shared_library = "external/libd3dshared.dylib";
pub const framework = "external/D3DMetal.framework";
pub const framework_plist = "external/D3DMetal.framework/Resources/Info.plist";
pub const windows_dir = "wine/x86_64-windows";
pub const unix_dir = "wine/x86_64-unix";

/// A file only a real Wine module tree has. `d3dmetal install` refuses a
/// destination without it, so the payload only ever goes into a runtime.
pub const wine_module_marker = "wine/x86_64-windows/ntdll.dll";

/// Where, inside a runtime's `lib/`, the Wine modules Apple's shims replace
/// are kept: Wine's own `d3d10.dll`, `d3d11.dll`, `d3d12.dll` and `dxgi.dll`.
pub const originals_dir = "wine-d3d-originals";

/// Apple's download, as it lands in ~/Downloads:
/// `Game_Porting_Toolkit_4.0_beta_2.dmg`.
pub fn isToolkitImage(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "Game_Porting_Toolkit") and std.mem.endsWith(u8, name, ".dmg");
}

/// The image inside the toolkit's that holds the payload:
/// `Evaluation environment for Windows games 4.0 beta 2.dmg`. It carries
/// Apple's licence agreement, which `hdiutil` asks the person to accept.
pub fn isEvaluationImage(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "Evaluation environment") and std.mem.endsWith(u8, name, ".dmg");
}

pub const Choice = union(enum) {
    none,
    one: []const u8,
    /// More than one: which is wanted is the person's to say, not a guess.
    several,
};

/// Which of a directory's entries is the toolkit image to use.
pub fn chooseToolkit(names: []const []const u8) Choice {
    var found: ?[]const u8 = null;
    for (names) |n| {
        if (!isToolkitImage(n)) continue;
        if (found != null) return .several;
        found = n;
    }
    return if (found) |n| .{ .one = n } else .none;
}

/// What every unix-side shim must point at, relative to `unix_dir`.
pub const symlink_target = "../../external/libd3dshared.dylib";

/// `d3d12.dll` names `d3d12.so`. Written into `buf`, which must hold the
/// stem plus three bytes.
pub fn unixCounterpart(dll: []const u8, buf: []u8) error{ NotADll, NoSpace }![]const u8 {
    if (!std.mem.endsWith(u8, dll, ".dll")) return error.NotADll;
    const stem = dll[0 .. dll.len - ".dll".len];
    if (stem.len + ".so".len > buf.len) return error.NoSpace;
    @memcpy(buf[0..stem.len], stem);
    @memcpy(buf[stem.len..][0..".so".len], ".so");
    return buf[0 .. stem.len + ".so".len];
}

pub const Issue = union(enum) {
    /// A PE shim with no unix-side counterpart. Loading it would fail at
    /// runtime with nothing to explain why.
    missing_unix: []const u8,
    /// A unix-side module with no PE shim. Harmless, but it means the tree is
    /// not the one Apple shipped.
    orphan_unix: []const u8,
};

/// Compare the two halves of the shim set. Returns how many issues were
/// written to `out`; further issues are counted but not recorded.
pub fn checkPairs(dlls: []const []const u8, sos: []const []const u8, out: []Issue) usize {
    var n: usize = 0;
    var buf: [128]u8 = undefined;

    for (dlls) |dll| {
        const want = unixCounterpart(dll, &buf) catch continue;
        if (!contains(sos, want)) n = record(out, n, .{ .missing_unix = dll });
    }
    for (sos) |so| {
        if (!std.mem.endsWith(u8, so, ".so")) continue;
        const stem = so[0 .. so.len - ".so".len];
        var want_buf: [128]u8 = undefined;
        if (stem.len + ".dll".len > want_buf.len) continue;
        @memcpy(want_buf[0..stem.len], stem);
        @memcpy(want_buf[stem.len..][0..".dll".len], ".dll");
        if (!contains(dlls, want_buf[0 .. stem.len + ".dll".len])) {
            n = record(out, n, .{ .orphan_unix = so });
        }
    }
    return n;
}

fn record(out: []Issue, n: usize, issue: Issue) usize {
    if (n < out.len) out[n] = issue;
    return n + 1;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

const testing = std.testing;

test "a PE shim names its unix counterpart" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("d3d12.so", try unixCounterpart("d3d12.dll", &buf));
    try testing.expectEqualStrings("nvngx-on-metalfx.so", try unixCounterpart("nvngx-on-metalfx.dll", &buf));
    try testing.expectError(error.NotADll, unixCounterpart("libd3dshared.dylib", &buf));

    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, unixCounterpart("d3d12.dll", &tiny));
}

test "a complete 4.0b2 shim set has no issues" {
    const dlls = [_][]const u8{ "d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll", "nvngx-on-metalfx.dll" };
    const sos = [_][]const u8{ "d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so", "nvapi64.so", "nvngx-on-metalfx.so" };
    var issues: [8]Issue = undefined;
    try testing.expectEqual(@as(usize, 0), checkPairs(&dlls, &sos, &issues));
}

test "a 3.0-era shim set is also complete — the file list is not the invariant" {
    const dlls = [_][]const u8{ "atidxx64.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll" };
    const sos = [_][]const u8{ "atidxx64.so", "d3d11.so", "d3d12.so", "dxgi.so", "nvapi64.so", "nvngx.so" };
    var issues: [8]Issue = undefined;
    try testing.expectEqual(@as(usize, 0), checkPairs(&dlls, &sos, &issues));
}

test "an unpaired shim is reported from whichever side it is missing" {
    const dlls = [_][]const u8{ "d3d12.dll", "dxgi.dll" };
    const sos = [_][]const u8{"d3d12.so"};
    var issues: [8]Issue = undefined;
    try testing.expectEqual(@as(usize, 1), checkPairs(&dlls, &sos, &issues));
    try testing.expectEqualStrings("dxgi.dll", issues[0].missing_unix);

    const orphan = [_][]const u8{ "d3d12.so", "d3d9.so" };
    try testing.expectEqual(@as(usize, 1), checkPairs(&[_][]const u8{"d3d12.dll"}, &orphan, &issues));
    try testing.expectEqualStrings("d3d9.so", issues[0].orphan_unix);
}

test "Apple's two disk images are told apart by name" {
    try testing.expect(isToolkitImage("Game_Porting_Toolkit_4.0_beta_2.dmg"));
    try testing.expect(!isToolkitImage("Game_Porting_Toolkit_4.0_beta_2.dmg.part"));
    try testing.expect(!isToolkitImage("Firefox 154.0.dmg"));
    try testing.expect(isEvaluationImage("Evaluation environment for Windows games 4.0 beta 2.dmg"));
    try testing.expect(!isEvaluationImage("Metal Shader Converter 4.0 beta 2.pkg"));
}

test "the toolkit image is chosen only when there is exactly one" {
    try testing.expectEqual(Choice.none, chooseToolkit(&.{ "Firefox 154.0.dmg", "TIDAL.arm64.dmg" }));
    const one = chooseToolkit(&.{ "Firefox 154.0.dmg", "Game_Porting_Toolkit_4.0_beta_2.dmg" });
    try testing.expectEqualStrings("Game_Porting_Toolkit_4.0_beta_2.dmg", one.one);
    // Two releases side by side: which is wanted is not protium's guess.
    try testing.expectEqual(Choice.several, chooseToolkit(&.{ "Game_Porting_Toolkit_3.0.dmg", "Game_Porting_Toolkit_4.0_beta_2.dmg" }));
}

test "more issues than the buffer holds are counted, not dropped silently" {
    const dlls = [_][]const u8{ "a.dll", "b.dll", "c.dll" };
    var one: [1]Issue = undefined;
    try testing.expectEqual(@as(usize, 3), checkPairs(&dlls, &[_][]const u8{}, &one));
}
