//! What a prefix needs so that a game controller reaches Windows programs.
//!
//! protium's Wine has one way to see a controller: winebus's IOHID backend,
//! which hands it over as a raw ("hidraw") device. The other two are gone —
//! the build has no SDL, and CrossOver's own Xbox bus disables itself on macOS
//! Sequoia and later. winebus refuses a gamepad over hidraw unless SDL is off
//! and the evdev backend is disabled, because on Linux those would carry it
//! instead. Neither exists here, so saying so costs nothing, and without it the
//! controller is seen by Wine and then dropped: `ignoring hidraw device
//! 045e:0b13 with usages 0001:0005`. See docs/controllers.md.

const std = @import("std");

/// Where the settings live, as `reg add` takes it. `CurrentControlSet` is a
/// link; `system.reg` writes the same key under `ControlSet001`.
pub const key = "HKLM\\System\\CurrentControlSet\\Services\\winebus";

/// The key's section header in `system.reg`, where every backslash is doubled.
const section = "[System\\\\ControlSet001\\\\Services\\\\winebus]";

pub const Value = struct {
    name: []const u8,
    data: u32,
};

pub const values = [_]Value{
    .{ .name = "Enable SDL", .data = 0 },
    .{ .name = "DisableInput", .data = 1 },
};

/// Whether `system_reg` — a prefix's `system.reg`, as text — already carries
/// every value. Read rather than asked of Wine, so that a launch that has
/// nothing to change starts nothing extra.
pub fn configured(system_reg: []const u8) bool {
    const body = sectionBody(system_reg) orelse return false;
    var buf: [64]u8 = undefined;
    for (values) |v| {
        const line = std.fmt.bufPrint(&buf, "\"{s}\"=dword:{x:0>8}", .{ v.name, v.data }) catch return false;
        if (!hasLine(body, line)) return false;
    }
    return true;
}

/// The lines between the section's header and the next one.
fn sectionBody(text: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, section)) |i| {
        at = i + section.len;
        // The header is the whole of a line, up to its timestamp: a longer key
        // that merely begins with this one is a different section.
        const starts_line = i == 0 or text[i - 1] == '\n';
        const ends_name = at == text.len or text[at] == ' ' or text[at] == '\r' or text[at] == '\n';
        if (!starts_line or !ends_name) continue;
        const rest = text[at..];
        const end = std.mem.indexOf(u8, rest, "\n[") orelse rest.len;
        return rest[0..end];
    }
    return null;
}

fn hasLine(body: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, l, "\r"), line)) return true;
    }
    return false;
}

/// The `reg add` arguments, after the Wine loader, that write `v`. `/f`
/// because `reg` otherwise stops to ask before overwriting a value.
pub fn regAddArgs(buf: *[16]u8, v: Value) [10][]const u8 {
    const data = std.fmt.bufPrint(buf, "{d}", .{v.data}) catch unreachable;
    return .{ "reg", "add", key, "/v", v.name, "/t", "REG_DWORD", "/d", data, "/f" };
}

const testing = std.testing;

test "a freshly booted prefix does not let a controller through" {
    // The shape of a prefix wineboot had just made. The values elsewhere —
    // one in another key, one in a subkey — are not the ones winebus reads.
    const booted =
        \\[System\\ControlSet001\\Enum\\ROOT\\WINE\\WINEBUS] 1791562154
        \\#time=1dd58089b892830
        \\"DisableInput"=dword:00000001
        \\
        \\[System\\ControlSet001\\Services\\winebus] 1791562188
        \\#time=1dd58089b892832
        \\"Description"="Wine HID bus driver"
        \\"DisplayName"="Wine HID bus"
        \\"ErrorControl"=dword:00000001
        \\
        \\[System\\ControlSet001\\Services\\winebus\\Enum] 1791562188
        \\"Enable SDL"=dword:00000000
        \\
    ;
    try testing.expect(!configured(booted));
    try testing.expect(!configured(""));
}

test "a prefix with both values does" {
    // As Wine writes it after `reg add`, from the throwaway prefix the
    // controller was first seen through.
    const set =
        \\[System\\ControlSet001\\Services\\winebus] 1791562188
        \\#time=1dd58089b892832
        \\"Description"="Wine HID bus driver"
        \\"DisableInput"=dword:00000001
        \\"DisplayName"="Wine HID bus"
        \\"Enable SDL"=dword:00000000
        \\"ErrorControl"=dword:00000001
        \\
        \\[System\\ControlSet001\\Services\\winebus\\Enum] 1791562188
        \\
    ;
    try testing.expect(configured(set));
    const crlf = try std.mem.replaceOwned(u8, testing.allocator, set, "\n", "\r\n");
    defer testing.allocator.free(crlf);
    try testing.expect(configured(crlf));
}

test "one value of the two, or the wrong data, is not enough" {
    const half =
        \\[System\\ControlSet001\\Services\\winebus] 1791562188
        \\"Enable SDL"=dword:00000000
        \\
    ;
    try testing.expect(!configured(half));
    const wrong =
        \\[System\\ControlSet001\\Services\\winebus] 1791562188
        \\"DisableInput"=dword:00000000
        \\"Enable SDL"=dword:00000000
        \\
    ;
    try testing.expect(!configured(wrong));
}

test "reg add is given the key, the name, the data as a number, and /f" {
    var buf: [16]u8 = undefined;
    const args = regAddArgs(&buf, values[1]);
    try testing.expectEqualStrings("reg", args[0]);
    try testing.expectEqualStrings(key, args[2]);
    try testing.expectEqualStrings("DisableInput", args[4]);
    try testing.expectEqualStrings("REG_DWORD", args[6]);
    try testing.expectEqualStrings("1", args[8]);
    try testing.expectEqualStrings("/f", args[9]);
}
