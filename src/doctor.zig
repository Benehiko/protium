//! The host report: one line per prerequisite, all of them, always.
//!
//! `doctor` never stops at the first failure. Someone setting up an
//! environment wants the whole list so they can fix it in one pass, not a
//! sequence of runs each revealing one more thing. The checks themselves live
//! here as pure functions over observations; the observing — PATH searching,
//! file access — is main's job, so that this file is testable without a host
//! to inspect.

const std = @import("std");
const toolchain = @import("toolchain.zig");

pub const Finding = struct {
    label: []const u8,
    ok: bool,
    detail: []const u8,
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
        .detail = "present; the Wine that hosts D3DMetal is x86-64",
    } else .{
        .label = "Rosetta 2",
        .ok = false,
        .detail = "missing — install with: softwareupdate --install-rosetta",
    };
}

pub fn toolFinding(req: toolchain.Requirement, status: toolchain.Status) Finding {
    return .{
        .label = req.program,
        .ok = status.satisfied(),
        .detail = switch (status) {
            .ok => req.why,
            .missing => "not on PATH",
            .too_old => "found, but too old — see docs/wine-build.md",
        },
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

test "a missing Rosetta says how to get it" {
    const f = rosettaFinding(false);
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.detail, "softwareupdate") != null);
    try testing.expect(rosettaFinding(true).ok);
}

test "a tool's finding carries its reason when satisfied and its fault when not" {
    const req = toolchain.requirements[0];
    try testing.expect(toolFinding(req, .ok).ok);
    try testing.expectEqualStrings(req.why, toolFinding(req, .ok).detail);
    try testing.expect(!toolFinding(req, .missing).ok);
    try testing.expect(!toolFinding(req, .too_old).ok);
}

test "the overall verdict is false if any single finding failed" {
    const good = [_]Finding{ archFinding(.aarch64), rosettaFinding(true) };
    try testing.expect(allOk(&good));
    const mixed = [_]Finding{ archFinding(.aarch64), rosettaFinding(false) };
    try testing.expect(!allOk(&mixed));
    try testing.expect(allOk(&[_]Finding{}));
}
