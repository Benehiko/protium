//! The host report: one line per prerequisite, all of them, always.
//!
//! `doctor` never stops at the first failure. Someone setting up an
//! environment wants the whole list so they can fix it in one pass, not a
//! sequence of runs each revealing one more thing. The checks themselves live
//! here as pure functions over observations; the observing — file access — is
//! main's job, so that this file is testable without a host to inspect.
//!
//! There are two reports, because there are two ways to get a Wine.
//! `protium doctor` checks what running protium's Wine needs, which is all
//! that someone using `protium runtime install` needs. `protium doctor build`
//! checks what `protium build` needs on top. The build fetches its own bison
//! and llvm-mingw, so what it needs from the Mac is Xcode's command line tools.

const std = @import("std");

pub const Finding = struct {
    label: []const u8,
    ok: bool,
    detail: []const u8,
};

/// The programs `protium build` shells out to. All of them come with Xcode's
/// command line tools, and all of them are named by absolute path:
/// llvm-mingw's `bin/` goes on `PATH` ahead of everything else while the build
/// runs, and the `clang` in it targets Windows.
pub const build_tools = [_][]const u8{
    "/usr/bin/clang",
    "/usr/bin/make",
    "/usr/bin/tar",
    "/usr/bin/patch",
    "/usr/bin/install_name_tool",
    "/usr/bin/touch",
    "/usr/bin/cmp",
    // GMP's and Nettle's builds generate assembly with it.
    "/usr/bin/m4",
};

/// D3DMetal is x86-64 only and Rosetta translates x86-64, so an Intel Mac is
/// not merely unsupported — it is a different problem with a different answer,
/// and saying "unsupported" would be unhelpful.
pub fn archFinding(arch: std.Target.Cpu.Arch) Finding {
    return switch (arch) {
        .aarch64 => .{ .label = "Apple silicon", .ok = true, .detail = "arm64 host" },
        .x86_64 => .{
            .label = "Apple silicon",
            .ok = false,
            .detail = "this is an Intel Mac; D3DMetal requires Apple silicon",
        },
        else => .{ .label = "Apple silicon", .ok = false, .detail = "not a supported host architecture" },
    };
}

pub fn rosettaFinding(present: bool) Finding {
    return if (present) .{
        .label = "Rosetta 2",
        .ok = true,
        .detail = "present; protium's Wine is x86-64, because D3DMetal is",
    } else .{
        .label = "Rosetta 2",
        .ok = false,
        .detail = "missing — `protium runtime install` offers it, or: softwareupdate --install-rosetta",
    };
}

/// `missing` is the first of `build_tools` that is not there, or null.
pub fn xcodeFinding(missing: ?[]const u8) Finding {
    return if (missing == null) .{
        .label = "Xcode command line tools",
        .ok = true,
        .detail = "present; the build fetches bison and llvm-mingw itself",
    } else .{
        .label = "Xcode command line tools",
        .ok = false,
        .detail = "missing — install with: xcode-select --install",
    };
}

/// Everything satisfied? The exit status follows this, so a script can gate on
/// `protium doctor` without parsing its output.
pub fn allOk(findings: []const Finding) bool {
    for (findings) |f| if (!f.ok) return false;
    return true;
}

const testing = std.testing;

test "an Intel Mac is told what is actually wrong, not just that it failed" {
    const f = archFinding(.x86_64);
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.detail, "Intel") != null);
    try testing.expect(archFinding(.aarch64).ok);
    try testing.expect(!archFinding(.riscv64).ok);
}

test "a missing Rosetta says how to get it, protium's way first" {
    const f = rosettaFinding(false);
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.detail, "protium runtime install") != null);
    try testing.expect(std.mem.indexOf(u8, f.detail, "softwareupdate") != null);
    try testing.expect(rosettaFinding(true).ok);
}

test "missing Xcode tools say how to get them" {
    try testing.expect(xcodeFinding(null).ok);
    const f = xcodeFinding("/usr/bin/m4");
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.detail, "xcode-select --install") != null);
}

test "the overall verdict is false if any single finding failed" {
    const good = [_]Finding{ archFinding(.aarch64), rosettaFinding(true) };
    try testing.expect(allOk(&good));
    const mixed = [_]Finding{ archFinding(.aarch64), rosettaFinding(false) };
    try testing.expect(!allOk(&mixed));
    try testing.expect(allOk(&[_]Finding{}));
}
