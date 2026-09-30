//! Which Steam app a program belongs to.
//!
//! A Steam game started directly, rather than through Steam, calls
//! `SteamAPI_Init`, which needs to know its app ID. It reads `SteamAppId` from
//! the environment, or `steam_appid.txt` beside the executable, and most games
//! ship neither.
//!
//! Steam records the answer itself. Every installed game has an
//! `appmanifest_<id>.acf` in the `steamapps` directory of its library, naming
//! the directory under `steamapps/common` the game lives in. So a program at
//! `…/steamapps/common/ELDEN RING/Game/eldenring.exe` belongs to the manifest
//! whose `installdir` is `ELDEN RING`, and that manifest's `appid` is the
//! answer. Nothing is guessed: no manifest, no ID.

const std = @import("std");
const Io = std.Io;

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

/// The value of a top-level `"key" "value"` pair in a Valve KeyValues file,
/// such as an app manifest. The key is matched ignoring case, as Steam does.
/// Keys inside nested blocks are skipped: the depots below `AppState` carry
/// keys of their own, `appid` among them.
pub fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "{")) {
            depth += 1;
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            depth -|= 1;
            continue;
        }
        if (depth != 1) continue;
        var tokens: Quoted = .{ .rest = line };
        const k = tokens.next() orelse continue;
        const v = tokens.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(k, key)) return v;
    }
    return null;
}

const Quoted = struct {
    rest: []const u8,

    fn next(q: *Quoted) ?[]const u8 {
        const open = std.mem.indexOfScalar(u8, q.rest, '"') orelse return null;
        const after = q.rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '"') orelse return null;
        q.rest = after[close + 1 ..];
        return after[0..close];
    }
};

fn isAppId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The Steam app ID of the program at host path `program`, read from the app
/// manifest Steam wrote for it. Null when the program is not in a Steam
/// library, or no manifest claims its directory.
pub fn appId(arena: std.mem.Allocator, io: Io, program: []const u8) !?[]const u8 {
    const loc = locate(program) orelse return null;

    var dir = Io.Dir.cwd().openDir(io, loc.steamapps, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "appmanifest_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".acf")) continue;
        const text = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
        const installdir = field(text, "installdir") orelse continue;
        if (!std.ascii.eqlIgnoreCase(installdir, loc.installdir)) continue;
        const id = field(text, "appid") orelse continue;
        if (isAppId(id)) return try arena.dupe(u8, id);
    }
    return null;
}

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

test "the app ID comes from the manifest that claims the directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "steamapps/common/ELDEN RING/Game");
    try tmp.dir.writeFile(io, .{ .sub_path = "steamapps/appmanifest_1245620.acf", .data = manifest });
    try tmp.dir.writeFile(io, .{
        .sub_path = "steamapps/appmanifest_7.acf",
        .data = "\"AppState\"\n{\n\t\"appid\"\t\"7\"\n\t\"installdir\"\t\"Other\"\n}\n",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exe = try std.fs.path.join(a, &.{ base, "steamapps/common/ELDEN RING/Game/eldenring.exe" });
    try testing.expectEqualStrings("1245620", (try appId(a, io, exe)).?);

    const stray = try std.fs.path.join(a, &.{ base, "steamapps/common/Unknown/x.exe" });
    try testing.expect(try appId(a, io, stray) == null);
}
