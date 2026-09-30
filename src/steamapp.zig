//! Steam's own records of what it installed, and where.
//!
//! A Steam game started directly, rather than through Steam, calls
//! `SteamAPI_Init`, which needs to know its app ID. It reads `SteamAppId` from
//! the environment, or `steam_appid.txt` beside the executable, and most games
//! ship neither.
//!
//! Steam records the answer itself. Every installed game has an
//! `appmanifest_<id>.acf` in the `steamapps` directory of its library, naming
//! the game and the directory under `steamapps/common` it lives in. A library
//! can be on any drive; Steam lists them all in `libraryfolders.vdf`. So a
//! program at `…/steamapps/common/ELDEN RING/Game/eldenring.exe` belongs to
//! the manifest whose `installdir` is `ELDEN RING`, and a game can be found by
//! the name Steam shows for it. Nothing is guessed: no manifest, no ID.

const std = @import("std");
const Io = std.Io;
const complete = @import("complete.zig");

/// The Steam library every Windows Steam install has, relative to a prefix.
pub const default_steamapps = "drive_c/Program Files (x86)/Steam/steamapps";

// ---------------------------------------------------------------------------
// Valve's KeyValues text format

/// One `"key" "value"` pair, and how many blocks deep it sits.
pub const Pair = struct { depth: usize, key: []const u8, value: []const u8 };

/// The `"key" "value"` pairs of a KeyValues file, in order. Values are raw:
/// Steam escapes `\` and `"` inside them, and `unescape` undoes that. A key
/// that opens a block has no value on its line and is not returned.
pub const Pairs = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    depth: usize = 0,

    pub fn next(p: *Pairs) ?Pair {
        while (p.lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.eql(u8, line, "{")) {
                p.depth += 1;
                continue;
            }
            if (std.mem.eql(u8, line, "}")) {
                p.depth -|= 1;
                continue;
            }
            var q: Quoted = .{ .rest = line };
            const k = q.next() orelse continue;
            const v = q.next() orelse continue;
            return .{ .depth = p.depth, .key = k, .value = v };
        }
        return null;
    }
};

pub fn pairs(text: []const u8) Pairs {
    return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
}

/// The value of a top-level `"key" "value"` pair, such as an app manifest's
/// `appid`. The key is matched ignoring case, as Steam does. Keys inside
/// nested blocks are skipped: the depots below `AppState` carry keys of their
/// own, `appid` among them.
pub fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var it = pairs(text);
    while (it.next()) |p| {
        if (p.depth == 1 and std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
    }
    return null;
}

const Quoted = struct {
    rest: []const u8,

    /// The next quoted string, raw. A backslash escapes the character after
    /// it, so `"C:\\Games\\"` ends at the last quote, not the one before.
    fn next(q: *Quoted) ?[]const u8 {
        const open = std.mem.indexOfScalar(u8, q.rest, '"') orelse return null;
        const after = q.rest[open + 1 ..];
        var i: usize = 0;
        while (i < after.len) : (i += 1) {
            if (after[i] == '\\') {
                i += 1;
                continue;
            }
            if (after[i] == '"') {
                q.rest = after[i + 1 ..];
                return after[0..i];
            }
        }
        return null;
    }
};

/// A KeyValues string with its escapes undone: `\\` is `\`, `\"` is `"`.
pub fn unescape(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            try out.append(arena, switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                else => raw[i],
            });
        } else try out.append(arena, raw[i]);
    }
    return out.items;
}

fn isAppId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Where a program is

/// A program's place in a Steam library.
pub const Location = struct {
    /// The library's `steamapps` directory.
    steamapps: []const u8,
    /// The game's directory under `steamapps/common`.
    installdir: []const u8,
};

/// Where `path` sits in a Steam library, or null when it is not under
/// `steamapps/common/<dir>/`. Accepts `/` or `\` and any case.
pub fn locate(path: []const u8) ?Location {
    const marker = "steamapps/common/";
    var i: usize = 0;
    while (i + marker.len <= path.len) : (i += 1) {
        if (!matchesMarker(path[i..][0..marker.len], marker)) continue;
        // The marker must start a path component, so `mysteamapps/common`
        // is not mistaken for a library.
        if (i != 0 and !isSep(path[i - 1])) continue;
        const rest = path[i + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, "/\\") orelse continue;
        if (end == 0) continue;
        return .{ .steamapps = path[0 .. i + "steamapps".len], .installdir = rest[0..end] };
    }
    return null;
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn matchesMarker(got: []const u8, want: []const u8) bool {
    for (got, want) |g, m| {
        if (m == '/') {
            if (!isSep(g)) return false;
        } else if (std.ascii.toLower(g) != m) return false;
    }
    return true;
}

/// The Steam app ID of the program at host path `program`, read from the app
/// manifest Steam wrote for it. Null when the program is not in a Steam
/// library, or no manifest claims its directory.
pub fn appId(arena: std.mem.Allocator, io: Io, program: []const u8) !?[]const u8 {
    const loc = locate(program) orelse return null;
    for (try gamesIn(arena, io, loc.steamapps)) |g| {
        if (std.ascii.eqlIgnoreCase(g.installdir, loc.installdir)) return g.appid;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Libraries and games

/// The host path of a Windows path in a prefix, or null for one that names no
/// drive. C: is the prefix's `drive_c`; any other letter goes through Wine's
/// `dosdevices/<letter>:` link, which is where Wine itself looks.
pub fn hostPath(arena: std.mem.Allocator, prefix_dir: []const u8, windows_path: []const u8) !?[]const u8 {
    if (windows_path.len < 2 or windows_path[1] != ':') return null;
    if (!std.ascii.isAlphabetic(windows_path[0])) return null;
    const rest = try arena.dupe(u8, std.mem.trimStart(u8, windows_path[2..], "\\/"));
    for (rest) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    const letter = std.ascii.toLower(windows_path[0]);
    if (letter == 'c') return try std.fs.path.join(arena, &.{ prefix_dir, "drive_c", rest });
    const device = try std.fmt.allocPrint(arena, "{c}:", .{letter});
    return try std.fs.path.join(arena, &.{ prefix_dir, "dosdevices", device, rest });
}

/// Every Steam library in a prefix, as host paths to their `steamapps`
/// directories: the default one first, then each other that
/// `libraryfolders.vdf` lists. None is checked for existence; a library that
/// is not there simply holds nothing.
pub fn libraries(arena: std.mem.Allocator, io: Io, prefix_dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const default = try std.fs.path.join(arena, &.{ prefix_dir, default_steamapps });
    try out.append(arena, default);

    // Steam writes the list into steamapps/ now and config/ before; the first
    // one there is the one it uses.
    const candidates = [_][]const u8{
        try std.fs.path.join(arena, &.{ default, "libraryfolders.vdf" }),
        try std.fs.path.join(arena, &.{ prefix_dir, "drive_c/Program Files (x86)/Steam/config/libraryfolders.vdf" }),
    };
    const text = for (candidates) |c| {
        if (Io.Dir.cwd().readFileAlloc(io, c, arena, .limited(1 << 20))) |t| break t else |_| {}
    } else return out.items;

    // "libraryfolders" { "0" { "path" "C:\\…" } "1" { "path" "D:\\…" } }
    var it = pairs(text);
    while (it.next()) |p| {
        if (p.depth != 2 or !std.ascii.eqlIgnoreCase(p.key, "path")) continue;
        const root = (try hostPath(arena, prefix_dir, try unescape(arena, p.value))) orelse continue;
        const lib = try std.fs.path.join(arena, &.{ root, "steamapps" });
        const seen = for (out.items) |o| {
            if (std.ascii.eqlIgnoreCase(o, lib)) break true;
        } else false;
        if (!seen) try out.append(arena, lib);
    }
    return out.items;
}

/// An installed Steam game, as its manifest describes it.
pub const Game = struct {
    appid: []const u8,
    /// The name Steam shows, `ELDEN RING`.
    name: []const u8,
    /// Its directory under `steamapps/common`.
    installdir: []const u8,
    /// That directory, as a host path.
    dir: []const u8,
};

/// Every game with a manifest in one library's `steamapps`.
fn gamesIn(arena: std.mem.Allocator, io: Io, steamapps: []const u8) ![]const Game {
    var out: std.ArrayList(Game) = .empty;
    var dir = Io.Dir.cwd().openDir(io, steamapps, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "appmanifest_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".acf")) continue;
        const text = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
        const id = field(text, "appid") orelse continue;
        if (!isAppId(id)) continue;
        const installdir = try unescape(arena, field(text, "installdir") orelse continue);
        const name = try unescape(arena, field(text, "name") orelse installdir);
        try out.append(arena, .{
            .appid = try arena.dupe(u8, id),
            .name = try arena.dupe(u8, name),
            .installdir = try arena.dupe(u8, installdir),
            .dir = try std.fs.path.join(arena, &.{ steamapps, "common", installdir }),
        });
    }
    return out.items;
}

/// Every game in every library in `libs`.
pub fn games(arena: std.mem.Allocator, io: Io, libs: []const []const u8) ![]const Game {
    var out: std.ArrayList(Game) = .empty;
    for (libs) |lib| try out.appendSlice(arena, try gamesIn(arena, io, lib));
    return out.items;
}

/// The game `query` names: its app ID, or its name or directory ignoring case.
pub fn find(all: []const Game, query: []const u8) ?Game {
    for (all) |g| {
        if (std.mem.eql(u8, g.appid, query)) return g;
        if (std.ascii.eqlIgnoreCase(g.name, query)) return g;
        if (std.ascii.eqlIgnoreCase(g.installdir, query)) return g;
    }
    return null;
}

/// Could `name` be a game's title rather than a path? Titles have spaces and
/// colons (`Portal 2`, `Hades II: …`), so this only rules out slashes and a
/// drive letter.
pub fn couldBeTitle(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    return !(name.len >= 2 and name[1] == ':');
}

// ---------------------------------------------------------------------------
// Which program in a game's folder is the game

/// What `choose` found.
pub const Choice = union(enum) {
    /// Nothing that could be the game.
    none,
    /// One program: its path.
    one: []const u8,
    /// Several equally likely programs: their paths.
    several: []const []const u8,
};

/// Parts of file names, lowercased, that are never the game: installers, the
/// runtimes games bundle, crash reporters, hardware checkers, helper
/// processes, overlays, and Easy Anti-Cheat's bootstrapper, which does not
/// work here. Each was seen beside a real game's executable. They are
/// specific rather than short, so that a game called `Checkers.exe` survives.
const noise_names = [_][]const u8{
    "unins",
    "setup",
    "redist",
    "crashhandler",
    "crashreport",
    "crashpad",
    "crs-uploader",
    "crs-handler",
    "crs-video",
    "installer",
    "easyanticheat",
    "battleye",
    "start_protected_game",
    "windowsdesktop-runtime",
    "layerschecker",
    "driverversionchecker",
    "browsersubprocess",
    "supporttool",
    "overlayinjector",
};

/// Directory names, lowercased, whose contents are never the game.
const noise_dirs = [_][]const u8{
    "_commonredist",
    "commonredist",
    "redist",
    "redistributables",
    "easyanticheat",
    "battleye",
    "directx",
    "__installer",
    "installers",
    "__overlay",
};

fn containsAny(arena: std.mem.Allocator, s: []const u8, words: []const []const u8) !bool {
    const lower = try std.ascii.allocLowerString(arena, s);
    for (words) |w| if (std.mem.indexOf(u8, lower, w) != null) return true;
    return false;
}

/// Letters and digits only, lowercased, so `ELDEN RING` and `eldenring` agree.
fn squash(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (std.ascii.isAlphanumeric(c)) try out.append(arena, std.ascii.toLower(c));
    return out.items;
}

fn isNoiseDir(name: []const u8) bool {
    for (noise_dirs) |d| if (std.ascii.eqlIgnoreCase(name, d)) return true;
    return false;
}

/// The program in `game_dir` most likely to be the game, from `programs`
/// found under it. Known noise is dropped, then the shallowest remaining
/// `.exe` wins if it is alone at its depth. An Unreal game's top-level
/// `Stray.exe` is its launcher and starts the real one, so shallowest is
/// right there too. Anything closer than that is left to the person.
///
/// When several tie, the one whose file name is the game's name, ignoring
/// case, spaces and punctuation, wins if only one is: `eldenring.exe` for
/// `ELDEN RING`, beside a mod's launcher in the same folder. `titles` are the
/// names to compare against, Steam's name for the game and its directory.
pub fn choose(
    arena: std.mem.Allocator,
    game_dir: []const u8,
    titles: []const []const u8,
    programs: []const complete.Program,
) !Choice {
    var best: std.ArrayList([]const u8) = .empty;
    var best_depth: usize = std.math.maxInt(usize);
    for (programs) |p| {
        if (p.path.len <= game_dir.len + 1) continue;
        if (!std.mem.startsWith(u8, p.path, game_dir)) continue;
        const rel = p.path[game_dir.len + 1 ..];
        if (try containsAny(arena, p.name, &noise_names)) continue;

        var depth: usize = 0;
        var noisy = false;
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |part| {
            if (parts.peek() == null) break;
            depth += 1;
            if (isNoiseDir(part)) noisy = true;
        }
        if (noisy) continue;

        if (depth < best_depth) {
            best_depth = depth;
            best.clearRetainingCapacity();
        }
        if (depth == best_depth) try best.append(arena, p.path);
    }

    if (best.items.len > 1) {
        var named: ?[]const u8 = null;
        var matches: usize = 0;
        for (best.items) |path| {
            const file = std.fs.path.basename(path);
            const stem = if (complete.isExe(file)) file[0 .. file.len - ".exe".len] else file;
            const s = try squash(arena, stem);
            if (s.len == 0) continue;
            for (titles) |t| {
                if (std.mem.eql(u8, s, try squash(arena, t))) {
                    named = path;
                    matches += 1;
                    break;
                }
            }
        }
        if (matches == 1) return .{ .one = named.? };
    }

    return switch (best.items.len) {
        0 => .none,
        1 => .{ .one = best.items[0] },
        else => .{ .several = best.items },
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a program is placed in its Steam library" {
    const loc = locate("/p/drive_c/Program Files (x86)/Steam/steamapps/common/ELDEN RING/Game/eldenring.exe").?;
    try testing.expectEqualStrings("/p/drive_c/Program Files (x86)/Steam/steamapps", loc.steamapps);
    try testing.expectEqualStrings("ELDEN RING", loc.installdir);
}

test "Windows separators and any case are recognised" {
    const loc = locate("C:\\Program Files (x86)\\Steam\\SteamApps\\Common\\Game\\x.exe").?;
    try testing.expectEqualStrings("Game", loc.installdir);
}

test "a program outside a Steam library has no location" {
    for ([_][]const u8{
        "/p/drive_c/Games/eldenring.exe",
        "/p/steamapps/common/loose.exe",
        "/p/mysteamapps/common/Game/x.exe",
        "/p/steamapps/common//x.exe",
    }) |p| try testing.expect(locate(p) == null);
}

const manifest = "\"AppState\"\n{\n" ++
    "\t\"appid\"\t\t\"1245620\"\n" ++
    "\t\"name\"\t\t\"ELDEN RING\"\n" ++
    "\t\"installdir\"\t\t\"ELDEN RING\"\n" ++
    "\t\"InstalledDepots\"\n\t{\n" ++
    "\t\t\"1245621\"\n\t\t{\n" ++
    "\t\t\t\"manifest\"\t\t\"123\"\n" ++
    "\t\t\t\"appid\"\t\t\"999\"\n" ++
    "\t\t}\n\t}\n}\n";

test "manifest fields are read from the top-level block only" {
    try testing.expectEqualStrings("1245620", field(manifest, "appid").?);
    try testing.expectEqualStrings("ELDEN RING", field(manifest, "InstallDir").?);
    try testing.expect(field(manifest, "manifest") == null);
    try testing.expect(field(manifest, "missing") == null);
}

test "an app ID is digits only" {
    try testing.expect(isAppId("1245620"));
    try testing.expect(!isAppId(""));
    try testing.expect(!isAppId("12a"));
}

test "escaped strings are read whole and unescaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var q: Quoted = .{ .rest = "\"path\"\t\t\"D:\\\\Games\\\\\"" };
    try testing.expectEqualStrings("path", q.next().?);
    const raw = q.next().?;
    try testing.expectEqualStrings("D:\\\\Games\\\\", raw);
    try testing.expectEqualStrings("D:\\Games\\", try unescape(arena.allocator(), raw));
}

test "Windows paths map to drive_c or to Wine's dosdevices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/p/drive_c/Program Files (x86)/Steam", (try hostPath(a, "/p", "C:\\Program Files (x86)\\Steam")).?);
    try testing.expectEqualStrings("/p/dosdevices/d:/SteamLibrary", (try hostPath(a, "/p", "D:\\SteamLibrary")).?);
    try testing.expect(try hostPath(a, "/p", "SteamLibrary") == null);
}

test "a title is anything that is not a path" {
    try testing.expect(couldBeTitle("ELDEN RING"));
    try testing.expect(couldBeTitle("Hades II: Early Access"));
    try testing.expect(!couldBeTitle("C:\\Games\\x.exe"));
    try testing.expect(!couldBeTitle("./x.exe"));
    try testing.expect(!couldBeTitle(""));
}

test "libraries, games and app IDs come from Steam's own files" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, default_steamapps ++ "/common/ELDEN RING/Game");
    try tmp.dir.writeFile(io, .{ .sub_path = default_steamapps ++ "/appmanifest_1245620.acf", .data = manifest });
    try tmp.dir.writeFile(io, .{
        .sub_path = default_steamapps ++ "/appmanifest_7.acf",
        .data = "\"AppState\"\n{\n\t\"appid\"\t\"7\"\n\t\"installdir\"\t\"Other\"\n}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = default_steamapps ++ "/libraryfolders.vdf",
        .data = "\"libraryfolders\"\n{\n" ++
            "\t\"0\"\n\t{\n\t\t\"path\"\t\t\"c:\\\\program files (x86)\\\\steam\"\n" ++
            "\t\t\"apps\"\n\t\t{\n\t\t\t\"1245620\"\t\t\"1\"\n\t\t}\n\t}\n" ++
            "\t\"1\"\n\t{\n\t\t\"path\"\t\t\"D:\\\\SteamLibrary\"\n\t}\n}\n",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);

    const libs = try libraries(a, io, base);
    try testing.expectEqual(@as(usize, 2), libs.len);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ base, default_steamapps }), libs[0]);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ base, "dosdevices/d:/SteamLibrary/steamapps" }), libs[1]);

    const all = try games(a, io, libs);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("1245620", find(all, "elden ring").?.appid);
    try testing.expectEqualStrings("1245620", find(all, "1245620").?.appid);
    try testing.expectEqualStrings("7", find(all, "other").?.appid);
    try testing.expect(find(all, "missing") == null);

    const exe = try std.fs.path.join(a, &.{ base, default_steamapps, "common/ELDEN RING/Game/eldenring.exe" });
    try testing.expectEqualStrings("1245620", (try appId(a, io, exe)).?);
    const stray = try std.fs.path.join(a, &.{ base, default_steamapps, "common/Unknown/x.exe" });
    try testing.expect(try appId(a, io, stray) == null);
}

fn prog(path: []const u8) complete.Program {
    return .{ .name = std.fs.path.basename(path), .path = path };
}

test "the game's program is chosen past launchers, redistributables and anti-cheat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const elden_titles = [_][]const u8{ "ELDEN RING", "ELDEN RING" };

    // The executables of a stock install, as Steam lays it out.
    const elden = [_]complete.Program{
        prog("/g/ELDEN RING/Game/eldenring.exe"),
        prog("/g/ELDEN RING/Game/start_protected_game.exe"),
        prog("/g/ELDEN RING/Game/EasyAntiCheat/easyanticheat_eos_setup.exe"),
    };
    switch (try choose(a, "/g/ELDEN RING", &elden_titles, &elden)) {
        .one => |p| try testing.expectEqualStrings("/g/ELDEN RING/Game/eldenring.exe", p),
        else => return error.TestUnexpectedResult,
    }

    // A real install with the Seamless Co-op mod, whose launcher sits beside
    // the game: the game's own name breaks the tie.
    const modded = [_]complete.Program{
        prog("/g/ELDEN RING/Game/eldenring.exe"),
        prog("/g/ELDEN RING/Game/Seamless Co-op v1.9.0-510-1-9-0-1737457830(1)/ersc_launcher.exe"),
        prog("/g/ELDEN RING/Game/ersc_launcher.exe"),
        prog("/g/ELDEN RING/Game/start_protected_game.exe"),
        prog("/g/ELDEN RING/Game/EasyAntiCheat/easyanticheat_eos_setup.exe"),
        prog("/g/ELDEN RING/Game/SeamlessCoop/crashpad/crashpad_handler.exe"),
    };
    switch (try choose(a, "/g/ELDEN RING", &elden_titles, &modded)) {
        .one => |p| try testing.expectEqualStrings("/g/ELDEN RING/Game/eldenring.exe", p),
        else => return error.TestUnexpectedResult,
    }

    const unreal = [_]complete.Program{
        prog("/g/Stray/Hk_project/Binaries/Win64/Stray-Win64-Shipping.exe"),
        prog("/g/Stray/Engine/Binaries/Win64/CrashReportClient.exe"),
        prog("/g/Stray/Stray.exe"),
    };
    switch (try choose(a, "/g/Stray", &.{"Stray"}, &unreal)) {
        .one => |p| try testing.expectEqualStrings("/g/Stray/Stray.exe", p),
        else => return error.TestUnexpectedResult,
    }

    // Seen in real installs: EA's overlay one level down hid the game three
    // down (Jedi: Fallen Order), and crash uploaders sat beside it (Stellar
    // Blade).
    const overlay = [_]complete.Program{
        prog("/g/Jedi/__overlay/overlayinjector.exe"),
        prog("/g/Jedi/SwGame/Binaries/Win64/starwarsjedifallenorder.exe"),
    };
    switch (try choose(a, "/g/Jedi", &.{"Jedi"}, &overlay)) {
        .one => |p| try testing.expectEqualStrings("/g/Jedi/SwGame/Binaries/Win64/starwarsjedifallenorder.exe", p),
        else => return error.TestUnexpectedResult,
    }
    const crs = [_]complete.Program{
        prog("/g/SB/crs-uploader.exe"), prog("/g/SB/crs-handler.exe"), prog("/g/SB/SB.exe"),
    };
    switch (try choose(a, "/g/SB", &.{"Stellar Blade"}, &crs)) {
        .one => |p| try testing.expectEqualStrings("/g/SB/SB.exe", p),
        else => return error.TestUnexpectedResult,
    }

    // A tie that no name breaks is left to the person.
    const two = [_]complete.Program{ prog("/g/X/a.exe"), prog("/g/X/b.exe"), prog("/g/X/sub/c.exe") };
    switch (try choose(a, "/g/X", &.{"X"}, &two)) {
        .several => |ps| try testing.expectEqual(@as(usize, 2), ps.len),
        else => return error.TestUnexpectedResult,
    }

    const noise = [_]complete.Program{
        prog("/g/X/_CommonRedist/vcredist/vc_redist.x64.exe"),
        prog("/g/X/DXSETUP.exe"),
    };
    try testing.expect(try choose(a, "/g/X", &.{"X"}, &noise) == .none);
}
