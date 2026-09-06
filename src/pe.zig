//! Which machine a Windows executable is built for.
//!
//! `macho.zig` answers this question for Apple's redistributable, and it is
//! worth answering for an installer too, for a reason particular to this
//! platform: a 32-bit installer needs a prefix with a populated `syswow64`,
//! and a prefix that `protium prefix new` created does not have one. Reading
//! two bytes before spawning turns "the installer exited with 53" into a
//! sentence someone can act on.
//!
//! Only enough of the PE format is read to answer that: the `MZ` signature, the
//! offset it holds at `0x3c`, the `PE\0\0` signature there, and the machine
//! field immediately after it. Nothing here allocates or opens anything.

const std = @import("std");

pub const Machine = enum {
    i386,
    x86_64,
    arm64,
    other,

    pub fn text(m: Machine) []const u8 {
        return switch (m) {
            .i386 => "32-bit x86",
            .x86_64 => "64-bit x86",
            .arm64 => "arm64",
            .other => "an architecture protium does not recognise",
        };
    }
};

pub const Error = error{NotPe};

/// The machine an executable is built for. `bytes` need only be the first few
/// hundred bytes of the file — everything read lives in the headers.
pub fn machine(bytes: []const u8) Error!Machine {
    if (bytes.len < 0x40) return error.NotPe;
    if (bytes[0] != 'M' or bytes[1] != 'Z') return error.NotPe;

    const at = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    // Two signature bytes, two zero bytes, then the two-byte machine field.
    const end = @as(u64, at) + 6;
    if (end > bytes.len) return error.NotPe;

    const pe = bytes[at..];
    if (pe[0] != 'P' or pe[1] != 'E' or pe[2] != 0 or pe[3] != 0) return error.NotPe;

    return switch (std.mem.readInt(u16, pe[4..6], .little)) {
        0x014c => .i386,
        0x8664 => .x86_64,
        0xaa64 => .arm64,
        else => .other,
    };
}

const testing = std.testing;

/// A PE header and nothing else: `MZ`, a pointer at 0x3c, and `PE\0\0` plus a
/// machine field where it points.
fn synth(buf: []u8, pe_at: u32, machine_id: u16) []u8 {
    @memset(buf, 0);
    buf[0] = 'M';
    buf[1] = 'Z';
    std.mem.writeInt(u32, buf[0x3c..0x40], pe_at, .little);
    buf[pe_at + 0] = 'P';
    buf[pe_at + 1] = 'E';
    std.mem.writeInt(u16, buf[pe_at + 4 ..][0..2], machine_id, .little);
    return buf;
}

test "the machine field is read from where the header says it is" {
    var buf: [0x200]u8 = undefined;
    // 0xc8 is where Valve's SteamSetup.exe keeps it; 0x80 is a different
    // offset, which is the point of the field existing at all.
    try testing.expectEqual(Machine.i386, try machine(synth(&buf, 0xc8, 0x014c)));
    try testing.expectEqual(Machine.x86_64, try machine(synth(&buf, 0x80, 0x8664)));
    try testing.expectEqual(Machine.arm64, try machine(synth(&buf, 0x100, 0xaa64)));
    try testing.expectEqual(Machine.other, try machine(synth(&buf, 0xc8, 0x0166)));
}

test "something that is not a PE file is refused rather than guessed at" {
    var buf: [0x200]u8 = undefined;

    try testing.expectError(error.NotPe, machine(""));
    try testing.expectError(error.NotPe, machine("MZ"));

    // No MZ.
    _ = synth(&buf, 0xc8, 0x8664);
    buf[0] = 'X';
    try testing.expectError(error.NotPe, machine(&buf));

    // MZ, but no PE where the offset points — a DOS executable, or an HTML
    // error page that happened to start with the right two bytes.
    _ = synth(&buf, 0xc8, 0x8664);
    buf[0xc8] = 0;
    try testing.expectError(error.NotPe, machine(&buf));

    // An offset past the end of what was read. The addition is done in 64
    // bits so that a header claiming 0xffffffff cannot wrap and index inside
    // the buffer.
    _ = synth(&buf, 0xc8, 0x8664);
    std.mem.writeInt(u32, buf[0x3c..0x40], 0xffff_ffff, .little);
    try testing.expectError(error.NotPe, machine(&buf));
}

test "every machine this can report says something readable" {
    for (std.enums.values(Machine)) |m| try testing.expect(m.text().len != 0);
    try testing.expectEqualStrings("32-bit x86", Machine.i386.text());
}
