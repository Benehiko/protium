//! protium — assemble a Windows-game runtime on macOS from a Wine you built
//! and a D3DMetal you obtained from Apple.
//!
//! This file is the I/O edge: it searches PATH, opens directories and prints.
//! Every judgement it renders comes from a module that can be tested without a
//! host to inspect, which is why `doctor.zig` takes observations rather than
//! making them.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const doctor = @import("doctor.zig");
const toolchain = @import("toolchain.zig");
const redist = @import("redist.zig");
const macho = @import("macho.zig");
const plist = @import("plist.zig");

const protium_version = "0.1.0";

/// Rosetta 2's runtime lives here when it is installed, and nowhere else.
const rosetta_marker = "/Library/Apple/usr/libexec/oah";

const usage =
    \\protium — run Windows games on macOS with a Wine you built and Apple's D3DMetal
    \\
    \\Usage:
    \\  protium doctor
    \\      Check this host against everything the Wine build recipe needs.
    \\      Every prerequisite is reported, not only the first that fails.
    \\
    \\  protium redist <dir> [--into <wine-lib>]
    \\      Verify an Apple evaluation-environment tree — the `redist/lib`
    \\      directory from Apple's DMG — reporting its D3DMetal version, its
    \\      architecture, and whether its PE shims and unix modules pair up.
    \\      With --into, also print how to install it into a Wine tree.
    \\
    \\  protium version
    \\
    \\Neither half of the environment is shipped here: the Wine is built from
    \\CodeWeavers' published sources (docs/wine-build.md) and D3DMetal comes
    \\from Apple's Game Porting Toolkit (docs/d3dmetal.md).
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = init.minimal.args.vector;

    var out_buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;

    const cmd = if (argv.len > 1) std.mem.sliceTo(argv[1], 0) else "help";

    if (std.mem.eql(u8, cmd, "doctor")) {
        const ok = try runDoctor(io, init.environ_map, w);
        try stdout.interface.flush();
        if (!ok) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, cmd, "redist")) {
        if (argv.len < 3) {
            try w.writeAll("protium redist: needs a directory — the `redist/lib` from Apple's DMG\n");
            try stdout.interface.flush();
            std.process.exit(2);
        }
        const dir_path = std.mem.sliceTo(argv[2], 0);
        var into: ?[]const u8 = null;
        var i: usize = 3;
        while (i < argv.len) : (i += 1) {
            const arg = std.mem.sliceTo(argv[i], 0);
            if (std.mem.eql(u8, arg, "--into") and i + 1 < argv.len) {
                i += 1;
                into = std.mem.sliceTo(argv[i], 0);
            }
        }
        const ok = try runRedist(gpa, io, dir_path, into, w);
        try stdout.interface.flush();
        if (!ok) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, cmd, "version")) {
        try w.print("protium {s}\n", .{protium_version});
        try stdout.interface.flush();
        return;
    }

    try w.writeAll(usage);
    try stdout.interface.flush();
}

/// The host report. Returns whether everything is satisfied; the exit status
/// follows it so a script can gate on this command without reading its output.
fn runDoctor(io: Io, env: *const std.process.Environ.Map, w: *Io.Writer) !bool {
    var findings: [2 + toolchain.requirements.len]doctor.Finding = undefined;
    var where: [toolchain.requirements.len]?[]const u8 = @splat(null);
    var bufs: [toolchain.requirements.len][std.fs.max_path_bytes]u8 = undefined;

    findings[0] = doctor.archFinding(builtin.cpu.arch);
    findings[1] = doctor.rosettaFinding(exists(io, rosetta_marker));

    const path_var = env.get("PATH") orelse "";
    for (toolchain.requirements, 0..) |req, n| {
        where[n] = searchPath(io, path_var, req.program, &bufs[n]);
        findings[2 + n] = doctor.toolFinding(req, toolchain.evaluate(req, where[n]));
    }

    try w.writeAll("protium doctor\n\n");
    for (findings, 0..) |f, n| {
        try w.print("  [{s}] {s}\n        {s}\n", .{ if (f.ok) "ok" else "--", f.label, f.detail });
        if (n >= 2) {
            if (where[n - 2]) |p| try w.print("        found at {s}\n", .{p});
        }
    }

    const ok = doctor.allOk(&findings);
    try w.writeAll(if (ok)
        "\nThis host can build the Wine half. See docs/wine-build.md.\n"
    else
        "\nSomething above is missing. docs/wine-build.md says where each piece comes from,\nand fetches all of them into a scratch directory rather than installing on the host.\n");
    return ok;
}

/// Verify an Apple `redist/lib` tree and report what it is.
fn runRedist(gpa: std.mem.Allocator, io: Io, path: []const u8, into: ?[]const u8, w: *Io.Writer) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch {
        try w.print("protium redist: cannot open {s}\n", .{path});
        return false;
    };
    defer dir.close(io);

    try w.print("protium redist — {s}\n\n", .{path});
    var ok = true;

    // The version, which is the single most important thing to record about
    // an environment: the D3D12 shim is not the same object between releases.
    if (dir.readFileAlloc(io, redist.framework_plist, arena, .limited(1 << 20))) |xml| {
        const short = plist.stringValue(xml, "CFBundleShortVersionString") orelse "unknown";
        const platform = plist.stringValue(xml, "DTPlatformVersion") orelse "unknown";
        try w.print("  D3DMetal {s}  (built against platform {s})\n", .{ short, platform });
    } else |_| {
        try w.print("  D3DMetal version unknown — no {s}\n", .{redist.framework_plist});
        ok = false;
    }

    // The architecture, which is why the whole Wine is x86-64.
    if (dir.readFileAlloc(io, redist.shared_library, arena, .limited(1 << 24))) |bytes| {
        if (macho.read(bytes)) |archs| {
            try w.writeAll("  libd3dshared.dylib: ");
            for (archs.slice(), 0..) |a, n| {
                if (n != 0) try w.writeAll(" ");
                try w.writeAll(a.text());
            }
            try w.writeAll(if (archs.isX86Only())
                "  — x86-64 only, so the Wine hosting it must be too\n"
            else
                "\n");
        } else |_| {
            try w.writeAll("  libd3dshared.dylib: not a Mach-O file\n");
            ok = false;
        }
    } else |_| {
        try w.print("  missing {s}\n", .{redist.shared_library});
        ok = false;
    }

    // The shim pairing. The file list changes between releases; that every PE
    // shim has a unix counterpart does not.
    const dlls = try names(arena, io, dir, redist.windows_dir);
    const sos = try names(arena, io, dir, redist.unix_dir);
    try w.print("  shims: {d} PE, {d} unix\n", .{ dlls.len, sos.len });

    var issues: [16]redist.Issue = undefined;
    const n_issues = redist.checkPairs(dlls, sos, &issues);
    if (n_issues == 0) {
        try w.writeAll("  every PE shim has its unix counterpart\n");
    } else {
        ok = false;
        for (issues[0..@min(n_issues, issues.len)]) |issue| switch (issue) {
            .missing_unix => |d| try w.print("  {s} has no unix counterpart\n", .{d}),
            .orphan_unix => |s| try w.print("  {s} has no PE shim\n", .{s}),
        };
    }

    if (into) |dest| {
        try w.print(
            \\
            \\To install into {s}, preserving the layout the relative symlinks need:
            \\
            \\  cd {s}
            \\  mv external external.old; mv wine wine.old
            \\  ditto "{s}/" .
            \\
            \\`ditto` rather than `cp` because it preserves symlinks and framework
            \\structure; keeping the .old copies makes it a one-command revert.
            \\
        , .{ dest, dest, path });
    }

    return ok;
}

/// Entry names directly inside `sub`, duped into `arena`. A directory that is
/// not there yields an empty list, which the pairing check then reports.
fn names(arena: std.mem.Allocator, io: Io, dir: Io.Dir, sub: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = dir.openDir(io, sub, .{ .iterate = true }) catch return out.items;
    defer d.close(io);

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        try out.append(arena, try arena.dupe(u8, entry.name));
    }
    return out.items;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The first directory on `path_var` holding an executable named `program`.
fn searchPath(io: Io, path_var: []const u8, program: []const u8, buf: []u8) ?[]const u8 {
    var dirs = std.mem.splitScalar(u8, path_var, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, program }) catch continue;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return full;
    }
    return null;
}
