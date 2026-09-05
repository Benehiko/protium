//! Version numbers as they arrive from tools, compared leniently.
//!
//! Every version this project cares about comes out of a line of
//! human-readable text — `bison (GNU Bison) 3.8.2` from a build tool, a
//! framework's `CFBundleShortVersionString` of `4.0b2` — and the only
//! question ever asked of it is "is this at least X".
//!
//! Parsing is therefore deliberately lenient: take the first run of digits and
//! read up to three dot-separated components. `4.0b2` orders as 4.0.0 and
//! keeps its original spelling for display, because the beta suffix is
//! something a reader wants to see and an ordering cannot carry.

const std = @import("std");

pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    /// Is `a` new enough to satisfy a minimum of `b`?
    pub fn atLeast(a: Version, b: Version) bool {
        return a.order(b) != .lt;
    }
};

/// The first dotted number in `text`, or null if it holds no digits.
///
/// The caller is expected to pass a version *line*, not an arbitrary string:
/// a program name like `x86_64-w64-mingw32-clang` is full of digits and would
/// parse as 86.64.32.
pub fn parse(text: []const u8) ?Version {
    var i: usize = 0;
    while (i < text.len and !std.ascii.isDigit(text[i])) i += 1;
    if (i == text.len) return null;

    var v: Version = .{};
    v.major = scan(text, &i);
    if (i < text.len and text[i] == '.') {
        i += 1;
        v.minor = scan(text, &i);
        if (i < text.len and text[i] == '.') {
            i += 1;
            v.patch = scan(text, &i);
        }
    }
    return v;
}

/// One run of digits starting at `i`, which is advanced past it. Saturates
/// rather than overflowing: a pathological digit run is not worth an error
/// path in a version comparison.
fn scan(text: []const u8, i: *usize) u32 {
    var n: u32 = 0;
    while (i.* < text.len and std.ascii.isDigit(text[i.*])) : (i.* += 1) {
        n = std.math.mul(u32, n, 10) catch return std.math.maxInt(u32);
        n = std.math.add(u32, n, text[i.*] - '0') catch return std.math.maxInt(u32);
    }
    return n;
}

const testing = std.testing;

test "a version is read out of the middle of a tool's output line" {
    try testing.expectEqual(Version{ .major = 3, .minor = 8, .patch = 2 }, parse("bison (GNU Bison) 3.8.2").?);
    try testing.expectEqual(Version{ .major = 2, .minor = 3 }, parse("bison (GNU Bison) 2.3").?);
    try testing.expectEqual(Version{ .major = 21, .minor = 0, .patch = 0 }, parse("Apple clang version 21.0.0").?);
    try testing.expectEqual(Version{ .major = 11, .minor = 0 }, parse("Wine version 11.0").?);
}

test "a beta suffix orders as the release it precedes, and is not an error" {
    // D3DMetal's CFBundleShortVersionString. The suffix is dropped for
    // ordering; callers display the original string.
    try testing.expectEqual(Version{ .major = 4, .minor = 0 }, parse("4.0b2").?);
}

test "text without digits has no version" {
    try testing.expectEqual(@as(?Version, null), parse("not found"));
    try testing.expectEqual(@as(?Version, null), parse(""));
}

test "ordering answers the only question asked of it" {
    const min: Version = .{ .major = 3 };
    try testing.expect(parse("bison (GNU Bison) 3.8.2").?.atLeast(min));
    try testing.expect(!parse("bison (GNU Bison) 2.3").?.atLeast(min));
    // Equality satisfies a minimum.
    try testing.expect((Version{ .major = 3 }).atLeast(min));
}
