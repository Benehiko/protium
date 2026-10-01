//! Tab-completion, and turning what someone types after `protium run` into
//! the program they meant.
//!
//! The shell scripts below do no thinking of their own. Each one hands the
//! words typed so far to `protium __complete`, which answers one candidate per
//! line, so bash, zsh and fish complete the same things and the rules live
//! here, where the tests are.
//!
//! Everything but `scan` is a pure function of its arguments. Completion runs
//! on every Tab press, so it must never print an error and never be slow: what
//! cannot be read is treated as absent.

const std = @import("std");
const Io = std.Io;
const catalog = @import("catalog.zig");
const shell = @import("shell.zig");

pub const commands = [_][]const u8{
    "doctor", "build",   "redist",  "status",     "env",        "use",
    "prefix", "run",     "install", "shell-init", "completion", "version",
    "help",   "runtime",
};
pub const prefix_subcommands = [_][]const u8{ "list", "new", "stop", "remove", "migrate-user" };
/// What `protium install` takes besides a catalogue name.
pub const install_specials = [_][]const u8{ "list", "clean" };
pub const options = [_][]const u8{ "--prefix", "--runtime", "--shell", "--force", "--refresh", "--undo" };
pub const shells = [_][]const u8{ "bash", "zsh", "fish" };

/// What the word being completed should be drawn from.
pub const Kind = enum {
    none,
    commands,
    options,
    install_names,
    prefix_subcommands,
    prefix_names,
    runtime_names,
    programs,
    shells,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The options that are followed by a value.
fn takesValue(arg: []const u8) bool {
    return eql(arg, "--prefix") or eql(arg, "--runtime") or eql(arg, "--shell");
}

/// What to complete, given the words after `protium` up to and including the
/// one under the cursor (which is empty when the line ends in a space).
pub fn kindAt(words: []const []const u8) Kind {
    if (words.len == 0) return .commands;
    const cur = words[words.len - 1];
    const before = words[0 .. words.len - 1];

    // The words that are not protium's options, or an option's value.
    var pos: [3][]const u8 = undefined;
    var npos: usize = 0;
    var i: usize = 0;
    while (i < before.len) : (i += 1) {
        const a = before[i];
        if (takesValue(a)) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) continue;
        if (npos < pos.len) pos[npos] = a;
        npos += 1;
    }

    // Everything after the program is the program's own: `--prefix` there is
    // a game's argument, not ours.
    if (npos >= 2 and eql(pos[0], "run")) return .none;

    if (before.len > 0) {
        const prev = before[before.len - 1];
        if (eql(prev, "--prefix")) return .prefix_names;
        if (eql(prev, "--runtime")) return .runtime_names;
        if (eql(prev, "--shell")) return .shells;
    }
    if (std.mem.startsWith(u8, cur, "--")) return .options;
    if (npos == 0) return .commands;

    const cmd = pos[0];
    if (eql(cmd, "install")) return if (npos == 1) .install_names else .none;
    if (eql(cmd, "run")) return .programs;
    if (eql(cmd, "use")) return if (npos == 1) .prefix_names else .none;
    if (eql(cmd, "completion")) return if (npos == 1) .shells else .none;
    if (eql(cmd, "prefix")) {
        if (npos == 1) return .prefix_subcommands;
        if (npos == 2 and (eql(pos[1], "stop") or eql(pos[1], "remove"))) return .prefix_names;
    }
    return .none;
}

/// Write each of `items` that begins with `cur`, ignoring case, one per line.
/// The shells filter as well, but a name with a space in it survives better
/// when only the matches were sent.
pub fn emit(w: *Io.Writer, items: []const []const u8, cur: []const u8) Io.Writer.Error!void {
    for (items) |item| {
        if (item.len < cur.len) continue;
        if (!std.ascii.eqlIgnoreCase(item[0..cur.len], cur)) continue;
        try w.writeAll(item);
        try w.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Programs

/// A Windows program found inside a prefix.
pub const Program = struct {
    /// The file name, `eldenring.exe`.
    name: []const u8,
    /// Where it is on this machine.
    path: []const u8,
};

/// Directories that hold Windows' own programs, which nobody launches by name
/// and which would bury the ones they do.
fn skipDir(depth: usize, name: []const u8) bool {
    return depth == 0 and std.ascii.eqlIgnoreCase(name, "windows");
}

pub fn isExe(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".exe");
}

/// An uninstaller is an `.exe` too, and never what someone wants to run.
fn isNoise(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "unins");
}

const max_programs = 5000;

/// How far below a root a scan looks. Directories at depth `max_depth` and
/// beyond are not opened; the root itself is depth 0.
pub const Walk = struct {
    max_depth: usize,
    /// Skip a top-level `windows`: set for `drive_c`, whose `windows` holds
    /// Windows' own programs, and not for a game library, where a directory
    /// of that name would be a game.
    skip_windows: bool = false,
};

/// `drive_c`. A Steam game's folder is five directories down
/// (`Program Files (x86)/Steam/steamapps/common/<game>`), and an Unreal
/// Engine game keeps its real executable three below that, in
/// `<project>/Binaries/Win64`, which is depth 8.
pub const drive_walk: Walk = .{ .max_depth = 9, .skip_windows = true };
/// A Steam library's `steamapps/common`: the same reach as the library on C:.
pub const library_walk: Walk = .{ .max_depth = 5 };
/// One game's folder: the same reach again, from the game down.
pub const game_walk: Walk = .{ .max_depth = 4 };

/// Every `.exe` under `drive_c`, apart from Windows' own and uninstallers.
pub fn scan(arena: std.mem.Allocator, io: Io, drive_c: []const u8) ![]const Program {
    var out: std.ArrayList(Program) = .empty;
    try scanRoot(arena, io, drive_c, drive_walk, &out);
    return out.items;
}

/// Append every `.exe` under `root` to `out`, apart from uninstallers.
///
/// Symlinks below the root are not followed: a prefix may link a drive letter
/// or a game library to somewhere large, and Tab must not walk it. The root
/// itself is followed, because it was chosen on purpose, and a Steam library
/// on another drive is reached through Wine's `dosdevices` link. The count is
/// capped across every root, so that a pathological tree still answers.
pub fn scanRoot(
    arena: std.mem.Allocator,
    io: Io,
    root: []const u8,
    walk: Walk,
    out: *std.ArrayList(Program),
) !void {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    try scanDir(arena, io, dir, root, 0, walk, out);
}

fn scanDir(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    dir_path: []const u8,
    depth: usize,
    walk: Walk,
    out: *std.ArrayList(Program),
) !void {
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (out.items.len >= max_programs) return;
        switch (entry.kind) {
            .file => {
                if (!isExe(entry.name) or isNoise(entry.name)) continue;
                try out.append(arena, .{
                    .name = try arena.dupe(u8, entry.name),
                    .path = try std.fs.path.join(arena, &.{ dir_path, entry.name }),
                });
            },
            .directory => {
                if (depth + 1 >= walk.max_depth) continue;
                if (walk.skip_windows and skipDir(depth, entry.name)) continue;
                var sub = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
                defer sub.close(io);
                const sub_path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                try scanDir(arena, io, sub, sub_path, depth + 1, walk, out);
            },
            else => {},
        }
    }
}

/// `programs` without repeats. Two roots can reach the same file, as the
/// Steam library on C: and `drive_c` itself do, and a Windows path in Steam's
/// own files may differ in case from the directory on disk, which macOS
/// treats as the same.
pub fn dedupe(arena: std.mem.Allocator, programs: []const Program) ![]const Program {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(Program) = .empty;
    for (programs) |p| {
        const key = try std.ascii.allocLowerString(arena, p.path);
        const slot = try seen.getOrPut(arena, key);
        if (slot.found_existing) continue;
        try out.append(arena, p);
    }
    return out.items;
}

/// The distinct names in `programs`, ignoring case, sorted.
pub fn programNames(arena: std.mem.Allocator, programs: []const Program) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (programs) |p| {
        var seen = false;
        for (out.items) |o| {
            if (std.ascii.eqlIgnoreCase(o, p.name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(arena, p.name);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

// ---------------------------------------------------------------------------
// Resolving `protium run <name>`

pub const Resolution = union(enum) {
    /// Not something protium recognises: hand it to Wine as typed. Wine has
    /// its own idea of a program — `notepad`, `winecfg`, a path.
    passthrough,
    /// A catalogue name whose program is in the prefix.
    app: *const catalog.App,
    /// A catalogue name that is not installed here.
    not_installed: *const catalog.App,
    /// An `.exe` name that exactly one file in the prefix has.
    program: []const u8,
    /// An `.exe` name that several files have: their paths.
    ambiguous: []const []const u8,
};

/// A path, or a drive, is already specific; only a bare name is looked up.
pub fn isBareName(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "/\\:") == null;
}

/// Decide what a bare name given to `protium run` means. `installed` is the
/// catalogue entries whose program exists in the prefix.
pub fn resolve(
    arena: std.mem.Allocator,
    name: []const u8,
    installed: []const *const catalog.App,
    programs: []const Program,
) !Resolution {
    if (!isBareName(name)) return .passthrough;

    if (catalog.find(name)) |app| {
        for (installed) |a| if (a == app) return .{ .app = app };
        return .{ .not_installed = app };
    }

    // Only a full file name is looked up. `notepad` stays Wine's, and a
    // prefix that happens to hold a `notepad.exe` cannot take it over.
    if (!isExe(name)) return .passthrough;
    var found: std.ArrayList([]const u8) = .empty;
    for (programs) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) try found.append(arena, p.path);
    }
    return switch (found.items.len) {
        0 => .passthrough,
        1 => .{ .program = found.items[0] },
        else => .{ .ambiguous = found.items },
    };
}

// ---------------------------------------------------------------------------
// The scripts

/// The script a shell sources to complete `protium`, or null for a shell with
/// no completion here. `protium env` prints it ahead of the environment, so
/// the line people already have in their startup file enables it; `protium
/// completion` prints it alone. It is shell code that gets evaluated, so it
/// says nothing but code and comments.
pub fn script(d: shell.Dialect) ?[]const u8 {
    return switch (d) {
        .bash =>
        \\# protium tab-completion
        \\_protium() {
        \\    local line
        \\    COMPREPLY=()
        \\    while IFS= read -r line; do
        \\        COMPREPLY+=("$line")
        \\    done < <(protium __complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
        \\}
        \\complete -o filenames -F _protium protium
        \\
        ,
        .zsh =>
        \\# protium tab-completion
        \\_protium() {
        \\    local -a candidates
        \\    candidates=( ${(f)"$(protium __complete "${(@)words[2,CURRENT]}" 2>/dev/null)"} )
        \\    compadd -- "${candidates[@]}"
        \\}
        \\(( $+functions[compdef] )) || { autoload -Uz compinit && compinit; }
        \\compdef _protium protium
        \\
        ,
        .fish =>
        \\# protium tab-completion
        \\function __protium_complete
        \\    set -l words (commandline -opc)
        \\    set -e words[1]
        \\    protium __complete $words (commandline -ct) 2>/dev/null
        \\end
        \\complete -c protium -f -a '(__protium_complete)'
        \\
        ,
        .posix => null,
    };
}

const testing = std.testing;

fn kind(words: []const []const u8) Kind {
    return kindAt(words);
}

test "the first word is a command, and an option once it starts with dashes" {
    try testing.expectEqual(Kind.commands, kind(&.{""}));
    try testing.expectEqual(Kind.commands, kind(&.{"ru"}));
    try testing.expectEqual(Kind.options, kind(&.{"--pre"}));
}

test "install completes the catalogue, once" {
    try testing.expectEqual(Kind.install_names, kind(&.{ "install", "" }));
    try testing.expectEqual(Kind.install_names, kind(&.{ "install", "--prefix", "p", "st" }));
    try testing.expectEqual(Kind.none, kind(&.{ "install", "steam", "" }));
}

test "run completes a program, and the program's own arguments are left alone" {
    try testing.expectEqual(Kind.programs, kind(&.{ "run", "" }));
    try testing.expectEqual(Kind.programs, kind(&.{ "run", "--prefix", "games", "el" }));
    try testing.expectEqual(Kind.none, kind(&.{ "run", "game.exe", "" }));
    // A game's own `--prefix` is not ours to complete.
    try testing.expectEqual(Kind.none, kind(&.{ "run", "game.exe", "--prefix", "" }));
}

test "an option's value is drawn from what it names" {
    try testing.expectEqual(Kind.prefix_names, kind(&.{ "run", "--prefix", "" }));
    try testing.expectEqual(Kind.runtime_names, kind(&.{ "install", "--runtime", "" }));
    try testing.expectEqual(Kind.shells, kind(&.{ "env", "--shell", "" }));
}

test "prefix subcommands, and the ones that name a prefix" {
    try testing.expectEqual(Kind.prefix_subcommands, kind(&.{ "prefix", "" }));
    try testing.expectEqual(Kind.prefix_names, kind(&.{ "prefix", "stop", "" }));
    try testing.expectEqual(Kind.prefix_names, kind(&.{ "prefix", "remove", "d" }));
    try testing.expectEqual(Kind.none, kind(&.{ "prefix", "new", "" }));
    try testing.expectEqual(Kind.prefix_names, kind(&.{ "use", "" }));
    try testing.expectEqual(Kind.shells, kind(&.{ "completion", "" }));
}

test "emit keeps only what starts with the word, ignoring case" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try emit(&w, &.{ "Steam.exe", "steamwebhelper.exe", "epic" }, "STEAM");
    try testing.expectEqualStrings("Steam.exe\nsteamwebhelper.exe\n", w.buffered());
}

test "a catalogue name resolves to its app, or says it is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const steam = catalog.find("steam").?;
    switch (try resolve(arena.allocator(), "steam", &.{steam}, &.{})) {
        .app => |a| try testing.expectEqual(steam, a),
        else => return error.TestUnexpectedResult,
    }
    switch (try resolve(arena.allocator(), "steam", &.{}, &.{})) {
        .not_installed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "an exe name resolves only when exactly one file has it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const progs = [_]Program{
        .{ .name = "EldenRing.exe", .path = "/p/one/EldenRing.exe" },
        .{ .name = "game.exe", .path = "/p/a/game.exe" },
        .{ .name = "game.exe", .path = "/p/b/game.exe" },
    };
    switch (try resolve(a, "eldenring.exe", &.{}, &progs)) {
        .program => |p| try testing.expectEqualStrings("/p/one/EldenRing.exe", p),
        else => return error.TestUnexpectedResult,
    }
    switch (try resolve(a, "game.exe", &.{}, &progs)) {
        .ambiguous => |ps| try testing.expectEqual(@as(usize, 2), ps.len),
        else => return error.TestUnexpectedResult,
    }
    switch (try resolve(a, "missing.exe", &.{}, &progs)) {
        .passthrough => {},
        else => return error.TestUnexpectedResult,
    }
}

test "paths, drives and Wine's own programs pass through untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const progs = [_]Program{.{ .name = "notepad.exe", .path = "/p/notepad.exe" }};
    for ([_][]const u8{ "C:\\a\\b.exe", "/abs/b.exe", "./b.exe", "sub/b.exe", "notepad", "winecfg" }) |n| {
        switch (try resolve(a, n, &.{}, &progs)) {
            .passthrough => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "program names are distinct ignoring case, and sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const names = try programNames(arena.allocator(), &.{
        .{ .name = "b.exe", .path = "1" },
        .{ .name = "A.exe", .path = "2" },
        .{ .name = "B.EXE", .path = "3" },
    });
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("A.exe", names[0]);
}

test "the drive scan reaches an Unreal game's executable, and stops below it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const ue = "drive_c/Program Files (x86)/Steam/steamapps/common/Stray/Hk_project/Binaries/Win64";
    try tmp.dir.createDirPath(io, ue);
    try tmp.dir.writeFile(io, .{ .sub_path = ue ++ "/Stray-Win64-Shipping.exe", .data = "" });
    try tmp.dir.createDirPath(io, "drive_c/1/2/3/4/5/6/7/8/9");
    try tmp.dir.writeFile(io, .{ .sub_path = "drive_c/1/2/3/4/5/6/7/8/in.exe", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "drive_c/1/2/3/4/5/6/7/8/9/out.exe", .data = "" });
    try tmp.dir.createDirPath(io, "drive_c/windows/system32");
    try tmp.dir.writeFile(io, .{ .sub_path = "drive_c/windows/system32/cmd.exe", .data = "" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const drive_c = try std.fs.path.join(a, &.{ base, "drive_c" });

    const names = try programNames(a, try scan(a, io, drive_c));
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("in.exe", names[0]);
    try testing.expectEqualStrings("Stray-Win64-Shipping.exe", names[1]);
}

test "dedupe drops a path seen before, ignoring case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try dedupe(arena.allocator(), &.{
        .{ .name = "a.exe", .path = "/p/Games/a.exe" },
        .{ .name = "a.exe", .path = "/p/games/a.exe" },
        .{ .name = "a.exe", .path = "/q/a.exe" },
    });
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "every shell but posix has a script that calls the completer" {
    for ([_]shell.Dialect{ .bash, .zsh, .fish }) |d| {
        try testing.expect(std.mem.indexOf(u8, script(d).?, "protium __complete") != null);
    }
    try testing.expect(script(.posix) == null);
}
