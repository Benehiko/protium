//! protium's own options: which ones there are, how each is spelled, and which
//! commands take which. Parsing lives here rather than in main so that it is
//! tested: tests are rooted at root.zig, which does not import main.

const std = @import("std");
const Io = std.Io;

pub const Options = struct {
    shell: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    /// Redo or override: `install` runs the installer again, `d3dmetal
    /// install` reinstalls the same version, `prefix stop` signals at once.
    /// On a command that asks a question it is the old spelling of `yes`.
    force: bool = false,
    /// Answer the command's question with yes, and nothing more: every check
    /// still runs, and a licence someone else asks about is still theirs.
    yes: bool = false,
    /// `install`: fetch the installer again rather than reusing the download.
    refresh: bool = false,
    /// `install`: put the program's own file back and remove protium's.
    undo: bool = false,
    /// Everything that was not a recognised option.
    positional: []const []const u8 = &.{},
    /// An option that was given without its value, or one this command does
    /// not take. Reported rather than ignored: a mistyped `--prefx` that
    /// silently launched the default prefix would be worse than an error.
    bad: ?[]const u8 = null,
};

/// protium's options. Each command names the ones it takes, and any other is
/// refused: with `--yes` and `--force` meaning different things, a
/// `prefix remove --undo` that was quietly ignored would teach the wrong one.
pub const Flag = enum { prefix, runtime, shell, force, yes, refresh, undo };

/// Which options a command takes.
pub const Allow = struct {
    prefix: bool = false,
    runtime: bool = false,
    shell: bool = false,
    force: bool = false,
    yes: bool = false,
    refresh: bool = false,
    undo: bool = false,

    fn has(a: Allow, f: Flag) bool {
        return switch (f) {
            inline else => |t| @field(a, @tagName(t)),
        };
    }
};

/// The option `arg` spells, long or short. Short forms exist for the ones
/// typed by hand often enough to want one.
pub fn flagOf(arg: []const u8) ?Flag {
    const spellings = [_]struct { []const u8, Flag }{
        .{ "--prefix", .prefix },   .{ "-p", .prefix },
        .{ "--runtime", .runtime }, .{ "-r", .runtime },
        .{ "--shell", .shell },     .{ "--force", .force },
        .{ "-f", .force },          .{ "--yes", .yes },
        .{ "-y", .yes },            .{ "--refresh", .refresh },
        .{ "--undo", .undo },
    };
    for (spellings) |s| if (std.mem.eql(u8, arg, s[0])) return s[1];
    return null;
}

/// Anything that starts with a dash is meant as an option, so one protium
/// does not know is an error rather than a name: `prefix remove games -x`
/// must not read `-x` as a second prefix. A lone `-` is not an option, and a
/// file whose name starts with one can be given as `./-name`.
fn looksLikeOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

/// Parse leading options, accepting only those in `allow`. When
/// `stop_at_positional` is set, the first non-option argument ends protium's
/// own parsing and everything after it is passed through untouched — a game's
/// own `--fullscreen` or `-windowed` is not protium's to interpret.
pub fn parse(
    arena: std.mem.Allocator,
    args: []const []const u8,
    stop_at_positional: bool,
    allow: Allow,
) !Options {
    var opts: Options = .{};
    var positional: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const flag = flagOf(arg) orelse {
            if (looksLikeOption(arg)) {
                opts.bad = arg;
                return opts;
            }
            try positional.append(arena, arg);
            if (stop_at_positional) {
                i += 1;
                while (i < args.len) : (i += 1) try positional.append(arena, args[i]);
                break;
            }
            continue;
        };
        if (!allow.has(flag)) {
            opts.bad = arg;
            return opts;
        }
        const target: *?[]const u8 = switch (flag) {
            .force => {
                opts.force = true;
                continue;
            },
            .yes => {
                opts.yes = true;
                continue;
            },
            .refresh => {
                opts.refresh = true;
                continue;
            },
            .undo => {
                opts.undo = true;
                continue;
            },
            .shell => &opts.shell,
            .prefix => &opts.prefix,
            .runtime => &opts.runtime,
        };
        i += 1;
        if (i >= args.len) {
            opts.bad = arg;
            return opts;
        }
        target.* = args[i];
    }

    opts.positional = positional.items;
    return opts;
}

/// The commands that ask a question, which `--yes` answers. Scripts written
/// for v0.2.0 pass `--force` to them instead (see CHANGELOG.md).
pub const asks_with_yes = [_][]const u8{ "prefix new", "prefix remove", "prefix migrate-user", "install clean" };

/// Whether `bad` is `--force` given to one of `asks_with_yes`, so that the
/// refusal can point at `--yes` rather than only refuse.
pub fn isRetiredForce(cmd: []const u8, bad: []const u8) bool {
    if (!std.mem.eql(u8, bad, "--force") and !std.mem.eql(u8, bad, "-f")) return false;
    for (asks_with_yes) |c| if (std.mem.eql(u8, c, cmd)) return true;
    return false;
}

/// What to say instead of the usual refusal.
pub const retired_force_message =
    \\--force no longer answers this command's question. Use --yes (-y), which
    \\says what it does: it answers the question, and every check still runs.
    \\
;

const testing = std.testing;

fn parseFor(arena: *std.heap.ArenaAllocator, args: []const []const u8, stop: bool, allow: Allow) !Options {
    return parse(arena.allocator(), args, stop, allow);
}

test "short and long spellings are the same option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allow: Allow = .{ .prefix = true, .runtime = true, .yes = true, .force = true };
    const long = try parseFor(&arena, &.{ "--prefix", "games", "--runtime", "w", "--yes", "--force" }, false, allow);
    const short = try parseFor(&arena, &.{ "-p", "games", "-r", "w", "-y", "-f" }, false, allow);
    for ([_]Options{ long, short }) |o| {
        try testing.expect(o.bad == null);
        try testing.expectEqualStrings("games", o.prefix.?);
        try testing.expectEqualStrings("w", o.runtime.?);
        try testing.expect(o.yes and o.force);
        try testing.expectEqual(@as(usize, 0), o.positional.len);
    }
}

test "--yes and --force are different options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const o = try parseFor(&arena, &.{"-y"}, false, .{ .yes = true });
    try testing.expect(o.yes and !o.force);
    // A command that takes only --force refuses --yes, and the other way round.
    try testing.expectEqualStrings("-y", (try parseFor(&arena, &.{"-y"}, false, .{ .force = true })).bad.?);
    try testing.expectEqualStrings("--force", (try parseFor(&arena, &.{"--force"}, false, .{ .yes = true })).bad.?);
}

test "an option the command does not take is refused, not ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("--undo", (try parseFor(&arena, &.{"--undo"}, false, .{ .prefix = true })).bad.?);
    try testing.expectEqualStrings("--prefix", (try parseFor(&arena, &.{ "--prefix", "p" }, false, .{})).bad.?);
}

test "an unknown dash argument is an error, not a name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const o = try parseFor(&arena, &.{ "games", "-x" }, false, .{ .yes = true });
    try testing.expectEqualStrings("-x", o.bad.?);
    try testing.expectEqualStrings("--prefx", (try parseFor(&arena, &.{"--prefx"}, false, .{ .prefix = true })).bad.?);
}

test "a lone dash and a ./-name path are names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const o = try parseFor(&arena, &.{ "-", "./-odd.dmg" }, false, .{});
    try testing.expect(o.bad == null);
    try testing.expectEqual(@as(usize, 2), o.positional.len);
}

test "an option missing its value is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("-p", (try parseFor(&arena, &.{"-p"}, false, .{ .prefix = true })).bad.?);
}

test "run's program and its arguments are passed through untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const o = try parseFor(&arena, &.{ "-p", "games", "game.exe", "-windowed", "--prefix", "x" }, true, .{ .prefix = true });
    try testing.expect(o.bad == null);
    try testing.expectEqualStrings("games", o.prefix.?);
    try testing.expectEqual(@as(usize, 4), o.positional.len);
    try testing.expectEqualStrings("-windowed", o.positional[1]);
}

test "the old --force on a question is recognised, so the refusal can name --yes" {
    for (asks_with_yes) |c| {
        try testing.expect(isRetiredForce(c, "--force"));
        try testing.expect(isRetiredForce(c, "-f"));
        try testing.expect(!isRetiredForce(c, "--undo"));
    }
    // Where --force means something else, or never meant anything, it is not
    // the retired spelling of --yes.
    try testing.expect(!isRetiredForce("status", "--force"));
    try testing.expect(!isRetiredForce("prefix stop", "--force"));
    try testing.expect(std.mem.indexOf(u8, retired_force_message, "--yes (-y)") != null);
}

test "the commands that ask take --yes and not --force" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const asks: Allow = .{ .yes = true };
    try testing.expect((try parseFor(&arena, &.{ "games", "-y" }, false, asks)).yes);
    try testing.expectEqualStrings("--force", (try parseFor(&arena, &.{ "games", "--force" }, false, asks)).bad.?);
}
