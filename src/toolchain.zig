//! What a host needs before it can build the Wine half.
//!
//! The list is short and every entry earned its place by breaking a real
//! build. `docs/wine-build.md` records what each failure looked like; this
//! file is that knowledge in a form the program can check.

const std = @import("std");
const semver = @import("semver.zig");

pub const Requirement = struct {
    /// The program as it is spelled on PATH.
    program: []const u8,
    /// One line, addressed to someone who does not already know.
    why: []const u8,
    min: ?semver.Version = null,
    /// A location known to hold a version too old to use. macOS has shipped
    /// bison 2.3 at `/usr/bin/bison` for over a decade, and finding it there
    /// is not good news — Wine's configure rejects it by name.
    stale_path: ?[]const u8 = null,
};

pub const requirements = [_]Requirement{
    .{
        .program = "bison",
        .why = "Wine's parser generator. Xcode ships 2.3; configure needs 3.0 or newer.",
        .min = .{ .major = 3 },
        .stale_path = "/usr/bin/bison",
    },
    .{
        .program = "flex",
        .why = "Wine's lexer generator. Xcode's copy is recent enough.",
    },
    .{
        .program = "x86_64-w64-mingw32-clang",
        .why = "Builds the 64-bit PE modules. From llvm-mingw; Apple clang has no mingw driver.",
    },
    .{
        .program = "i686-w64-mingw32-clang",
        .why = "Builds the 32-bit PE modules, which the 32-bit Windows Steam client needs.",
    },
};

pub const Status = enum {
    ok,
    too_old,
    missing,

    pub fn satisfied(s: Status) bool {
        return s == .ok;
    }
};

/// Judge a requirement by where the program was found. Used when running the
/// program to ask its version is not worth a subprocess — presence plus a
/// known-stale location answers the question for every entry above.
pub fn evaluate(req: Requirement, found_path: ?[]const u8) Status {
    const path = found_path orelse return .missing;
    if (req.stale_path) |stale| {
        if (std.mem.eql(u8, path, stale)) return .too_old;
    }
    return .ok;
}

/// Judge a requirement by a version actually read from the program.
pub fn evaluateVersion(req: Requirement, found: ?semver.Version) Status {
    const version = found orelse return .missing;
    const min = req.min orelse return .ok;
    return if (version.atLeast(min)) .ok else .too_old;
}

const testing = std.testing;

fn named(name: []const u8) Requirement {
    for (requirements) |r| if (std.mem.eql(u8, r.program, name)) return r;
    unreachable;
}

test "a program that is absent is missing, not merely unsatisfied" {
    try testing.expectEqual(Status.missing, evaluate(named("bison"), null));
    try testing.expectEqual(Status.missing, evaluateVersion(named("bison"), null));
}

test "Xcode's bison is recognised at its own path as too old" {
    try testing.expectEqual(Status.too_old, evaluate(named("bison"), "/usr/bin/bison"));
    try testing.expectEqual(Status.ok, evaluate(named("bison"), "/opt/tools/bin/bison"));
}

test "a requirement with no stale path is satisfied by being found anywhere" {
    try testing.expectEqual(Status.ok, evaluate(named("flex"), "/usr/bin/flex"));
    try testing.expectEqual(Status.ok, evaluate(named("x86_64-w64-mingw32-clang"), "/scratch/llvm-mingw/bin/x86_64-w64-mingw32-clang"));
}

test "a version read from the program decides it when one is available" {
    const bison = named("bison");
    try testing.expectEqual(Status.too_old, evaluateVersion(bison, semver.parse("bison (GNU Bison) 2.3")));
    try testing.expectEqual(Status.ok, evaluateVersion(bison, semver.parse("bison (GNU Bison) 3.8.2")));
    // No minimum: any version satisfies.
    try testing.expectEqual(Status.ok, evaluateVersion(named("flex"), semver.parse("flex 2.6.4")));
}

test "both 32- and 64-bit PE compilers are required, not just one" {
    var saw_32 = false;
    var saw_64 = false;
    for (requirements) |r| {
        if (std.mem.eql(u8, r.program, "i686-w64-mingw32-clang")) saw_32 = true;
        if (std.mem.eql(u8, r.program, "x86_64-w64-mingw32-clang")) saw_64 = true;
    }
    try testing.expect(saw_32 and saw_64);
}
