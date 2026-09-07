//! What a removal is allowed to touch, and what it does with each entry it
//! meets on the way down.
//!
//! `protium prefix remove` deletes a directory tree that somebody's games are
//! installed in, so the two questions it has to get right — which path is in
//! scope, and what happens at a symlink — are answered here, without a
//! filesystem, and tested. `main.zig` opens the directories and does the
//! unlinking; it decides nothing.

const std = @import("std");

const layout = @import("layout.zig");

/// What a removal does with one entry of a directory it is emptying.
pub const Action = enum {
    /// A directory of its own: empty it, then remove it.
    descend,
    /// Remove this entry, and nothing beyond it.
    unlink,
    /// The directory listing did not say what this is. Ask the filesystem —
    /// without following a link — and decide again from that answer.
    inspect,
};

/// **A symlink is unlinked, never followed.**
///
/// This is the rule the whole command rests on. A prefix can hold a link that
/// points out of it, and that is not hypothetical:
///
///     prefixes/eldenring/drive_c/Program Files (x86)/Steam/steamapps
///
/// is a symlink into a CrossOver bottle holding a 66 GB game install. Walking
/// through it would delete software protium did not put there and cannot put
/// back, and it would do so while reporting the prefix's size as something far
/// smaller than what was about to go. Removing the link leaves the target
/// exactly as it was, which is what somebody who made that link meant.
///
/// Everything that is not a directory is unlinked, so a socket or a device
/// node left behind in a prefix goes the same way rather than stopping the
/// walk part-way through a tree it has already begun to empty.
///
/// A kind of `.unknown` is what a filesystem that does not report entry types
/// in its listing gives, and it is the one answer that cannot be acted on: it
/// covers both a directory and a link. It is sent back to be looked at
/// directly rather than guessed at. A second `.unknown`, from a stat, is
/// treated as `.unlink` by the caller — unlinking a directory fails with
/// `IsDir` and is recoverable, where descending into a symlink is not.
pub fn actionFor(kind: std.Io.File.Kind) Action {
    return switch (kind) {
        .directory => .descend,
        .unknown => .inspect,
        else => .unlink,
    };
}

/// How deep a tree may be before a removal refuses it. The walk recurses, and
/// each level costs a directory handle and its 2 KB read buffer; this bounds
/// that. It is measured before anything is deleted, so a tree past the limit
/// is refused whole rather than left half-removed.
///
/// A Wine prefix with games in it does not come close: `eldenring` — Steam,
/// Proton-era layout and all — is 14 levels below the prefix directory.
pub const max_depth = 128;

pub const ScopeError = layout.NameError || error{ NotAChild, OutOfMemory };

/// The one directory `protium prefix remove <name>` may delete.
///
/// The name goes through `layout.checkName` — the same rule that decided
/// whether the prefix could be created — and the joined path is then checked
/// to be a direct child of `<root>/prefixes` rather than trusted to be one.
/// The check is redundant given the name rule, and it stays because the two
/// can drift apart and this is the one that matters: everything below the
/// path this returns is about to be unlinked.
pub fn prefixPath(gpa: std.mem.Allocator, root: []const u8, name: []const u8) ScopeError![]u8 {
    return childPath(gpa, root, layout.prefixes, name);
}

/// Where `protium install clean` may delete: the whole downloads directory,
/// not a named child of it. It holds vendors' installers under the names the
/// catalogue gives them, and nothing in it that cannot be fetched again — see
/// `layout.downloads`.
pub fn downloadsPath(gpa: std.mem.Allocator, root: []const u8) error{OutOfMemory}![]u8 {
    return std.fs.path.join(gpa, &.{ root, layout.downloads });
}

fn childPath(
    gpa: std.mem.Allocator,
    root: []const u8,
    sub: []const u8,
    name: []const u8,
) ScopeError![]u8 {
    try layout.checkName(name);
    const parent = try std.fs.path.join(gpa, &.{ root, sub });
    defer gpa.free(parent);
    const path = try std.fs.path.join(gpa, &.{ parent, name });
    errdefer gpa.free(path);
    if (!isDirectChild(parent, path)) return error.NotAChild;
    return path;
}

/// Whether `path` names something sitting immediately inside `parent`.
///
/// Compares the path's own parent directory against `parent`, so `.` and `..`
/// components, an absolute path that is not under `parent` at all, and
/// `parent` itself are all refused. A trailing separator on either side is
/// ignored, because a shell's tab-completion adds one and it is the same
/// directory either way.
pub fn isDirectChild(parent: []const u8, path: []const u8) bool {
    if (parent.len == 0 or path.len == 0) return false;
    const dir = std.fs.path.dirname(path) orelse return false;
    if (!std.mem.eql(u8, trimSlash(dir), trimSlash(parent))) return false;
    const base = std.fs.path.basename(path);
    if (base.len == 0) return false;
    return !std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..");
}

/// Whether a symlink found in `link_dir`, pointing at `target`, leads out of
/// `tree`.
///
/// This decides nothing about the removal — an outward link is unlinked
/// exactly like an inward one — it decides what is worth *saying* before the
/// removal happens. A link out of a prefix is the case where somebody put
/// something of their own into the tree, and the confirmation should name it
/// so that "only the link goes" is a statement they can check rather than a
/// promise they have to take.
///
/// The resolution is textual: `..` components are folded, and nothing is
/// opened. That makes it wrong in one direction only — a link whose path runs
/// through *another* symlink may be reported as leading out when it does not,
/// which lists a link that did not need listing. Following links to find out
/// would mean reading the very things this command exists not to touch.
pub fn pointsOutOf(
    gpa: std.mem.Allocator,
    tree: []const u8,
    link_dir: []const u8,
    target: []const u8,
) error{OutOfMemory}!bool {
    if (target.len == 0) return false;
    const resolved = try std.fs.path.resolve(gpa, &.{ link_dir, target });
    defer gpa.free(resolved);
    return !isWithin(tree, resolved);
}

/// Whether `path` is `tree` or something below it. A component boundary is
/// required, so `/root/prefixes/eldenring2` is not within
/// `/root/prefixes/eldenring`.
pub fn isWithin(tree: []const u8, path: []const u8) bool {
    const t = trimSlash(tree);
    if (t.len == 0 or path.len == 0) return false;
    if (!std.mem.startsWith(u8, path, t)) return false;
    if (path.len == t.len) return true;
    return path[t.len] == '/';
}

/// Whether removing `removed` leaves the recorded default naming something
/// that is no longer there.
///
/// `<root>/defaults` records a name rather than a path, so a default left
/// behind does not dangle in a way protium can see later: every command that
/// resolves it fails with "no prefix named X" and points at a prefix the user
/// deliberately deleted. Clearing the key at removal time is what turns that
/// into the ordinary "nothing chosen yet" state, which — with one prefix left
/// — needs no configuration at all.
pub fn clearsDefault(recorded: ?[]const u8, removed: []const u8) bool {
    const r = recorded orelse return false;
    return std.mem.eql(u8, r, removed);
}

fn trimSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

const testing = std.testing;

test "a symlink is unlinked, never walked through" {
    // The rule that keeps a 66 GB CrossOver bottle out of a prefix removal.
    try testing.expectEqual(Action.unlink, actionFor(.sym_link));
    try testing.expectEqual(Action.descend, actionFor(.directory));
    try testing.expectEqual(Action.unlink, actionFor(.file));
}

test "anything that is not a directory is unlinked rather than stopping the walk" {
    // Wine leaves sockets and named pipes in a prefix; a removal that refused
    // them would stop half way through a tree it had already begun to empty.
    for ([_]std.Io.File.Kind{
        .block_device,
        .character_device,
        .named_pipe,
        .unix_domain_socket,
        .whiteout,
        .door,
        .event_port,
        .file,
        .sym_link,
    }) |kind| {
        try testing.expectEqual(Action.unlink, actionFor(kind));
    }
}

test "an entry of unknown kind is looked at rather than guessed at" {
    // `.unknown` covers both a directory and a link, and the two want
    // opposite treatment, so it is the one answer that cannot be acted on.
    try testing.expectEqual(Action.inspect, actionFor(.unknown));
}

test "a prefix removal names a direct child of the prefixes directory" {
    const a = testing.allocator;
    const path = try prefixPath(a, "/home/me/.local/share/protium", "eldenring");
    defer a.free(path);
    try testing.expectEqualStrings("/home/me/.local/share/protium/prefixes/eldenring", path);
}

test "a name that could reach outside the prefixes directory is refused" {
    const a = testing.allocator;
    try testing.expectError(error.BadCharacter, prefixPath(a, "/root", "../runtimes"));
    try testing.expectError(error.BadCharacter, prefixPath(a, "/root", "a/b"));
    try testing.expectError(error.BadCharacter, prefixPath(a, "/root", "/etc"));
    try testing.expectError(error.Reserved, prefixPath(a, "/root", ".."));
    try testing.expectError(error.Reserved, prefixPath(a, "/root", "."));
    try testing.expectError(error.Empty, prefixPath(a, "/root", ""));
}

test "the downloads directory is removed whole, not by name" {
    const a = testing.allocator;
    const path = try downloadsPath(a, "/home/me/.local/share/protium");
    defer a.free(path);
    try testing.expectEqualStrings("/home/me/.local/share/protium/downloads", path);
}

test "in scope means one level inside, and nothing else" {
    const prefixes = "/root/prefixes";
    try testing.expect(isDirectChild(prefixes, "/root/prefixes/eldenring"));
    try testing.expect(isDirectChild(prefixes, "/root/prefixes/eldenring/"));
    try testing.expect(isDirectChild(prefixes ++ "/", "/root/prefixes/eldenring"));

    // The directory itself, its parent, and the root of the disk.
    try testing.expect(!isDirectChild(prefixes, prefixes));
    try testing.expect(!isDirectChild(prefixes, "/root"));
    try testing.expect(!isDirectChild(prefixes, "/"));
    // Two levels in is not one level in: `protium prefix remove` deletes a
    // prefix, never something inside one.
    try testing.expect(!isDirectChild(prefixes, "/root/prefixes/eldenring/drive_c"));
    // A sibling directory whose name merely starts the same way.
    try testing.expect(!isDirectChild(prefixes, "/root/prefixes-old/eldenring"));
    try testing.expect(!isDirectChild(prefixes, "/root/runtimes/wine-11.0"));
    // Traversal, spelled out rather than assumed to be impossible.
    try testing.expect(!isDirectChild(prefixes, "/root/prefixes/.."));
    try testing.expect(!isDirectChild(prefixes, "/root/prefixes/../runtimes"));
    try testing.expect(!isDirectChild(prefixes, "/root/prefixes/."));
    try testing.expect(!isDirectChild("", "/root/prefixes/eldenring"));
    try testing.expect(!isDirectChild(prefixes, ""));
}

test "a link into a CrossOver bottle is reported as leading out of the prefix" {
    const a = testing.allocator;
    const prefix = "/home/me/.local/share/protium/prefixes/eldenring";
    const steam = prefix ++ "/drive_c/Program Files (x86)/Steam";

    // The real one: `steamapps` in the prefix is a link into a CrossOver
    // bottle holding a 66 GB game install.
    try testing.expect(try pointsOutOf(
        a,
        prefix,
        steam,
        "/Users/me/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Steam/steamapps",
    ));
    // A relative link that climbs out of the prefix is the same case spelled
    // differently, and textual resolution is what catches it.
    try testing.expect(try pointsOutOf(a, prefix, steam, "../../../../../shared-steamapps"));
}

test "a link that stays inside the prefix is not worth naming" {
    const a = testing.allocator;
    const prefix = "/root/prefixes/eldenring";
    const inside = prefix ++ "/drive_c/windows";

    try testing.expect(!try pointsOutOf(a, prefix, inside, "system32"));
    try testing.expect(!try pointsOutOf(a, prefix, inside, "../users/me"));
    try testing.expect(!try pointsOutOf(a, prefix, inside, prefix ++ "/drive_c"));
    // The prefix directory itself is inside itself.
    try testing.expect(!try pointsOutOf(a, prefix, inside, "../.."));
    // A link with no target reads as nothing to say, not as an escape.
    try testing.expect(!try pointsOutOf(a, prefix, inside, ""));
}

test "a sibling whose name merely starts the same way is outside" {
    const a = testing.allocator;
    const prefix = "/root/prefixes/eldenring";
    try testing.expect(try pointsOutOf(a, prefix, prefix, "/root/prefixes/eldenring2/drive_c"));
    try testing.expect(try pointsOutOf(a, prefix, prefix, "/root/prefixes"));

    try testing.expect(isWithin(prefix, prefix));
    try testing.expect(isWithin(prefix ++ "/", prefix ++ "/drive_c"));
    try testing.expect(!isWithin(prefix, "/root/prefixes/eldenring2"));
    try testing.expect(!isWithin(prefix, "/root"));
    try testing.expect(!isWithin("", "/root"));
    try testing.expect(!isWithin(prefix, ""));
}

test "a recorded default is cleared only when it names what was removed" {
    try testing.expect(clearsDefault("eldenring", "eldenring"));
    try testing.expect(!clearsDefault("skyrim", "eldenring"));
    try testing.expect(!clearsDefault(null, "eldenring"));
    // A name that merely starts the same way is a different prefix.
    try testing.expect(!clearsDefault("eldenring2", "eldenring"));
}
