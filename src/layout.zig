//! Where protium keeps a user's environment, and how it picks between several.
//!
//! Pure path arithmetic and pure choices — nothing here opens a file, so every
//! rule below is testable without a host that has protium installed on it.
//!
//! The layout is one directory holding three things:
//!
//!     <root>/runtimes/<name>/   a Wine install: bin/wine, lib/wine/...
//!     <root>/prefixes/<name>/   a WINEPREFIX, with its protium.conf inside
//!     <root>/defaults           which runtime and which prefix to use
//!
//! `<root>` is `$PROTIUM_HOME`, else `$XDG_DATA_HOME/protium`, else
//! `$HOME/.local/share/protium`. It is deliberately not under `~/Library/
//! Application Support`: Wine's install rules do not quote paths, so a
//! destination containing a space fails part-way through `make install`. See
//! docs/wine-build.md.

const std = @import("std");

/// Directories inside the root.
pub const runtimes = "runtimes";
pub const prefixes = "prefixes";

/// The file recording which runtime and prefix to use, in the same
/// `KEY=VALUE` form as a prefix's own settings — see `env.parse`.
pub const defaults_file = "defaults";

/// A prefix's settings, stored *inside* the prefix rather than beside it.
/// Wine ignores files it does not recognise, and keeping the settings in the
/// prefix means copying or moving the prefix carries them along.
pub const prefix_config = "protium.conf";

/// Paths within a runtime, relative to `<root>/runtimes/<name>`.
pub const wine_loader = "bin/wine";
pub const wineserver = "bin/wineserver";
pub const bin_dir = "bin";
pub const lib_dir = "lib";

/// The file a prefix has once `wineboot` has finished with it. `wineboot`
/// returning is not the signal — `wineserver` inherits stdout and lingers
/// after it exits — but this file being written is.
pub const boot_marker = "system.reg";

pub const RootError = error{ NoHome, OutOfMemory };

/// Resolve the root from the environment. Explicit beats conventional, so
/// someone keeping a 1.1 GB Wine and its prefixes on an external disk sets
/// `PROTIUM_HOME` and is finished.
pub fn resolveRoot(
    gpa: std.mem.Allocator,
    protium_home: ?[]const u8,
    xdg_data_home: ?[]const u8,
    home: ?[]const u8,
) RootError![]u8 {
    if (nonEmpty(protium_home)) |p| return gpa.dupe(u8, p);
    if (nonEmpty(xdg_data_home)) |x| return std.fs.path.join(gpa, &.{ x, "protium" });
    const h = nonEmpty(home) orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ h, ".local", "share", "protium" });
}

pub const NameError = error{ Empty, Reserved, BadCharacter };

/// Runtime and prefix names are identifiers, not titles. Each one becomes a
/// directory name, gets printed into shell code, and gets typed at a prompt;
/// restricting them to this set is what makes all three safe at once, without
/// quoting rules that differ between shells.
pub fn checkName(name: []const u8) NameError!void {
    if (name.len == 0) return error.Empty;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.Reserved;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return error.BadCharacter,
    };
}

/// One line, addressed to whoever typed the name.
pub fn nameProblem(err: NameError) []const u8 {
    return switch (err) {
        error.Empty => "a name cannot be empty",
        error.Reserved => "`.` and `..` are directories, not names",
        error.BadCharacter => "names may hold letters, digits, `-`, `_` and `.` only",
    };
}

pub const ChoiceError = error{ None, Ambiguous };

/// Which of several installed runtimes, or prefixes, to use.
///
/// The single-candidate rule is what makes the common case need no
/// configuration: one Wine and one prefix are chosen without being named.
/// Ambiguity is reported rather than resolved, because picking the
/// alphabetically first runtime would be a silent decision about which
/// graphics stack a game runs against.
pub fn choose(
    asked: ?[]const u8,
    from_env: ?[]const u8,
    from_defaults: ?[]const u8,
    installed: []const []const u8,
) ChoiceError![]const u8 {
    if (nonEmpty(asked)) |n| return n;
    if (nonEmpty(from_env)) |n| return n;
    if (nonEmpty(from_defaults)) |n| return n;
    return switch (installed.len) {
        0 => error.None,
        1 => installed[0],
        else => error.Ambiguous,
    };
}

/// Wine's install rules do not quote paths, so a root with a space in it
/// cannot hold a runtime — `make install` fails after copying several hundred
/// files. Worth saying before the build rather than after it.
pub fn rootIsUsable(root: []const u8) bool {
    return std.mem.indexOfScalar(u8, root, ' ') == null;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

const testing = std.testing;

test "the root prefers an explicit setting, then XDG, then the home default" {
    const a = testing.allocator;

    const explicit = try resolveRoot(a, "/Volumes/Games/protium", "/x", "/home/me");
    defer a.free(explicit);
    try testing.expectEqualStrings("/Volumes/Games/protium", explicit);

    const xdg = try resolveRoot(a, null, "/home/me/.data", "/home/me");
    defer a.free(xdg);
    try testing.expectEqualStrings("/home/me/.data/protium", xdg);

    const dflt = try resolveRoot(a, null, null, "/home/me");
    defer a.free(dflt);
    try testing.expectEqualStrings("/home/me/.local/share/protium", dflt);
}

test "an empty variable is the same as an unset one" {
    const a = testing.allocator;
    // A shell that exports PROTIUM_HOME= without a value must not put the
    // root at the filesystem root.
    const root = try resolveRoot(a, "", "", "/home/me");
    defer a.free(root);
    try testing.expectEqualStrings("/home/me/.local/share/protium", root);
    try testing.expectError(error.NoHome, resolveRoot(a, null, null, null));
    try testing.expectError(error.NoHome, resolveRoot(a, null, null, ""));
}

test "a name that would escape its directory or confuse a shell is refused" {
    try checkName("default");
    try checkName("wine-11.0-cx26.3");
    try checkName("Skyrim_SE");

    try testing.expectError(error.Empty, checkName(""));
    try testing.expectError(error.Reserved, checkName(".."));
    try testing.expectError(error.Reserved, checkName("."));
    try testing.expectError(error.BadCharacter, checkName("a/b"));
    try testing.expectError(error.BadCharacter, checkName("my game"));
    try testing.expectError(error.BadCharacter, checkName("$(rm -rf ~)"));
    // A dot inside a name is ordinary — versions are spelled that way.
    try checkName("..hidden");
}

test "one installed candidate is chosen without being named" {
    const one = [_][]const u8{"wine-11.0-cx26.3"};
    try testing.expectEqualStrings("wine-11.0-cx26.3", try choose(null, null, null, &one));
}

test "several candidates with nothing to pick between them is ambiguous, not a guess" {
    const two = [_][]const u8{ "wine-11.0", "wine-7.7" };
    try testing.expectError(error.Ambiguous, choose(null, null, null, &two));
    try testing.expectError(error.None, choose(null, null, null, &.{}));
    // A recorded default resolves it, and so does an override.
    try testing.expectEqualStrings("wine-7.7", try choose(null, null, "wine-7.7", &two));
    try testing.expectEqualStrings("wine-11.0", try choose(null, "wine-11.0", "wine-7.7", &two));
    try testing.expectEqualStrings("asked", try choose("asked", "env", "defaults", &two));
}

test "a root with a space in it cannot hold a Wine install" {
    try testing.expect(rootIsUsable("/Users/me/.local/share/protium"));
    try testing.expect(!rootIsUsable("/Users/me/Library/Application Support/protium"));
}
