//! The environment an application inherits, and the per-prefix file that
//! shapes it.
//!
//! This is the whole point of the prefix being a *context* rather than a
//! directory you pass around: once these variables are in a shell, anything
//! launched from it — `wine`, a launcher script, a game — reaches the same
//! prefix, the same Wine and the same D3DMetal without being told.
//!
//! Everything here is computed from values handed in, so the rules are
//! testable without a Wine to point them at.

const std = @import("std");

pub const Setting = struct { key: []const u8, value: []const u8 };

pub const Var = struct { name: []const u8, value: []const u8 };

/// Variables protium sets itself, and which a prefix's `protium.conf` may
/// therefore not set. The file travels inside the prefix; one that redefined
/// `WINEPREFIX` would send a copied prefix's applications somewhere else
/// entirely, and one that redefined `PATH` would replace it rather than add
/// to it.
pub const managed = [_][]const u8{
    "PROTIUM_RUNTIME",
    "PROTIUM_PREFIX",
    "WINEPREFIX",
    "WINELOADER",
    "WINESERVER",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "PATH",
};

pub fn isManaged(key: []const u8) bool {
    for (managed) |m| if (std.mem.eql(u8, m, key)) return true;
    return false;
}

/// A line of `protium.conf` that could not be used. Reported rather than
/// skipped: a setting silently ignored is a game launched with the wrong
/// frame cap and no way to tell.
pub const Problem = struct {
    line: usize,
    text: []const u8,
    why: Why,

    pub const Why = enum { no_equals, empty_key, bad_key, managed_key };

    pub fn detail(p: Problem) []const u8 {
        return switch (p.why) {
            .no_equals => "not a KEY=VALUE line",
            .empty_key => "no name before the `=`",
            .bad_key => "a name may hold letters, digits and `_`, and may not start with a digit",
            .managed_key => "protium sets this variable itself; remove the line",
        };
    }
};

/// Parse a `KEY=VALUE` settings file. Blank lines and `#` comments are
/// ignored; everything else must be a setting. Keys and values are slices
/// into `text`, so `text` has to outlive them.
///
/// Both `protium.conf` and the root's `defaults` file use this form. It is
/// deliberately not shell syntax: the file is read by protium, never sourced,
/// so there is nothing in it that can run.
pub fn parse(
    gpa: std.mem.Allocator,
    text: []const u8,
    settings: *std.ArrayList(Setting),
    problems: *std.ArrayList(Problem),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try problems.append(gpa, .{ .line = n, .text = line, .why = .no_equals });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (key.len == 0) {
            try problems.append(gpa, .{ .line = n, .text = line, .why = .empty_key });
            continue;
        }
        if (!isValidKey(key)) {
            try problems.append(gpa, .{ .line = n, .text = line, .why = .bad_key });
            continue;
        }
        if (isManaged(key)) {
            try problems.append(gpa, .{ .line = n, .text = line, .why = .managed_key });
            continue;
        }
        try settings.append(gpa, .{ .key = key, .value = value });
    }
}

/// The name of an environment variable, as a shell will accept it.
pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (std.ascii.isDigit(key[0])) return false;
    for (key) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

/// The value of one setting, or null. Later lines win, so a file can be
/// appended to without being edited.
pub fn lookup(settings: []const Setting, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (settings) |s| if (std.mem.eql(u8, s.key, key)) {
        found = s.value;
    };
    return found;
}

/// One quoted value stays quoted in the file but not in the variable, so
/// `WINEDLLOVERRIDES="d3d12=n"` means what it looks like it means.
fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) {
        return v[1 .. v.len - 1];
    }
    return v;
}

/// Where the chosen runtime and prefix are.
pub const Site = struct {
    runtime_name: []const u8,
    /// `<root>/runtimes/<name>`
    runtime_dir: []const u8,
    prefix_name: []const u8,
    /// `<root>/prefixes/<name>`
    prefix_dir: []const u8,
};

/// What the calling shell already had. Both are colon-separated lists that
/// have to be added to rather than replaced.
pub const Inherited = struct {
    path: ?[]const u8 = null,
    dyld_fallback: ?[]const u8 = null,
};

/// The full set of variables, in the order they should be written.
///
/// `DYLD_FALLBACK_LIBRARY_PATH` is here because of a real property of the
/// build: Wine records FreeType's bare soname, `libfreetype.6.dylib`, and
/// `dlopen`s it at runtime, so the runtime's own `lib` has to be on dyld's
/// fallback search path or every launch comes up with no font rasteriser.
/// Nothing else is added to that list — `man dyld` states that binaries built
/// from Fall 2023 onward have no default fallback path at all, so inventing
/// `/usr/local/lib` here would create a search path macOS would not otherwise
/// have used, in an x86-64 process where it could find the wrong dylib.
pub fn compute(
    arena: std.mem.Allocator,
    site: Site,
    inherited: Inherited,
    settings: []const Setting,
) ![]Var {
    var out: std.ArrayList(Var) = .empty;

    // The names, so that a later `protium status` — or a nested protium —
    // reports what this shell is actually pointed at.
    try out.append(arena, .{ .name = "PROTIUM_RUNTIME", .value = site.runtime_name });
    try out.append(arena, .{ .name = "PROTIUM_PREFIX", .value = site.prefix_name });

    try out.append(arena, .{ .name = "WINEPREFIX", .value = site.prefix_dir });

    // Absolute rather than relying on PATH: Wine re-execs its loader by this
    // name, including when it hands a 32-bit process to the 32-bit loader.
    const loader = try std.fs.path.join(arena, &.{ site.runtime_dir, "bin", "wine" });
    const server = try std.fs.path.join(arena, &.{ site.runtime_dir, "bin", "wineserver" });
    try out.append(arena, .{ .name = "WINELOADER", .value = loader });
    try out.append(arena, .{ .name = "WINESERVER", .value = server });

    const lib = try std.fs.path.join(arena, &.{ site.runtime_dir, "lib" });
    try out.append(arena, .{
        .name = "DYLD_FALLBACK_LIBRARY_PATH",
        .value = try prepend(arena, lib, inherited.dyld_fallback),
    });

    const bin = try std.fs.path.join(arena, &.{ site.runtime_dir, "bin" });
    try out.append(arena, .{ .name = "PATH", .value = try prepend(arena, bin, inherited.path) });

    // The prefix's own settings come last, and cannot reach the ones above:
    // `parse` refuses a managed key before it ever gets here.
    for (settings) |s| try out.append(arena, .{ .name = s.key, .value = s.value });

    return out.items;
}

/// `entry` first, then `current` with any existing copy of `entry` removed.
///
/// The removal is what makes the shell hook safe to run twice. A plain prepend
/// grows `PATH` by one entry per new shell, and a shell started from a shell
/// inherits the growth.
pub fn prepend(arena: std.mem.Allocator, entry: []const u8, current: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, entry);
    if (current) |c| {
        var it = std.mem.tokenizeScalar(u8, c, ':');
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, entry)) continue;
            try out.append(arena, ':');
            try out.appendSlice(arena, part);
        }
    }
    return out.items;
}

const testing = std.testing;

test "a settings file keeps its settings and reports its mistakes" {
    const a = testing.allocator;
    var settings: std.ArrayList(Setting) = .empty;
    defer settings.deinit(a);
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(a);

    try parse(a,
        \\# frame cap, because this game's physics run off the frame rate
        \\D3DM_MAX_FPS = 60
        \\
        \\D3DM_SUPPORT_DXR=1
        \\WINEDLLOVERRIDES="d3d12=n"
    , &settings, &problems);

    try testing.expectEqual(@as(usize, 3), settings.items.len);
    try testing.expectEqualStrings("D3DM_MAX_FPS", settings.items[0].key);
    try testing.expectEqualStrings("60", settings.items[0].value);
    try testing.expectEqualStrings("1", settings.items[1].value);
    // The quotes belonged to the file, not to the value.
    try testing.expectEqualStrings("d3d12=n", settings.items[2].value);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "a line protium cannot use is reported with its line number" {
    const a = testing.allocator;
    var settings: std.ArrayList(Setting) = .empty;
    defer settings.deinit(a);
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(a);

    try parse(a,
        \\D3DM_MAX_FPS=60
        \\export D3DM_MTL4=1
        \\=orphan
        \\WINEPREFIX=/somewhere/else
    , &settings, &problems);

    try testing.expectEqual(@as(usize, 1), settings.items.len);
    try testing.expectEqual(@as(usize, 3), problems.items.len);

    // `export` is shell syntax; this file is not sourced by a shell.
    try testing.expectEqual(@as(usize, 2), problems.items[0].line);
    try testing.expectEqual(Problem.Why.bad_key, problems.items[0].why);
    try testing.expectEqual(Problem.Why.empty_key, problems.items[1].why);
    // The one that matters: a prefix may not redirect itself.
    try testing.expectEqual(Problem.Why.managed_key, problems.items[2].why);
}

test "a value may contain an equals sign, because overrides do" {
    const a = testing.allocator;
    var settings: std.ArrayList(Setting) = .empty;
    defer settings.deinit(a);
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(a);

    try parse(a, "WINEDLLOVERRIDES=d3d11=n,b;dxgi=n", &settings, &problems);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
    try testing.expectEqualStrings("d3d11=n,b;dxgi=n", settings.items[0].value);
}

test "the last setting of a name wins, so a file can be appended to" {
    const a = testing.allocator;
    var settings: std.ArrayList(Setting) = .empty;
    defer settings.deinit(a);
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(a);

    try parse(a, "prefix=one\nprefix=two\n", &settings, &problems);
    try testing.expectEqualStrings("two", lookup(settings.items, "prefix").?);
    try testing.expectEqual(@as(?[]const u8, null), lookup(settings.items, "runtime"));
}

test "every variable protium sets is refused in a prefix's own settings" {
    for (managed) |key| try testing.expect(isManaged(key));
    try testing.expect(!isManaged("D3DM_MAX_FPS"));
    try testing.expect(!isManaged("WINEDEBUG"));
}

test "a variable name is judged the way a shell would judge it" {
    try testing.expect(isValidKey("D3DM_MAX_FPS"));
    try testing.expect(isValidKey("_x"));
    try testing.expect(!isValidKey(""));
    try testing.expect(!isValidKey("2FAST"));
    try testing.expect(!isValidKey("D3DM MAX"));
    try testing.expect(!isValidKey("PATH;rm"));
}

test "prepending is idempotent, so the shell hook can run in every shell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("/w/bin", try prepend(a, "/w/bin", null));
    try testing.expectEqualStrings("/w/bin:/usr/bin", try prepend(a, "/w/bin", "/usr/bin"));

    // Already first: the result is the same string, not a doubled one.
    const once = try prepend(a, "/w/bin", "/w/bin:/usr/bin");
    try testing.expectEqualStrings("/w/bin:/usr/bin", once);
    try testing.expectEqualStrings("/w/bin:/usr/bin", try prepend(a, "/w/bin", once));

    // Found later in the list: moved to the front rather than duplicated.
    try testing.expectEqualStrings("/w/bin:/usr/bin:/bin", try prepend(a, "/w/bin", "/usr/bin:/w/bin:/bin"));
    // Empty entries, which a trailing colon leaves behind, are dropped.
    try testing.expectEqualStrings("/w/bin:/usr/bin", try prepend(a, "/w/bin", "/usr/bin:"));
}

test "the computed environment points every part of a launch at the same place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const vars = try compute(a, .{
        .runtime_name = "wine-11.0-cx26.3",
        .runtime_dir = "/r/runtimes/wine-11.0-cx26.3",
        .prefix_name = "default",
        .prefix_dir = "/r/prefixes/default",
    }, .{ .path = "/usr/bin:/bin" }, &.{
        .{ .key = "D3DM_MAX_FPS", .value = "60" },
    });

    try testing.expectEqualStrings("/r/prefixes/default", find(vars, "WINEPREFIX").?);
    try testing.expectEqualStrings("/r/runtimes/wine-11.0-cx26.3/bin/wine", find(vars, "WINELOADER").?);
    try testing.expectEqualStrings("/r/runtimes/wine-11.0-cx26.3/bin/wineserver", find(vars, "WINESERVER").?);
    try testing.expectEqualStrings("/r/runtimes/wine-11.0-cx26.3/bin:/usr/bin:/bin", find(vars, "PATH").?);
    try testing.expectEqualStrings("wine-11.0-cx26.3", find(vars, "PROTIUM_RUNTIME").?);
    try testing.expectEqualStrings("default", find(vars, "PROTIUM_PREFIX").?);
    try testing.expectEqualStrings("60", find(vars, "D3DM_MAX_FPS").?);
}

test "the runtime's lib is added to dyld's fallback path, not substituted for it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const site: Site = .{
        .runtime_name = "w",
        .runtime_dir = "/r/runtimes/w",
        .prefix_name = "p",
        .prefix_dir = "/r/prefixes/p",
    };

    // Nothing inherited: exactly the runtime's lib, and nothing invented.
    // Fabricating /usr/local/lib here would add a search path that current
    // macOS does not use by default — see the comment on `compute`.
    const bare = try compute(a, site, .{}, &.{});
    try testing.expectEqualStrings("/r/runtimes/w/lib", find(bare, "DYLD_FALLBACK_LIBRARY_PATH").?);

    // Something inherited: kept, behind ours.
    const kept = try compute(a, site, .{ .dyld_fallback = "/opt/mine/lib" }, &.{});
    try testing.expectEqualStrings("/r/runtimes/w/lib:/opt/mine/lib", find(kept, "DYLD_FALLBACK_LIBRARY_PATH").?);
}

fn find(vars: []const Var, name: []const u8) ?[]const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    return null;
}
