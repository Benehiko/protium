//! Which architectures a Mach-O file holds, read from its header.
//!
//! This is `lipo -archs` as a function, and it exists because the single most
//! consequential fact about Apple's D3DMetal is that it is x86-64 only, which
//! forces the entire Wine that hosts it to be x86-64 as well. A tool that
//! assembles such an environment should be able to state that itself rather
//! than asking the user to run `lipo` and read the answer back.
//!
//! Only the two header shapes macOS actually ships are accepted: a
//! little-endian thin Mach-O, and a big-endian fat (universal) header. Any
//! big-endian thin Mach-O is from the PowerPC era and is not a file this
//! project will ever be handed.

const std = @import("std");

pub const Arch = enum {
    i386,
    x86_64,
    arm,
    arm64,
    other,

    pub fn text(a: Arch) []const u8 {
        return switch (a) {
            .i386 => "i386",
            .x86_64 => "x86_64",
            .arm => "arm",
            .arm64 => "arm64",
            .other => "other",
        };
    }
};

pub const Error = error{
    /// The bytes do not begin with a Mach-O or fat magic number.
    NotMachO,
    /// The header runs past the end of the bytes given.
    Truncated,
    /// More slices than this reader keeps room for.
    TooManyArchs,
};

/// A universal binary has held two slices in practice and four at the outside;
/// eight is generous and keeps the result a value rather than an allocation.
pub const max_archs = 8;

pub const Archs = struct {
    buf: [max_archs]Arch = undefined,
    len: usize = 0,

    pub fn slice(self: *const Archs) []const Arch {
        return self.buf[0..self.len];
    }

    pub fn has(self: *const Archs, a: Arch) bool {
        return std.mem.indexOfScalar(Arch, self.slice(), a) != null;
    }

    /// True when the file holds x86-64 and nothing else — the shape every
    /// piece of D3DMetal has, and the reason the Wine hosting it is x86-64.
    pub fn isX86Only(self: *const Archs) bool {
        return self.len == 1 and self.buf[0] == .x86_64;
    }

    fn append(self: *Archs, a: Arch) Error!void {
        if (self.len == max_archs) return Error.TooManyArchs;
        self.buf[self.len] = a;
        self.len += 1;
    }
};

const fat_magic: u32 = 0xCAFEBABE;
const fat_magic_64: u32 = 0xCAFEBABF;
const mh_magic: u32 = 0xFEEDFACE;
const mh_magic_64: u32 = 0xFEEDFACF;

const cpu_arch_abi64: u32 = 0x01000000;
const cpu_type_x86: u32 = 7;
const cpu_type_arm: u32 = 12;

/// The header only — 4 KB of a file is always enough, and usually 32 bytes.
pub fn read(bytes: []const u8) Error!Archs {
    if (bytes.len < 8) return Error.Truncated;

    const magic_be = std.mem.readInt(u32, bytes[0..4], .big);
    if (magic_be == fat_magic or magic_be == fat_magic_64) {
        // A fat header is big-endian by definition, including its count and
        // every slice's cputype.
        const count = std.mem.readInt(u32, bytes[4..8], .big);
        const entry_size: usize = if (magic_be == fat_magic_64) 32 else 20;

        var archs: Archs = .{};
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const off = 8 + i * entry_size;
            if (off + 4 > bytes.len) return Error.Truncated;
            try archs.append(fromCpuType(std.mem.readInt(u32, bytes[off..][0..4], .big)));
        }
        return archs;
    }

    const magic_le = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic_le == mh_magic or magic_le == mh_magic_64) {
        var archs: Archs = .{};
        try archs.append(fromCpuType(std.mem.readInt(u32, bytes[4..8], .little)));
        return archs;
    }

    return Error.NotMachO;
}

fn fromCpuType(cputype: u32) Arch {
    return switch (cputype) {
        cpu_type_x86 => .i386,
        cpu_type_x86 | cpu_arch_abi64 => .x86_64,
        cpu_type_arm => .arm,
        cpu_type_arm | cpu_arch_abi64 => .arm64,
        else => .other,
    };
}

const testing = std.testing;

/// A thin little-endian 64-bit header: magic then cputype.
fn thin64(cputype: u32) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], mh_magic_64, .little);
    std.mem.writeInt(u32, b[4..8], cputype, .little);
    return b;
}

test "a thin x86-64 Mach-O reports x86_64 and nothing else" {
    const bytes = thin64(cpu_type_x86 | cpu_arch_abi64);
    const archs = try read(&bytes);
    try testing.expectEqual(@as(usize, 1), archs.len);
    try testing.expect(archs.has(.x86_64));
    // The property that decides this project's architecture.
    try testing.expect(archs.isX86Only());
}

test "a thin arm64 Mach-O is not mistaken for x86-64" {
    const bytes = thin64(cpu_type_arm | cpu_arch_abi64);
    const archs = try read(&bytes);
    try testing.expect(archs.has(.arm64));
    try testing.expect(!archs.has(.x86_64));
    try testing.expect(!archs.isX86Only());
}

test "a fat header is read big-endian, and a universal binary is not x86-only" {
    // The shape of the native macOS Steam client's steamclient.dylib: both
    // slices, which is what makes an in-process bridge from an x86-64 Wine
    // possible at all.
    var b: [8 + 2 * 20]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], fat_magic, .big);
    std.mem.writeInt(u32, b[4..8], 2, .big);
    std.mem.writeInt(u32, b[8..][0..4], cpu_type_x86 | cpu_arch_abi64, .big);
    std.mem.writeInt(u32, b[28..][0..4], cpu_type_arm | cpu_arch_abi64, .big);

    const archs = try read(&b);
    try testing.expectEqual(@as(usize, 2), archs.len);
    try testing.expect(archs.has(.x86_64));
    try testing.expect(archs.has(.arm64));
    try testing.expect(!archs.isX86Only());
}

test "a truncated fat header is an error, not a short answer" {
    var b: [8 + 20]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], fat_magic, .big);
    std.mem.writeInt(u32, b[4..8], 4, .big); // claims four slices, carries one
    try testing.expectError(Error.Truncated, read(&b));
}

test "something that is not a Mach-O says so" {
    try testing.expectError(Error.NotMachO, read("MZ\x90\x00\x03\x00\x00\x00"));
    try testing.expectError(Error.Truncated, read("MZ"));
}
