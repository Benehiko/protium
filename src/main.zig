//! protium — assemble a Windows-game runtime on macOS from a Wine you built
//! and a D3DMetal you obtained from Apple.
//!
//! This file is the I/O edge: it searches PATH, opens directories, spawns
//! processes and prints. Every judgement it renders comes from a module that
//! can be tested without a host to inspect, which is why `doctor.zig` takes
//! observations rather than making them, and why `layout.zig`, `env.zig`,
//! `shell.zig` and `status.zig` hold the rules this file only carries out.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const doctor = @import("doctor.zig");
const toolchain = @import("toolchain.zig");
const redist = @import("redist.zig");
const macho = @import("macho.zig");
const plist = @import("plist.zig");
const layout = @import("layout.zig");
const env = @import("env.zig");
const shell = @import("shell.zig");
const status = @import("status.zig");
const session = @import("session.zig");
const catalog = @import("catalog.zig");
const fetch = @import("fetch.zig");
const pe = @import("pe.zig");
const teardown = @import("teardown.zig");
const removal = @import("removal.zig");

/// The stand-in `steamwebhelper.exe`, built for x86_64-windows from
/// `src/webhelper.zig` by this repository's own `build.zig` and embedded here.
/// Nothing is vendored: it is compiled from source beside everything else.
const webhelper_shim = @embedFile("webhelper_shim");

const protium_version = "0.1.0";

/// Rosetta 2's runtime lives here when it is installed, and nowhere else.
const rosetta_marker = "/Library/Apple/usr/libexec/oah";

const usage =
    \\protium — run Windows games on macOS with a Wine you built and Apple's D3DMetal
    \\
    \\Setting up:
    \\  protium doctor              Check this host against what building Wine needs.
    \\  protium status              Where the installation is, and the next step.
    \\  protium shell-init          Print the line that makes prefixes automatic.
    \\
    \\Every day:
    \\  protium install <name>            Fetch and install known software.
    \\  protium install list              Show what protium knows how to install.
    \\  protium install clean             Delete the installers protium downloaded.
    \\  protium run <program> [args...]   Launch something in the default prefix.
    \\  protium prefix list               Show the prefixes and which is default.
    \\  protium prefix new <name>         Create a prefix and boot it.
    \\  protium prefix stop [<name>]      Shut down the Wine running in a prefix.
    \\  protium prefix remove <name>      Delete a prefix and everything in it.
    \\  protium use <name>                Make a prefix the default.
    \\  protium env                       Print the environment, as shell code.
    \\
    \\Installing Apple's half:
    \\  protium redist <dir> [--into <wine-lib>]
    \\      Verify an Apple evaluation-environment tree — the `redist/lib`
    \\      directory from Apple's DMG — reporting its D3DMetal version, its
    \\      architecture, and whether its PE shims and unix modules pair up.
    \\      With --into, also print how to install it into a Wine tree.
    \\
    \\  protium version
    \\
    \\Options, where they apply:
    \\  --prefix <name>   Use this prefix instead of the default.
    \\  --runtime <name>  Use this Wine instead of the default.
    \\  --shell <name>    fish, zsh, bash or posix. Defaults to $SHELL.
    \\  --force           install: run the installer even if it is already there.
    \\                    prefix stop: skip the polite request and signal at once.
    \\                    prefix remove, install clean: delete without asking
    \\                    first. It never deletes anything the question would
    \\                    not have offered to.
    \\  --refresh         install: download again rather than reusing the copy.
    \\  --undo            install: put back the program's own file protium replaced.
    \\
    \\Neither half of the environment is shipped here: the Wine is built from
    \\CodeWeavers' published sources (docs/wine-build.md) and D3DMetal comes
    \\from Apple's Game Porting Toolkit (docs/d3dmetal.md).
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = init.minimal.args.vector;
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, args) |src, *dst| dst.* = std.mem.sliceTo(src, 0);

    var out_buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;

    const cmd = if (args.len > 1) args[1] else "help";
    const rest = if (args.len > 2) args[2..] else &.{};

    const code = try dispatch(gpa, arena, io, init.environ_map, cmd, rest, w);
    try w.flush();
    if (code != 0) std.process.exit(code);
}

fn dispatch(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    cmd: []const u8,
    rest: []const []const u8,
    w: *Io.Writer,
) !u8 {
    if (std.mem.eql(u8, cmd, "doctor")) return runDoctor(io, vars, w);
    if (std.mem.eql(u8, cmd, "redist")) return runRedist(gpa, io, rest, w);
    if (std.mem.eql(u8, cmd, "status")) return runStatus(arena, io, vars, rest, w);
    if (std.mem.eql(u8, cmd, "env")) return runEnv(arena, io, vars, rest, w);
    if (std.mem.eql(u8, cmd, "use")) return runUse(arena, io, vars, rest, w);
    if (std.mem.eql(u8, cmd, "prefix")) return runPrefix(arena, io, vars, rest, w);
    if (std.mem.eql(u8, cmd, "run")) return runLaunch(arena, io, vars, rest, w);
    if (std.mem.eql(u8, cmd, "install")) return runInstall(arena, io, vars, rest, w);
    if (std.mem.eql(u8, cmd, "shell-init")) return runShellInit(vars, rest, w);
    if (std.mem.eql(u8, cmd, "version")) {
        try w.print("protium {s}\n", .{protium_version});
        return 0;
    }
    for ([_][]const u8{ "help", "--help", "-h" }) |h| if (std.mem.eql(u8, cmd, h)) {
        try w.writeAll(usage);
        return 0;
    };

    // A mistyped command is a failure, not a request for the list. Exiting 0
    // here would let `protium instal … && echo done` report success.
    try w.print("protium: no such command `{s}`\n\n", .{cmd});
    try w.writeAll(usage);
    return 2;
}

// ---------------------------------------------------------------------------
// Arguments

const Options = struct {
    shell: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    /// `install`: run the installer even when the program is already there.
    force: bool = false,
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

/// Parse leading options. When `stop_at_positional` is set, the first
/// non-option argument ends protium's own parsing and everything after it is
/// passed through untouched — a game's own `--fullscreen` is not protium's to
/// interpret.
fn parseOptions(
    arena: std.mem.Allocator,
    args: []const []const u8,
    stop_at_positional: bool,
) !Options {
    var opts: Options = .{};
    var positional: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // Flags without a value, handled before the ones that take one so
        // that `--force` is not read as `--force <next argument>`.
        if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--refresh")) {
            opts.refresh = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--undo")) {
            opts.undo = true;
            continue;
        }
        const target: *?[]const u8 = if (std.mem.eql(u8, arg, "--shell"))
            &opts.shell
        else if (std.mem.eql(u8, arg, "--prefix"))
            &opts.prefix
        else if (std.mem.eql(u8, arg, "--runtime"))
            &opts.runtime
        else {
            if (std.mem.startsWith(u8, arg, "--")) {
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

fn reportBadOption(w: *Io.Writer, cmd: []const u8, bad: []const u8) !u8 {
    try w.print("protium {s}: {s} is not an option this command takes, or is missing its value\n", .{ cmd, bad });
    try w.writeAll("Run `protium` on its own for the list.\n");
    return 2;
}

// ---------------------------------------------------------------------------
// Resolving an installation

/// Open the session and resolve both halves, reporting whatever went wrong in
/// terms someone can act on. Returns null when the environment is not usable,
/// having already printed why.
const Resolution = struct {
    sess: session.Session,
    runtime: session.Session.Resolved,
    prefix: session.Session.Resolved,
    site: env.Site,
};

fn resolve(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    opts: Options,
    w: *Io.Writer,
) !?Resolution {
    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return null;
        },
        else => |e| return e,
    };

    const rt = sess.runtime(opts.runtime) catch |err| {
        try reportUnresolved(sess, w, layout.runtimes, "runtime", opts.runtime, err);
        return null;
    };
    const px = sess.prefix(opts.prefix) catch |err| {
        try reportUnresolved(sess, w, layout.prefixes, "prefix", opts.prefix, err);
        return null;
    };

    return .{ .sess = sess, .runtime = rt, .prefix = px, .site = sess.site(rt, px) };
}

fn reportUnresolved(
    sess: session.Session,
    w: *Io.Writer,
    sub: []const u8,
    noun: []const u8,
    asked: ?[]const u8,
    err: anyerror,
) !void {
    switch (err) {
        error.None => {
            try w.print("protium: no {s} installed under {s}/{s}\n", .{ noun, sess.root, sub });
            try w.writeAll("Run `protium status` for the next step.\n");
        },
        error.Ambiguous => {
            try w.print("protium: several {s}s are installed and none is the default:\n", .{noun});
            for (try sess.installed(sub)) |name| try w.print("  {s}\n", .{name});
            if (std.mem.eql(u8, noun, "prefix")) {
                try w.writeAll("Pick one with `protium use <name>`, or pass --prefix <name>.\n");
            } else {
                try w.writeAll("Pick one with `protium use --runtime <name>`, or pass --runtime <name>.\n");
            }
        },
        error.NoSuchName => {
            try w.print("protium: no {s} named {s} under {s}/{s}\n", .{ noun, asked orelse "?", sess.root, sub });
        },
        error.BadName => try w.print("protium: {s} is not a usable {s} name — {s}\n", .{
            asked orelse "?", noun, layout.nameProblem(error.BadCharacter),
        }),
        else => return err,
    }
}

// ---------------------------------------------------------------------------
// status

fn runStatus(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const opts = try parseOptions(arena, args, false);
    if (opts.bad) |b| return reportBadOption(w, "status", b);

    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return 1;
        },
        else => |e| return e,
    };

    var rt_err: ?anyerror = null;
    const rt: ?session.Session.Resolved = sess.runtime(opts.runtime) catch |err| blk: {
        rt_err = err;
        break :blk null;
    };
    var px_err: ?anyerror = null;
    const px: ?session.Session.Resolved = sess.prefix(opts.prefix) catch |err| blk: {
        px_err = err;
        break :blk null;
    };

    const state = sess.observe(rt, rt_err, px, px_err);

    try w.writeAll("protium status\n\n");
    try w.print("  root      {s}\n", .{sess.root});

    if (rt) |r| {
        try w.print("  runtime   {s}\n", .{r.name});
        try w.print("            {s}\n", .{if (state.wine_installed) r.dir else "no bin/wine — this is not a Wine install"});
        if (sess.d3dmetalVersion(r)) |v| {
            try w.print("            D3DMetal {s}\n", .{v});
        } else {
            try w.writeAll("            no D3DMetal — a Direct3D game will render nothing\n");
        }
    } else {
        try w.print("  runtime   {s}\n", .{describe(rt_err)});
    }

    if (px) |p| {
        try w.print("  prefix    {s}\n", .{p.name});
        try w.print("            {s}\n", .{p.dir});
        try w.writeAll(if (state.prefix_booted)
            "            booted\n"
        else
            "            never finished booting — no system.reg\n");
    } else {
        try w.print("  prefix    {s}\n", .{describe(px_err)});
    }

    try w.writeAll(if (state.shell_active)
        "  shell     this shell is pointed at the prefix above\n"
    else
        "  shell     not set up in this shell\n");

    const step = status.nextStep(state);
    try w.print("\nNext: {s}\n", .{step.why()});
    if (step.command()) |c| try w.print("      {s}\n", .{c});

    return if (step == .ready) 0 else 1;
}

fn describe(err: ?anyerror) []const u8 {
    const e = err orelse return "none";
    return switch (e) {
        error.None => "none installed",
        error.Ambiguous => "several installed, none chosen",
        error.NoSuchName => "the one asked for is not there",
        error.BadName => "the name given is not usable",
        else => "unavailable",
    };
}

// ---------------------------------------------------------------------------
// env

/// Print the environment as shell code. This is what a shell startup file
/// evaluates, so it must never write prose to stdout and must never fail: an
/// installation that is not finished yet prints a comment and succeeds, rather
/// than putting an error in front of someone on every new terminal.
fn runEnv(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const opts = try parseOptions(arena, args, false);
    if (opts.bad != null) {
        try shell.comment(w, "protium: unrecognised option; run `protium` for the list");
        return 0;
    }

    // Everything this command can say has to be said as a comment, including
    // its complaints — the shell is going to evaluate whatever appears here.
    const dialect = if (opts.shell) |name|
        shell.Dialect.fromName(name) orelse {
            try shell.comment(w, "protium: unknown --shell value; run `protium shell-init`");
            return 0;
        }
    else
        shell.Dialect.fromShellPath(vars.get("SHELL"));

    // `resolve` explains itself in prose, which is exactly what must not reach
    // a shell, so its report is thrown away and replaced with one comment.
    var quiet = std.Io.Writer.Discarding.init(&.{});
    const res = try resolve(arena, io, vars, opts, &quiet.writer) orelse {
        try shell.comment(w, "protium: no prefix in effect — run `protium status`");
        return 0;
    };

    const settings = try res.sess.prefixSettings(res.prefix, null);
    const computed = try env.compute(arena, res.site, res.sess.inherited(), settings);
    for (computed) |v| try shell.assign(w, dialect, v.name, v.value);
    return 0;
}

/// The dialect to render in: what was asked for, else what `$SHELL` implies.
/// Returns null having printed a complaint when a name was given that is not
/// one of the four.
fn chooseDialect(
    vars: *std.process.Environ.Map,
    opts: Options,
    w: *Io.Writer,
) !?shell.Dialect {
    const name = opts.shell orelse return shell.Dialect.fromShellPath(vars.get("SHELL"));
    return shell.Dialect.fromName(name) orelse {
        try w.print("protium: {s} is not a shell protium knows — try fish, zsh, bash or posix\n", .{name});
        return null;
    };
}

// ---------------------------------------------------------------------------
// use

fn runUse(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const opts = try parseOptions(arena, args, false);
    if (opts.bad) |b| return reportBadOption(w, "use", b);

    const wanted_prefix = if (opts.positional.len > 0) opts.positional[0] else opts.prefix;
    if (wanted_prefix == null and opts.runtime == null) {
        try w.writeAll("protium use: name a prefix — `protium use default` — or a runtime with --runtime\n");
        return 2;
    }

    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return 1;
        },
        else => |e| return e,
    };

    // Both names are checked against what is installed before anything is
    // written, so a typo does not leave a defaults file pointing at nothing.
    if (wanted_prefix) |name| {
        if (try verify(sess, layout.prefixes, "prefix", name, w) != 0) return 1;
    }
    if (opts.runtime) |name| {
        if (try verify(sess, layout.runtimes, "runtime", name, w) != 0) return 1;
    }

    const runtime_name = opts.runtime orelse env.lookup(sess.defaults, "runtime");
    const prefix_name = wanted_prefix orelse env.lookup(sess.defaults, "prefix");
    try writeDefaults(sess, runtime_name, prefix_name);

    if (prefix_name) |p| try w.print("Default prefix is now {s}.\n", .{p});
    if (runtime_name) |r| try w.print("Default runtime is now {s}.\n", .{r});

    const dialect = shell.Dialect.fromShellPath(vars.get("SHELL"));
    try w.writeAll("\nNew terminals pick this up on their own. To move this one:\n\n");
    try w.print("  {s}\n", .{dialect.hook()});
    return 0;
}

fn verify(
    sess: session.Session,
    sub: []const u8,
    noun: []const u8,
    name: []const u8,
    w: *Io.Writer,
) !u8 {
    layout.checkName(name) catch |err| {
        try w.print("protium use: {s} is not a usable name — {s}\n", .{ name, layout.nameProblem(err) });
        return 1;
    };
    const dir = try sess.join(&.{ sess.root, sub, name });
    if (sess.exists(dir)) return 0;

    try w.print("protium use: there is no {s} named {s}.\n", .{ noun, name });
    const present = try sess.installed(sub);
    if (present.len == 0) {
        try w.print("There are no {s}s yet — run `protium status` for the next step.\n", .{noun});
    } else {
        try w.print("These exist:\n", .{});
        for (present) |p| try w.print("  {s}\n", .{p});
    }
    return 1;
}

fn writeDefaults(sess: session.Session, runtime_name: ?[]const u8, prefix_name: ?[]const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    var body = std.Io.Writer.Allocating.fromArrayList(sess.arena, &text);
    const bw = &body.writer;
    try bw.writeAll("# Written by protium. KEY=VALUE, one per line; `#` is a comment.\n");
    if (runtime_name) |r| try bw.print("runtime={s}\n", .{r});
    if (prefix_name) |p| try bw.print("prefix={s}\n", .{p});

    try Io.Dir.cwd().createDirPath(sess.io, sess.root);
    const path = try sess.join(&.{ sess.root, layout.defaults_file });
    try Io.Dir.cwd().writeFile(sess.io, .{ .sub_path = path, .data = body.written() });
}

// ---------------------------------------------------------------------------
// prefix

fn runPrefix(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const sub = if (args.len > 0) args[0] else "list";
    const rest = if (args.len > 1) args[1..] else &.{};

    if (std.mem.eql(u8, sub, "list")) return prefixList(arena, io, vars, w);
    if (std.mem.eql(u8, sub, "new")) return prefixNew(arena, io, vars, rest, w);
    if (std.mem.eql(u8, sub, "stop")) return prefixStop(arena, io, vars, rest, w);
    if (std.mem.eql(u8, sub, "remove")) return prefixRemove(arena, io, vars, rest, w);

    try w.print("protium prefix: no such subcommand `{s}` — try `list`, `new`, `stop` or `remove`\n", .{sub});
    return 2;
}

fn prefixList(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    w: *Io.Writer,
) !u8 {
    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return 1;
        },
        else => |e| return e,
    };

    const present = try sess.installed(layout.prefixes);
    if (present.len == 0) {
        try w.print("No prefixes yet under {s}/{s}.\n", .{ sess.root, layout.prefixes });
        try w.writeAll("Create one with: protium prefix new default\n");
        return 1;
    }

    const active = sess.prefix(null) catch null;
    try w.writeAll("protium prefixes\n\n");
    for (present) |name| {
        const is_default = active != null and std.mem.eql(u8, active.?.name, name);
        const dir = try sess.join(&.{ sess.root, layout.prefixes, name });
        const booted = sess.exists(try sess.join(&.{ dir, layout.boot_marker }));
        try w.print("  {s} {s}{s}\n", .{
            if (is_default) "*" else " ",
            name,
            if (booted) "" else "   (never finished booting)",
        });
    }
    try w.writeAll("\n`*` is the default. Change it with: protium use <name>\n");
    return 0;
}

/// A starter `protium.conf`, written into a new prefix. It sets nothing —
/// D3DMetal's defaults are the right starting point — but it puts the file
/// where someone will find it, with the knobs named.
const starter_config =
    \\# Settings for this prefix. protium reads this file and puts each line
    \\# into the environment of anything launched here, so a change takes
    \\# effect the next time you run something — there is nothing to re-apply.
    \\#
    \\# The file lives inside the prefix, so copying the prefix copies these.
    \\#
    \\# What D3DMetal reads (see docs/d3dmetal.md for what each one does):
    \\#
    \\#   D3DM_SUPPORT_DXR=1        DirectX Raytracing
    \\#   D3DM_ENABLE_METALFX=1     turn DLSS calls into MetalFX where possible
    \\#   D3DM_MTL4=1               the Metal 4 backend
    \\#   D3DM_MAX_FPS=60           cap the frame rate
    \\#   ROSETTA_ADVERTISE_AVX=1   advertise AVX to the translated process
    \\#
    \\# And Wine's own, of which these two are the ones worth knowing:
    \\#
    \\#   WINEDEBUG=-all            quieten Wine's logging
    \\#   WINEDLLOVERRIDES=d3d12=n  force the native (D3DMetal) d3d12
    \\
;

fn prefixNew(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const opts = try parseOptions(arena, args, false);
    if (opts.bad) |b| return reportBadOption(w, "prefix new", b);
    if (opts.positional.len == 0) {
        try w.writeAll("protium prefix new: name the prefix — `protium prefix new default`\n");
        return 2;
    }
    const name = opts.positional[0];
    layout.checkName(name) catch |err| {
        try w.print("protium prefix new: {s} is not a usable name — {s}\n", .{ name, layout.nameProblem(err) });
        return 2;
    };

    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return 1;
        },
        else => |e| return e,
    };
    if (!layout.rootIsUsable(sess.root)) {
        try w.print("protium: {s} contains a space, which Wine's own tooling cannot handle.\n", .{sess.root});
        try w.writeAll("Set PROTIUM_HOME to a path without one. See docs/wine-build.md.\n");
        return 1;
    }

    // A prefix is only useful with a Wine to boot it, so resolve that first
    // and say so plainly rather than failing inside wineboot.
    const rt = sess.runtime(opts.runtime) catch |err| {
        try reportUnresolved(sess, w, layout.runtimes, "runtime", opts.runtime, err);
        return 1;
    };
    const loader = try sess.join(&.{ rt.dir, layout.wine_loader });
    if (!sess.exists(loader)) {
        try w.print("protium: {s} has no {s}.\n", .{ rt.dir, layout.wine_loader });
        try w.writeAll("That directory is not a Wine install. See docs/wine-build.md.\n");
        return 1;
    }

    const dir = try sess.join(&.{ sess.root, layout.prefixes, name });
    const already = sess.exists(try sess.join(&.{ dir, layout.boot_marker }));
    try Io.Dir.cwd().createDirPath(io, dir);

    const conf = try sess.join(&.{ dir, layout.prefix_config });
    if (!sess.exists(conf)) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = conf, .data = starter_config });
    }

    const site: env.Site = .{
        .runtime_name = rt.name,
        .runtime_dir = rt.dir,
        .prefix_name = name,
        .prefix_dir = dir,
    };
    const computed = try env.compute(arena, site, sess.inherited(), &.{});
    for (computed) |v| try vars.put(v.name, v.value);

    try w.print("Creating the prefix {s} in {s}\n", .{ name, dir });
    if (already) try w.writeAll("It exists already; booting it again repairs it and keeps its contents.\n");
    try w.writeAll(
        \\
        \\This runs Wine's own `wineboot`, which installs a Windows layout into the
        \\prefix. Expect several minutes: all of it is x86-64 running under Rosetta.
        \\
        \\
    );
    try w.flush();

    const boot = try spawnWait(io, vars, &.{ loader, "wineboot", "-u" });
    if (boot != 0) {
        try w.print("\nwineboot exited with {d}. The prefix may be incomplete.\n", .{boot});
        return 1;
    }

    // wineboot returning is not the end: wineserver stays alive holding the
    // session open, and would keep this terminal's stdout with it.
    const server = try sess.join(&.{ rt.dir, layout.wineserver });
    if (sess.exists(server)) _ = try spawnWait(io, vars, &.{ server, "-k" });

    if (!sess.exists(try sess.join(&.{ dir, layout.boot_marker }))) {
        try w.print("\nwineboot finished but wrote no {s}, so the prefix is not usable.\n", .{layout.boot_marker});
        return 1;
    }

    try w.print("\nThe prefix {s} is ready.\n", .{name});
    try w.print("Its settings are in {s}\n", .{conf});
    if (env.lookup(sess.defaults, "prefix") == null and (try sess.installed(layout.prefixes)).len == 1) {
        try w.writeAll("It is the only prefix, so it is the default.\n");
    } else {
        try w.print("\nMake it the default with:\n\n  protium use {s}\n", .{name});
    }
    return 0;
}

// ---------------------------------------------------------------------------
// prefix stop

/// A prefix that is running holds a Wine session open: one wineserver, and
/// every process it is serving. Stopping it politely means asking the
/// wineserver to shut down, which is what `wineserver -k` does — but a
/// wineserver that has stopped answering will not answer that either, and
/// `wineserver -k` is itself a Wine process, so it joins the queue instead of
/// clearing it. That is the case this command exists for, so the polite
/// request is given a deadline and the rest is done with signals.
fn prefixStop(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    var opts = try parseOptions(arena, args, false);
    if (opts.bad) |b| return reportBadOption(w, "prefix stop", b);
    // `prefix stop eldenring` and `prefix stop --prefix eldenring` are the
    // same request; `prefix new` takes its name positionally, so this does.
    if (opts.positional.len > 0) opts.prefix = opts.positional[0];

    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return 1;
        },
        else => |e| return e,
    };
    const px = sess.prefix(opts.prefix) catch |err| {
        try reportUnresolved(sess, w, layout.prefixes, "prefix", opts.prefix, err);
        return 1;
    };

    // Deliberately not `resolve`: stopping a prefix is signalling processes,
    // and that needs no Wine. A runtime is wanted only for the polite route
    // below, so an installation without one — or with an ambiguous one — can
    // still be brought down rather than being told to go and fix its
    // defaults first.
    //
    // Both halves are looked for, and neither stands in for the other. The
    // lock names the wineserver exactly; the environment names what it was
    // serving. A session whose wineserver has already died leaves the second
    // without the first, and those orphans are a large part of why this
    // command exists — keying the whole thing off the lock would report them
    // as nothing at all.
    const server_pid = try findServer(arena, px.dir, w);
    const running = try prefixProcesses(arena, px.dir, server_pid);

    if (server_pid == null and running.len == 0) {
        try w.print("Nothing is running in the prefix {s}.\n", .{px.name});
        return 0;
    }

    try w.print("The prefix {s} has ", .{px.name});
    if (server_pid) |pid| {
        try w.print("a wineserver running as pid {d}", .{pid});
        if (running.len > 0) try w.print(", serving {d} process{s}", .{
            running.len,
            if (running.len == 1) "" else "es",
        });
    } else {
        try w.print("{d} process{s} left over from a wineserver that is already gone", .{
            running.len,
            if (running.len == 1) "" else "es",
        });
    }
    try w.writeAll(".\n");

    var settled = false;
    if (!opts.force) {
        if (server_pid) |pid| {
            settled = try askNicely(arena, io, vars, sess, px, opts, pid, w);
        }
    }

    if (!settled) {
        // The wineserver first: its clients are blocked in calls to it, and
        // some of them exit on their own once it is gone.
        if (server_pid) |pid| {
            try w.print("Killing the wineserver, pid {d}.\n", .{pid});
            signal(pid, KILL);
            _ = waitFor(io, pid, reap_deadline_ms);
        }

        var left: usize = 0;
        for (running) |pid| {
            if (!alive(pid)) continue;
            signal(pid, KILL);
            left += 1;
        }
        if (left > 0) {
            try w.print("Killing {d} process{s} that did not follow it.\n", .{
                left,
                if (left == 1) "" else "es",
            });
            _ = waitForAll(io, running, reap_deadline_ms);
        }
    }

    // Saying "stopped" is only worth anything if it was checked, and checking
    // means every process rather than just the wineserver. A process the
    // kernel is holding does not die when it is killed, and calling that
    // prefix stopped would be a claim the next launch disproves.
    var stuck: std.ArrayList(std.c.pid_t) = .empty;
    if (server_pid) |pid| if (alive(pid)) try stuck.append(arena, pid);
    for (running) |pid| if (alive(pid)) try stuck.append(arena, pid);

    if (stuck.items.len > 0) {
        try w.print("\n{d} process{s} did not die:", .{
            stuck.items.len,
            if (stuck.items.len == 1) "" else "es",
        });
        for (stuck.items) |pid| try w.print(" {d}", .{pid});
        try w.writeAll(
            \\
            \\
            \\A process the kernel is holding cannot be signalled away. It goes when
            \\whatever it is waiting on returns, or when the machine restarts, and the
            \\prefix is not stopped until it does.
            \\
        );
        return 1;
    }
    try w.print("The prefix {s} is stopped.\n", .{px.name});
    return 0;
}

/// Ask the wineserver to shut down, the way Wine's own tooling does, and give
/// it a deadline. True when it went.
///
/// The deadline is the point of this: `wineserver -k` is itself a Wine
/// process, so it has to be served by the very wineserver it is asking to
/// leave. Against one that has stopped answering it does not fail — it joins
/// the queue and waits for as long as it is left to, which is why it cannot
/// be the whole of a teardown.
fn askNicely(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    sess: session.Session,
    px: session.Session.Resolved,
    opts: Options,
    server_pid: std.c.pid_t,
    w: *Io.Writer,
) !bool {
    const rt = sess.runtime(opts.runtime) catch return false;
    const server = try sess.join(&.{ rt.dir, layout.wineserver });
    if (!sess.exists(server)) return false;

    try w.writeAll("Asking it to shut down.\n");
    try w.flush();

    const computed = try env.compute(arena, sess.site(rt, px), sess.inherited(), &.{});
    for (computed) |v| try vars.put(v.name, v.value);

    var child = try std.process.spawn(io, .{ .argv = &.{ server, "-k" }, .environ_map = vars });
    if (waitFor(io, server_pid, shutdown_deadline_ms)) {
        _ = child.wait(io) catch {};
        try w.writeAll("It shut down.\n");
        return true;
    }

    // The polite request is now stuck behind the wineserver it was asking to
    // leave, so it goes with everything else.
    try w.print(
        "It did not shut down within {d} seconds, so it is not answering.\n",
        .{shutdown_deadline_ms / 1000},
    );
    child.kill(io);
    _ = child.wait(io) catch {};
    return false;
}

/// How long the wineserver is given to honour `-k` before it is treated as
/// unresponsive. Long enough for a healthy session with work to flush, short
/// enough that a wedged one does not hold the terminal.
const shutdown_deadline_ms = 5_000;

/// How long a killed process is given to be reaped before its clients are
/// dealt with. SIGKILL is not instant when the process is in the kernel.
const reap_deadline_ms = 2_000;

/// Find the wineserver serving a prefix, by asking who holds the write lock
/// on the lock file in the directory Wine made for it. Nothing is searched
/// for by name: the lock is the wineserver's own claim on the prefix, so the
/// answer is exact even with several wineservers running.
fn findServer(arena: std.mem.Allocator, prefix_dir: []const u8, w: *Io.Writer) !?std.c.pid_t {
    var st: std.c.Stat = undefined;
    const dir_z = try arena.dupeZ(u8, prefix_dir);
    if (std.c.fstatat(std.c.AT.FDCWD, dir_z, &st, 0) != 0) {
        try w.print("protium prefix stop: cannot look at {s}\n", .{prefix_dir});
        return null;
    }
    const dir = try teardown.serverDir(
        arena,
        teardown.tmp_dir,
        std.c.getuid(),
        @intCast(st.dev),
        @intCast(st.ino),
    );
    const path = try std.fs.path.join(arena, &.{ dir, teardown.lock_file });

    const path_z = try arena.dupeZ(u8, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var fl: std.c.Flock = std.mem.zeroes(std.c.Flock);
    fl.type = std.c.F.WRLCK;
    fl.whence = std.c.SEEK.SET;
    if (std.c.fcntl(fd, std.c.F.GETLK, @intFromPtr(&fl)) < 0) return null;
    if (fl.type == std.c.F.UNLCK) return null;
    return fl.pid;
}

// ---------------------------------------------------------------------------
// Asking the kernel what is running

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;

const CTL_KERN = 1;
const KERN_ARGMAX = 8;
const KERN_PROCARGS2 = 49;
const KILL = 9;

/// Declared here rather than taken from `std.posix`, which types the signal
/// as an enumeration with no member for zero — and zero is the one that asks
/// whether a process exists without disturbing it.
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;

/// Every process whose `WINEPREFIX` is this prefix, this process excluded.
/// A process whose arguments cannot be read — one belonging to another user,
/// or one that exited while we were asking — is left out rather than guessed
/// at, because the list is about to be signalled.
fn prefixProcesses(
    arena: std.mem.Allocator,
    prefix_dir: []const u8,
    except: ?std.c.pid_t,
) ![]const std.c.pid_t {
    var out: std.ArrayList(std.c.pid_t) = .empty;

    const count = proc_listallpids(null, 0);
    if (count <= 0) return out.items;
    const pids = try arena.alloc(std.c.pid_t, @intCast(count));
    const got = proc_listallpids(pids.ptr, @intCast(pids.len * @sizeOf(std.c.pid_t)));

    const buf = try arena.alloc(u8, argMax());
    const me = std.c.getpid();
    for (pids[0..teardown.pidCount(got, pids.len)]) |pid| {
        if (pid <= 0 or pid == me) continue;
        if (except) |e| if (pid == e) continue;
        const args = processArgs(pid, buf) orelse continue;
        if (teardown.belongsTo(args, prefix_dir)) try out.append(arena, pid);
    }
    return out.items;
}

/// The largest argument block the kernel will hand back, which is the size
/// the buffer for one has to be.
fn argMax() usize {
    var mib = [_]c_int{ CTL_KERN, KERN_ARGMAX };
    var value: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (std.c.sysctl(&mib, mib.len, &value, &len, null, 0) != 0) return 256 << 10;
    return @intCast(value);
}

fn processArgs(pid: std.c.pid_t, buf: []u8) ?[]const u8 {
    var mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, pid };
    var len: usize = buf.len;
    if (std.c.sysctl(&mib, mib.len, buf.ptr, &len, null, 0) != 0) return null;
    return buf[0..len];
}

fn alive(pid: std.c.pid_t) bool {
    return kill(pid, 0) == 0;
}

fn signal(pid: std.c.pid_t, sig: c_int) void {
    _ = kill(pid, sig);
}

/// Wait for every process in a list to go away, up to one shared deadline.
/// True when they all did.
fn waitForAll(io: Io, pids: []const std.c.pid_t, deadline_ms: i64) bool {
    var waited: i64 = 0;
    while (waited < deadline_ms) : (waited += poll_step_ms) {
        if (noneAlive(pids)) return true;
        io.sleep(.fromMilliseconds(poll_step_ms), .awake) catch break;
    }
    return noneAlive(pids);
}

fn noneAlive(pids: []const std.c.pid_t) bool {
    for (pids) |pid| if (alive(pid)) return false;
    return true;
}

/// Wait for a process to go away, up to a deadline. True when it did.
fn waitFor(io: Io, pid: std.c.pid_t, deadline_ms: i64) bool {
    return waitForAll(io, &.{pid}, deadline_ms);
}

/// How often a wait looks again. Short enough that a healthy shutdown is not
/// padded out, long enough not to spin.
const poll_step_ms = 50;

// ---------------------------------------------------------------------------
// prefix remove

/// Delete a prefix and everything in it.
///
/// Three things stand between the command and the unlinking, and none of them
/// is skippable by a flag:
///
///   * the path is built by `removal.prefixPath`, so it is a direct child of
///     `<root>/prefixes` and nothing else can be named;
///   * a prefix with a Wine running in it is refused, because a live
///     wineserver holds the prefix open and deleting underneath it produces a
///     half-removed tree and a process still writing into it;
///   * the tree is measured and described before anything goes.
///
/// `--force` answers the question, and only the question.
fn prefixRemove(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const opts = try parseOptions(arena, args, false);
    if (opts.bad) |b| return reportBadOption(w, "prefix remove", b);
    if (opts.positional.len == 0) {
        // Deliberately not the default prefix. Every other command falls back
        // to it, and this is the one where falling back would delete
        // something nobody named.
        try w.writeAll("protium prefix remove: name the prefix — `protium prefix remove skyrim`\n");
        try w.writeAll("There is no default here: what gets deleted is always spelled out.\n");
        return 2;
    }
    const name = opts.positional[0];

    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return 1;
        },
        else => |e| return e,
    };

    const dir = removal.prefixPath(arena, sess.root, name) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.NotAChild => {
            try w.print("protium prefix remove: {s} does not name something inside {s}/{s}\n", .{
                name, sess.root, layout.prefixes,
            });
            return 2;
        },
        error.Empty, error.Reserved, error.BadCharacter => |e| {
            try w.print("protium prefix remove: {s} is not a usable name — {s}\n", .{
                name, layout.nameProblem(e),
            });
            return 2;
        },
    };

    if (!sess.exists(dir)) {
        try w.print("protium prefix remove: there is no prefix named {s} under {s}/{s}\n", .{
            name, sess.root, layout.prefixes,
        });
        const present = try sess.installed(layout.prefixes);
        if (present.len > 0) {
            try w.writeAll("These exist:\n");
            for (present) |p| try w.print("  {s}\n", .{p});
        }
        return 1;
    }

    // A running prefix is refused rather than stopped. Stopping one means
    // signalling processes, and a command that both signals and deletes is
    // one whose failure modes cannot be reasoned about from its name. The
    // command that does it is named instead — `--force` does not change this.
    const server_pid = try findServer(arena, dir, w);
    const running = try prefixProcesses(arena, dir, server_pid);
    if (server_pid != null or running.len > 0) {
        try w.print("The prefix {s} is running: ", .{name});
        if (server_pid) |pid| {
            try w.print("a wineserver as pid {d}", .{pid});
            if (running.len > 0) try w.print(", serving {d} process{s}", .{
                running.len,
                if (running.len == 1) "" else "es",
            });
        } else {
            try w.print("{d} process{s} left over from a wineserver that is already gone", .{
                running.len,
                if (running.len == 1) "" else "es",
            });
        }
        try w.print(".\n\nStop it first:\n\n  protium prefix stop {s}\n\nNothing was deleted.\n", .{name});
        return 1;
    }

    const m = measureTree(arena, io, dir) catch |err| {
        try w.print("protium prefix remove: cannot look through {s} — {s}\n", .{ dir, @errorName(err) });
        try w.writeAll("Nothing was deleted.\n");
        return 1;
    };
    var what_buf: [256]u8 = undefined;
    const what = std.fmt.bufPrint(&what_buf, "the prefix {s}", .{name}) catch "the prefix";
    if (try describeTree(w, what, dir, m) != 0) return 1;

    if (!opts.force) {
        var question: [256]u8 = undefined;
        const prompt = std.fmt.bufPrint(&question, "Delete the prefix {s}?", .{name}) catch "Delete it?";
        if (!try confirm(io, w, prompt)) {
            try w.writeAll("Nothing was deleted.\n");
            return 1;
        }
    }

    removeTree(io, dir) catch |err| {
        try w.print("\nprotium prefix remove: {s} — {s}\n", .{ dir, @errorName(err) });
        try w.writeAll("Part of the prefix may be gone. Run the command again to finish it.\n");
        return 1;
    };

    var size_buf: [64]u8 = undefined;
    try w.print("\nDeleted {s}, freeing {s}.\n", .{ dir, fetch.size(&size_buf, m.bytes) });

    // A default naming a prefix that is no longer there is not an error any
    // command can explain: it reports "no prefix named X" and points at
    // something the user deliberately deleted.
    if (removal.clearsDefault(env.lookup(sess.defaults, "prefix"), name)) {
        try writeDefaults(sess, env.lookup(sess.defaults, "runtime"), null);
        try w.print("It was the default prefix, so `prefix` is now unset in {s}/{s}.\n", .{
            sess.root, layout.defaults_file,
        });
        const left = try sess.installed(layout.prefixes);
        if (left.len == 1) {
            try w.print("{s} is the only prefix left, so it is the default.\n", .{left[0]});
        } else if (left.len > 1) {
            try w.writeAll("Choose the next one with: protium use <name>\n");
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Removing a tree, and saying what is in it first

/// What a tree holds, gathered before anything is deleted so that the
/// confirmation describes what is actually about to go.
const Measure = struct {
    bytes: u64 = 0,
    files: usize = 0,
    dirs: usize = 0,
    links: usize = 0,
    /// Symlinks whose target is outside the tree, as `path -> target`. These
    /// are the ones worth naming: their targets survive the removal, and
    /// somebody who made one wants to be told it is being unlinked.
    outward: std.ArrayList([]const u8) = .empty,
    /// How many more of those there were than were kept.
    outward_more: usize = 0,
    /// Entries that could not be stat'ed or opened. Reported rather than
    /// counted as nothing: a size that quietly omits part of a tree is worse
    /// than no size at all.
    unreadable: usize = 0,
    /// Directories deeper than `removal.max_depth`. One of these refuses the
    /// whole removal, which is why it is found by measuring rather than
    /// half-way through deleting.
    too_deep: usize = 0,
};

/// macOS caps a single path component at 255 bytes. The walk copies each name
/// out of the iterator's buffer before it recurses, because that buffer is
/// reused, and this is how big the copy has to be.
const max_name = 255;

/// At most this many outward-pointing symlinks are listed by name.
const outward_shown = 8;

fn measureTree(arena: std.mem.Allocator, io: Io, path: []const u8) !Measure {
    var m: Measure = .{};
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    m.dirs += 1;
    try measureInto(arena, io, dir, path, path, &m, 0);
    return m;
}

/// The entry kind comes from `statFile` rather than from the directory
/// listing, and the stat does not follow links — the size counted for a
/// symlink is the link's own, never the size of what it points at. A prefix
/// holding a link to a 66 GB game install measures as the prefix.
fn measureInto(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    dir_path: []const u8,
    tree: []const u8,
    m: *Measure,
    depth: usize,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var name_buf: [max_name]u8 = undefined;
        if (entry.name.len > name_buf.len) {
            m.unreadable += 1;
            continue;
        }
        const name = name_buf[0..entry.name.len];
        @memcpy(name, entry.name);

        const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch {
            m.unreadable += 1;
            continue;
        };
        switch (removal.actionFor(st.kind)) {
            .descend => {
                if (depth + 1 >= removal.max_depth) {
                    m.too_deep += 1;
                    continue;
                }
                var sub = dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch {
                    m.unreadable += 1;
                    continue;
                };
                defer sub.close(io);
                m.dirs += 1;
                const sub_path = try std.fs.path.join(arena, &.{ dir_path, name });
                try measureInto(arena, io, sub, sub_path, tree, m, depth + 1);
            },
            .unlink, .inspect => {
                m.bytes += st.size;
                if (st.kind == .sym_link) {
                    m.links += 1;
                    try noteOutward(arena, io, dir, name, dir_path, tree, m);
                } else {
                    m.files += 1;
                }
            },
        }
    }
}

fn noteOutward(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    dir_path: []const u8,
    tree: []const u8,
    m: *Measure,
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.readLink(io, name, &buf) catch return;
    const target = buf[0..n];
    if (!try removal.pointsOutOf(arena, tree, dir_path, target)) return;
    if (m.outward.items.len >= outward_shown) {
        m.outward_more += 1;
        return;
    }
    try m.outward.append(arena, try std.fmt.allocPrint(arena, "{s}/{s} -> {s}", .{ dir_path, name, target }));
}

/// Print what is about to be deleted. Non-zero when the tree is one this
/// cannot safely remove, in which case nothing should be.
fn describeTree(w: *Io.Writer, what: []const u8, dir: []const u8, m: Measure) !u8 {
    var size_buf: [64]u8 = undefined;
    try w.print("This deletes {s}:\n\n", .{what});
    try w.print("  {s}\n", .{dir});
    try w.print("  {s}\n", .{fetch.size(&size_buf, m.bytes)});
    try w.print("  {d} file{s} in {d} director{s}\n", .{
        m.files,
        if (m.files == 1) "" else "s",
        m.dirs,
        if (m.dirs == 1) "y" else "ies",
    });
    if (m.links > 0) {
        try w.print("  {d} symlink{s}, unlinked but never followed\n", .{
            m.links,
            if (m.links == 1) "" else "s",
        });
    }
    if (m.unreadable > 0) {
        try w.print("  {d} entr{s} could not be read, and are not in that size\n", .{
            m.unreadable,
            if (m.unreadable == 1) "y" else "ies",
        });
    }

    if (m.outward.items.len > 0) {
        const total = m.outward.items.len + m.outward_more;
        try w.print("\n{d} of those link{s} out of {s}. What they point at is left\n", .{
            total,
            if (total == 1) "s" else "",
            what,
        });
        try w.writeAll("exactly as it is — only the link goes:\n\n");
        for (m.outward.items) |line| try w.print("  {s}\n", .{line});
        if (m.outward_more > 0) try w.print("  … and {d} more\n", .{m.outward_more});
    }
    try w.writeAll("\n");

    if (m.too_deep > 0) {
        try w.print("{d} director{s} nested more than {d} deep, which this will not walk.\n", .{
            m.too_deep,
            if (m.too_deep == 1) "y is" else "ies are",
            removal.max_depth,
        });
        try w.writeAll("Nothing was deleted; remove it by hand.\n");
        return 1;
    }
    return 0;
}

/// Ask before deleting.
///
/// Only `--force` skips this. A pipe with nothing behind it is refused rather
/// than answered, because the alternative — reading end-of-input as `no` — is
/// indistinguishable from a script that meant to say `yes` and forgot the
/// flag, and one of those two readings deletes a prefix.
fn confirm(io: Io, w: *Io.Writer, prompt: []const u8) !bool {
    const in = Io.File.stdin();
    if (!(in.isTty(io) catch false)) {
        try w.writeAll("Standard input is not a terminal, so there is nobody to ask.\n");
        try w.writeAll("Pass --force to delete without the question.\n");
        return false;
    }

    try w.print("{s} [y/N] ", .{prompt});
    try w.flush();

    var buf: [64]u8 = undefined;
    var reader = in.readerStreaming(io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch {
        try w.writeAll("\n");
        return false;
    };
    const answer = std.mem.trim(u8, line, " \t\r");
    return std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "yes");
}

/// Delete `path` and everything below it.
///
/// Written here rather than handed to `std.Io.Dir.deleteTree` so that the
/// rule in `removal.actionFor` is the rule that runs: a symlink is unlinked
/// and never opened, at every level, including the top one.
fn removeTree(io: Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.NotDir;
    const base = std.fs.path.basename(path);
    var dir = try Io.Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);
    try removeEntry(io, dir, base, 0);
}

/// Spelled out rather than inferred: `removeEntry` and `removeDir` call each
/// other, and Zig cannot infer an error set through that.
const RemoveError = Io.Dir.StatFileError ||
    Io.Dir.OpenError ||
    Io.Dir.Iterator.Error ||
    Io.Dir.DeleteFileError ||
    Io.Dir.DeleteDirError ||
    error{ TooDeep, NameTooLong };

fn removeEntry(io: Io, dir: Io.Dir, name: []const u8, depth: usize) RemoveError!void {
    const st = try dir.statFile(io, name, .{ .follow_symlinks = false });
    switch (removal.actionFor(st.kind)) {
        .descend => try removeDir(io, dir, name, depth),
        // `.inspect` reaches here only when a stat that already looked at the
        // entry still reported no kind. Unlinking is the recoverable guess:
        // against a directory it fails with `IsDir` and is retried as one,
        // where opening a symlink as a directory would not fail at all.
        .unlink, .inspect => dir.deleteFile(io, name) catch |err| switch (err) {
            error.IsDir => try removeDir(io, dir, name, depth),
            else => |e| return e,
        },
    }
}

fn removeDir(io: Io, dir: Io.Dir, name: []const u8, depth: usize) RemoveError!void {
    if (depth + 1 >= removal.max_depth) return error.TooDeep;

    // Entries are unlinked while the directory is being read, and a
    // filesystem is allowed to skip entries when that happens. Emptying a
    // directory is therefore a pass rather than a single sweep: repeat until
    // `deleteDir` accepts it, with a cap so that a directory something else
    // is writing into fails rather than spinning.
    var pass: usize = 0;
    while (pass < empty_passes) : (pass += 1) {
        {
            var sub = try dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
            defer sub.close(io);
            var it = sub.iterate();
            while (try it.next(io)) |entry| {
                var name_buf: [max_name]u8 = undefined;
                if (entry.name.len > name_buf.len) return error.NameTooLong;
                const child = name_buf[0..entry.name.len];
                @memcpy(child, entry.name);
                try removeEntry(io, sub, child, depth + 1);
            }
        }
        dir.deleteDir(io, name) catch |err| switch (err) {
            error.DirNotEmpty => continue,
            else => |e| return e,
        };
        return;
    }
    return error.DirNotEmpty;
}

/// How many times a directory is emptied before the removal gives up on it.
const empty_passes = 64;

// ---------------------------------------------------------------------------
// run

fn runLaunch(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const opts = try parseOptions(arena, args, true);
    if (opts.bad) |b| return reportBadOption(w, "run", b);
    if (opts.positional.len == 0) {
        try w.writeAll("protium run: name something to run — `protium run ~/Games/Setup.exe`\n");
        return 2;
    }

    const res = try resolve(arena, io, vars, opts, w) orelse return 1;
    const loader = try res.sess.join(&.{ res.runtime.dir, layout.wine_loader });
    if (!res.sess.exists(loader)) {
        try w.print("protium run: {s} does not exist, so there is no Wine to launch with.\n", .{loader});
        try w.writeAll("Run `protium status` for the next step.\n");
        return 1;
    }
    if (!res.sess.exists(try res.sess.join(&.{ res.prefix.dir, layout.boot_marker }))) {
        try w.print("protium run: the prefix {s} was never finished.\n", .{res.prefix.name});
        try w.print("Finish it with: protium prefix new {s}\n", .{res.prefix.name});
        return 1;
    }

    var problems: std.ArrayList(env.Problem) = .empty;
    const settings = try res.sess.prefixSettings(res.prefix, &problems);
    for (problems.items) |p| {
        try w.print("protium: {s}, line {d}: {s}\n", .{ layout.prefix_config, p.line, p.detail() });
        try w.print("         {s}\n", .{p.text});
    }

    const computed = try env.compute(arena, res.site, res.sess.inherited(), settings);
    for (computed) |v| try vars.put(v.name, v.value);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, loader);
    for (opts.positional) |a| try argv.append(arena, a);

    try w.flush();
    return spawnWait(io, vars, argv.items);
}

/// Run a program to completion with the current environment, giving it this
/// process's terminal, and report its exit status as our own. A signal is
/// reported the way a shell reports one, so `protium run` and `wine` are
/// indistinguishable to whatever called them.
fn spawnWait(io: Io, vars: *std.process.Environ.Map, argv: []const []const u8) !u8 {
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = vars });
    return switch (try child.wait(io)) {
        .exited => |c| c,
        .signal => |s| 128 +| @as(u8, @truncate(@intFromEnum(s))),
        .stopped, .unknown => 1,
    };
}

// ---------------------------------------------------------------------------
// install

fn runInstall(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    args: []const []const u8,
    w: *Io.Writer,
) !u8 {
    const opts = try parseOptions(arena, args, false);
    if (opts.bad) |b| return reportBadOption(w, "install", b);
    if (opts.positional.len == 0) {
        try w.writeAll("protium install: name something — `protium install steam`\n");
        try w.writeAll("`protium install list` shows everything protium knows about.\n");
        return 2;
    }

    const name = opts.positional[0];
    if (std.mem.eql(u8, name, "list")) {
        try installList(w);
        return 0;
    }
    if (std.mem.eql(u8, name, "clean")) return installClean(arena, io, vars, opts, w);

    const app = catalog.find(name) orelse {
        try w.print("protium install: nothing named `{s}` in the catalogue.\n\n", .{name});
        try installList(w);
        return 2;
    };

    // The catalogue is data, and data can be edited without running the
    // tests. Nothing is fetched over anything but TLS, checked here as well
    // as there.
    if (!catalog.isSafeUrl(app.url)) {
        try w.print("protium install: {s} is not an https:// URL, so it will not be fetched.\n", .{app.url});
        return 1;
    }

    const res = try resolve(arena, io, vars, opts, w) orelse return 1;
    const loader = try res.sess.join(&.{ res.runtime.dir, layout.wine_loader });
    if (!res.sess.exists(loader)) {
        try w.print("protium install: {s} does not exist, so there is no Wine to install into.\n", .{loader});
        try w.writeAll("Run `protium status` for the next step.\n");
        return 1;
    }
    if (!res.sess.exists(try res.sess.join(&.{ res.prefix.dir, layout.boot_marker }))) {
        try w.print("protium install: the prefix {s} was never finished.\n", .{res.prefix.name});
        try w.print("Finish it with: protium prefix new {s}\n", .{res.prefix.name});
        return 1;
    }

    // Where the program will end up, so that "already there" is answered by
    // looking rather than by a marker file protium wrote itself.
    const target = catalog.hostPath(arena, res.prefix.dir, app.installed) catch {
        try w.print("protium install: {s} names {s}, which is not on C:\n", .{ app.name, app.installed });
        return 1;
    };
    const already = res.sess.exists(target);

    try w.print("protium install {s} — {s}\n", .{ app.name, app.summary });
    try w.print("  prefix    {s}\n", .{res.prefix.name});
    try w.print("  runtime   {s}\n", .{res.runtime.name});
    try w.print("  evidence  {s}\n", .{app.confidence.label()});
    try w.writeAll("\n");
    try printIndented(w, "  ", app.evidence);
    try w.writeAll("\n");

    // Undoing is about the fix, not the install: protium never uninstalls
    // someone's software, it only puts back the file it replaced.
    if (opts.undo) {
        if (!already) {
            try w.print("{s} is not installed in this prefix, so there is nothing to undo.\n", .{app.name});
            return 1;
        }
        return undoFix(arena, io, res, app, w);
    }

    if (already and !opts.force) {
        try w.print("Already installed: {s}\n", .{app.installed});
        // The fix is still checked: Steam replaces the file protium wrote
        // whenever it updates itself, and re-running this command is how it
        // comes back.
        if (try applyFix(arena, io, res, app, w) != 0) return 1;
        try w.writeAll("Run with --force to reinstall over it.\n\n");
        try printLaunch(w, app, res.prefix.name);
        return 0;
    }

    if (try applyNeeds(arena, w, res, app) != 0) return 1;

    // The download, kept beside the prefixes: the same installer serves every
    // prefix, and the directory holds nothing that cannot be fetched again.
    const dir = try res.sess.join(&.{ res.sess.root, layout.downloads });
    try Io.Dir.cwd().createDirPath(io, dir);
    const dest = try res.sess.join(&.{ dir, app.file });

    try w.print("Fetching {s}\n", .{app.url});
    try w.flush();

    const report = fetch.download(arena, io, app.url, dest, opts.refresh) catch |err| {
        try w.print("\nprotium install: the download failed — {s}\n", .{@errorName(err)});
        try w.print("Nothing was installed. The URL is {s}\n", .{app.url});
        return 1;
    };

    var size_buf: [64]u8 = undefined;
    var hex_buf: [64]u8 = undefined;
    try w.print("  {s}{s}\n", .{ dest, if (report.reused) "  (already downloaded)" else "" });
    try w.print("  {s}\n", .{fetch.size(&size_buf, report.bytes)});
    try w.print("  sha256 {s}\n", .{report.hex(&hex_buf)});
    if (report.reused) {
        try w.writeAll("  Pass --refresh to fetch the vendor's current file instead.\n");
    }
    try w.writeAll("\n");

    // Two bytes read before anything is spawned. A 32-bit installer in a
    // prefix with an empty syswow64 fails inside Wine's loader with an exit
    // status and one line about kernel32, which is not something anyone can
    // act on; this is.
    if (try checkArch(io, res, dest, w) != 0) return 1;

    // Copied inside the prefix before it is run. An installer given a host
    // path works for a plain `.exe` and does not for an `.msi`, because
    // msiexec is handed the string rather than the loader; one route that
    // works for both is worth more than two that each work sometimes.
    const temp_rel = "drive_c/windows/temp";
    const temp_dir = try res.sess.join(&.{ res.prefix.dir, temp_rel });
    try Io.Dir.cwd().createDirPath(io, temp_dir);
    const staged = try res.sess.join(&.{ temp_dir, app.file });
    try copyFile(io, dest, staged);
    defer Io.Dir.cwd().deleteFile(io, staged) catch {};
    const windows_path = try std.fmt.allocPrint(arena, "C:\\windows\\temp\\{s}", .{app.file});

    const settings = try res.sess.prefixSettings(res.prefix, null);
    const computed = try env.compute(arena, res.site, res.sess.inherited(), settings);
    for (computed) |v| try vars.put(v.name, v.value);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, loader);
    if (catalog.isMsi(app.file)) {
        try argv.append(arena, "msiexec");
        try argv.append(arena, "/i");
    }
    try argv.append(arena, windows_path);
    for (app.installer_args) |a| try argv.append(arena, a);

    try w.writeAll("Running the installer. It is the vendor's own, and it runs as itself:\n\n  ");
    for (argv.items[1..], 0..) |a, n| {
        if (n != 0) try w.writeAll(" ");
        try w.writeAll(a);
    }
    try w.writeAll("\n\n");
    try w.flush();

    const code = try spawnWait(io, vars, argv.items);
    if (code != 0) {
        try w.print("\nThe installer exited with {d}.\n", .{code});
        try w.print("The download is kept at {s}, so a retry does not fetch it again.\n", .{dest});
        return 1;
    }

    // wineserver keeps the session — and this terminal's stdout — open after
    // an installer that started a service or a helper.
    const server = try res.sess.join(&.{ res.runtime.dir, layout.wineserver });
    if (res.sess.exists(server)) _ = try spawnWait(io, vars, &.{ server, "-w" });

    try w.writeAll("\n");
    if (res.sess.exists(target)) {
        try w.print("Installed: {s}\n", .{app.installed});
    } else {
        // Said rather than assumed: an installer can exit 0 having done
        // nothing, and a silent switch it did not understand does exactly that.
        try w.print("The installer finished, but {s} is not there.\n", .{app.installed});
        try w.writeAll("Either it installs somewhere else than the catalogue records, or it did nothing.\n");
        return 1;
    }
    if (try applyFix(arena, io, res, app, w) != 0) return 1;

    if (app.notes.len != 0) {
        try w.writeAll("\n");
        try printIndented(w, "", app.notes);
    }
    try w.writeAll("\n");
    try printLaunch(w, app, res.prefix.name);
    return 0;
}

/// Put protium's stand-in in place of the program's own file, keeping the
/// original beside it.
///
/// This is the most invasive thing `install` does, so it explains itself
/// before it acts, never deletes anything, and is undone by `--undo`. It is
/// also idempotent and self-repairing: Steam replaces the file whenever it
/// updates, and running the command again puts the fix back without losing
/// track of which copy is Valve's.
fn applyFix(
    arena: std.mem.Allocator,
    io: Io,
    res: Resolution,
    app: *const catalog.App,
    w: *Io.Writer,
) !u8 {
    const fix = app.fix orelse return 0;

    // The reason is printed once, before anything is touched, even though the
    // fix may replace several files — it is one change, argued once.
    var explained = false;
    // A file the program has not written yet is not a failure: Steam fetches
    // its second CEF tree during its own first run, so at install time one of
    // the two is normally absent. Only "none of them were there" is worth a
    // non-zero status.
    var present: usize = 0;
    var missing: usize = 0;

    for (fix.replaces) |r| {
        const target = catalog.hostPath(arena, res.prefix.dir, r.target) catch {
            try w.print("protium install: {s} is not on C:\n", .{r.target});
            return 1;
        };
        const backup = catalog.hostPath(arena, res.prefix.dir, r.backup) catch {
            try w.print("protium install: {s} is not on C:\n", .{r.backup});
            return 1;
        };
        if (!res.sess.exists(target)) {
            missing += 1;
            try w.print("\n{s} is not there yet, so there is nothing to replace.\n", .{r.target});
            try w.writeAll("Run this command again after the program has started once.\n");
            continue;
        }
        present += 1;

        switch (try stateOf(io, target)) {
            .current => {
                try w.print("\nThe fix is already in place: {s}\n", .{r.target});
                continue;
            },
            .older_standin => {
                // An earlier protium wrote this. The backup beside it is still
                // the program's own file, so it must not be overwritten with a
                // stand-in — that would lose the only copy of the real binary.
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = webhelper_shim });
                try w.print("\nUpdated protium's stand-in at {s}\n", .{r.target});
                continue;
            },
            .theirs => {},
        }

        if (!explained) {
            try w.writeAll("\nprotium is about to replace one of this program's files:\n\n");
            explained = true;
        }
        try w.print("  {s}\n", .{r.target});
        try w.print("  kept as {s}\n", .{r.backup});

        try copyFile(io, target, backup);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = webhelper_shim });
    }

    if (explained) {
        try w.writeAll("\n");
        try printIndented(w, "  ", fix.why);
        try w.writeAll("\nDone. `protium install ");
        try w.print("{s} --undo` puts the original back.\n", .{app.name});
    }
    if (present == 0 and missing != 0) return 1;
    return 0;
}

fn undoFix(
    arena: std.mem.Allocator,
    io: Io,
    res: Resolution,
    app: *const catalog.App,
    w: *Io.Writer,
) !u8 {
    const fix = app.fix orelse {
        try w.print("protium install: {s} has no fix to undo.\n", .{app.name});
        return 0;
    };
    var restored: usize = 0;
    for (fix.replaces) |r| {
        const target = try catalog.hostPath(arena, res.prefix.dir, r.target);
        const backup = try catalog.hostPath(arena, res.prefix.dir, r.backup);

        // A copy the fix never reached has nothing to put back. That is the
        // normal case for a CEF tree the program had not downloaded yet, so
        // it is skipped quietly and only a clean sweep counts as a failure.
        if (!res.sess.exists(backup)) continue;

        try copyFile(io, backup, target);
        Io.Dir.cwd().deleteFile(io, backup) catch {};
        try w.print("Restored {s}\n", .{r.target});
        restored += 1;
    }

    if (restored == 0) {
        try w.writeAll("protium install: there is nothing to restore.\n");
        try w.writeAll("Either the fix was never applied here, or it has already been undone.\n");
        return 1;
    }

    try w.writeAll("Steam will look right again on its own terms, and paint black.\n");
    try w.print("Put the fix back with: protium install {s}\n", .{app.name});
    return 0;
}

/// What is currently at the path a fix replaces.
const FixState = enum {
    /// Byte for byte the stand-in this protium carries.
    current,
    /// A stand-in from another protium: small, and carrying the switch it
    /// exists to add. Recognised so that the program's own backup is not
    /// overwritten with a stand-in.
    older_standin,
    /// The program's own file.
    theirs,
};

fn stateOf(io: Io, path: []const u8) !FixState {
    // Only ever as much as the stand-in itself: the file being examined may be
    // the program's own, which is megabytes.
    var buf: [64 * 1024]u8 = undefined;
    const limit = @min(buf.len, webhelper_shim.len + 1);
    const n = readHead(io, path, buf[0..limit]) catch return .theirs;

    if (n == webhelper_shim.len and std.mem.eql(u8, buf[0..n], webhelper_shim)) return .current;
    // A real webhelper is several megabytes, so anything that fits in the
    // buffer and mentions the switch is one of protium's.
    if (n < limit and std.mem.indexOf(u8, buf[0..n], catalog.webhelper.switch_added) != null) {
        return .older_standin;
    }
    return .theirs;
}

/// The catalogue, as a table. `confidence` is printed beside every row rather
/// than in a footnote: the difference between "this was run here" and "this
/// URL resolves" is the only thing on the line worth reading twice.
fn installList(w: *Io.Writer) !void {
    try w.writeAll("protium install\n\n");
    for (&catalog.apps) |*a| {
        try w.print("  {s: <14} {s: <10} {s}\n", .{ a.name, a.confidence.label(), a.summary });
    }
    try w.writeAll(
        \\
        \\  verified   fetched, installed and started under a Wine built from
        \\             these instructions, on a date the entry records
        \\  untested   the download is the publisher's own and resolves, and
        \\             nothing more than that
        \\  blocked    someone tried it and something specific stops it
        \\
        \\`protium install <name>` prints the evidence behind that word before it
        \\fetches anything. Nothing here is redistributed: each one is downloaded
        \\from its publisher at the moment you ask for it.
        \\
    );
}

/// Delete `<root>/downloads`, which holds the installers `protium install`
/// fetched.
///
/// The whole directory goes, rather than named entries in it: it holds the
/// publishers' own files under the names the catalogue gives them, one copy
/// serving every prefix, and nothing in it that cannot be fetched again. The
/// next `protium install` recreates it and downloads what it needs.
///
/// It is described and confirmed like a prefix removal, and it uses the same
/// walk, so a symlink somebody put in there is unlinked rather than followed.
fn installClean(
    arena: std.mem.Allocator,
    io: Io,
    vars: *std.process.Environ.Map,
    opts: Options,
    w: *Io.Writer,
) !u8 {
    const sess = session.Session.open(arena, io, vars) catch |err| switch (err) {
        error.NoHome => {
            try w.writeAll("protium: no HOME, and no PROTIUM_HOME to use instead\n");
            return 1;
        },
        else => |e| return e,
    };

    const dir = try removal.downloadsPath(arena, sess.root);
    if (!sess.exists(dir)) {
        try w.print("Nothing has been downloaded: {s} does not exist.\n", .{dir});
        return 0;
    }

    const m = measureTree(arena, io, dir) catch |err| {
        try w.print("protium install clean: cannot look through {s} — {s}\n", .{ dir, @errorName(err) });
        try w.writeAll("Nothing was deleted.\n");
        return 1;
    };
    if (m.files == 0 and m.links == 0 and m.dirs == 1) {
        try w.print("Nothing to clean: {s} is empty.\n", .{dir});
        return 0;
    }
    if (try describeTree(w, "the downloads directory", dir, m) != 0) return 1;
    try w.writeAll("Every installer in it is the publisher's own, and `protium install`\n");
    try w.writeAll("downloads what it needs again.\n\n");

    if (!opts.force and !try confirm(io, w, "Delete the downloaded installers?")) {
        try w.writeAll("Nothing was deleted.\n");
        return 1;
    }

    removeTree(io, dir) catch |err| {
        try w.print("\nprotium install clean: {s} — {s}\n", .{ dir, @errorName(err) });
        try w.writeAll("Part of it may be gone. Run the command again to finish it.\n");
        return 1;
    };

    var size_buf: [64]u8 = undefined;
    try w.print("\nDeleted {s}, freeing {s}.\n", .{ dir, fetch.size(&size_buf, m.bytes) });
    return 0;
}

/// How to start what was just installed, with the reason for every argument
/// that is not the program's own idea.
fn printLaunch(w: *Io.Writer, app: *const catalog.App, prefix_name: []const u8) !void {
    try w.writeAll("Launch it with:\n\n  protium run");
    if (!std.mem.eql(u8, prefix_name, "default")) {
        try w.print(" --prefix {s}", .{prefix_name});
    }
    try w.print(" \"{s}\"", .{app.installed});
    for (app.launch_args) |a| try w.print(" {s}", .{a.flag});
    try w.writeAll("\n");
    if (app.launch_args.len != 0) {
        try w.writeAll("\nand those arguments are there because:\n");
        for (app.launch_args) |a| {
            try w.print("\n  {s}\n", .{a.flag});
            try printWrapped(w, "      ", a.why);
        }
    }
    if (app.fix) |fix| {
        if (fix.needs_launch_args) {
            try w.writeAll(
                \\
                \\Launching it any other way undoes the fix: the program puts its own
                \\file back, and the next start paints black again. Running `protium
                \\install
            );
            try w.print(" {s}` puts it back.\n", .{app.name});
        }
    }
}

/// Add the settings the program needs to the prefix's own `protium.conf`,
/// reporting every change. A setting already present with a different value is
/// left alone and reported: the file is the person's, and a prefix that has
/// been deliberately configured is not protium's to correct.
fn applyNeeds(
    arena: std.mem.Allocator,
    w: *Io.Writer,
    res: Resolution,
    app: *const catalog.App,
) !u8 {
    if (app.needs.len == 0) return 0;

    const present = try res.sess.prefixSettings(res.prefix, null);
    const clashes = try catalog.conflictingNeeds(arena, app, present);
    for (clashes) |c| {
        try w.print("protium install: this prefix sets {s}={s}, and {s} needs {s}={s}.\n", .{
            c.need.key, c.found, app.name, c.need.key, c.need.value,
        });
        try printWrapped(w, "  ", c.need.why);
        try w.writeAll("\nNothing has been changed. Edit protium.conf, or install into another prefix.\n");
    }
    if (clashes.len != 0) return 1;

    const missing = try catalog.missingNeeds(arena, app, present);
    if (missing.len == 0) return 0;

    const path = try res.sess.join(&.{ res.prefix.dir, layout.prefix_config });
    var text: std.ArrayList(u8) = .empty;
    if (Io.Dir.cwd().readFileAlloc(res.sess.io, path, arena, .limited(1 << 16))) |existing| {
        try text.appendSlice(arena, existing);
        if (existing.len != 0 and existing[existing.len - 1] != '\n') try text.append(arena, '\n');
    } else |_| {}

    var body = std.Io.Writer.Allocating.fromArrayList(arena, &text);
    const bw = &body.writer;
    try bw.print("\n# Added by `protium install {s}`.\n", .{app.name});
    for (missing) |need| {
        try bw.print("# {s}\n", .{need.why});
        try bw.print("{s}={s}\n", .{ need.key, need.value });
    }
    try Io.Dir.cwd().writeFile(res.sess.io, .{ .sub_path = path, .data = body.written() });

    try w.print("Added to {s}:\n", .{path});
    for (missing) |need| {
        try w.print("\n  {s}={s}\n", .{ need.key, need.value });
        try printWrapped(w, "      ", need.why);
    }
    try w.writeAll("\n");
    return 0;
}

/// Can this prefix run the thing that was just downloaded?
///
/// A prefix has a 32-bit side exactly when its `syswow64` holds modules.
/// `protium prefix new` produces one that does not — `wineboot` stops before
/// it fills that directory — so a 32-bit installer in a protium-made prefix
/// cannot run, and says so in Wine's terms rather than protium's when it
/// tries. See docs/install.md.
///
/// Anything that is not a PE file is passed through rather than refused: an
/// installer format protium does not recognise is the vendor's business, and
/// guessing would block a working install.
fn checkArch(
    io: Io,
    res: Resolution,
    installer: []const u8,
    w: *Io.Writer,
) !u8 {
    var head: [4096]u8 = undefined;
    const n = readHead(io, installer, &head) catch return 0;
    const m = pe.machine(head[0..n]) catch return 0;
    if (m != .i386) return 0;

    const wow = try res.sess.join(&.{ res.prefix.dir, "drive_c", "windows", "syswow64" });
    if (!isEmptyDir(io, wow)) return 0;

    try w.print("protium install: this installer is {s}, and the prefix {s} has no 32-bit side.\n\n", .{
        m.text(), res.prefix.name,
    });
    try w.print(
        \\{s}
        \\is empty. Wine populates it while `wineboot` sets a prefix up, and on this
        \\build that step does not finish, so nothing 32-bit can start — the loader
        \\reports `could not load kernel32.dll` and the installer exits.
        \\
        \\The Wine itself is not the problem: its lib/wine/i386-windows tree is
        \\complete, and 32-bit programs do run in a prefix whose syswow64 was filled
        \\by something else. docs/install.md records what was measured.
        \\
        \\Nothing has been installed. The download is kept, so a retry costs nothing.
        \\
    , .{wow});
    return 1;
}

/// The first `buf.len` bytes of a file, or fewer if it is shorter. Not
/// `readFileAlloc`: a limit there is a maximum the whole file must fit under,
/// and every installer is far larger than its headers.
fn readHead(io: Io, path: []const u8, buf: []u8) !usize {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var filled: usize = 0;
    while (filled < buf.len) {
        var vec: [1][]u8 = .{buf[filled..]};
        const n = file.readStreaming(io, &vec) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) break;
        filled += n;
    }
    return filled;
}

/// True when `path` is a directory holding no entries. A path that is not
/// there, or cannot be opened, is not reported as empty: this decides whether
/// to refuse to run something, and refusing on a failed `openDir` would turn
/// an unrelated permissions problem into a wrong diagnosis.
fn isEmptyDir(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    const first = it.next(io) catch return false;
    return first == null;
}

fn copyFile(io: Io, from: []const u8, to: []const u8) !void {
    var src = try Io.Dir.cwd().openFile(io, from, .{});
    defer src.close(io);
    var dst = try Io.Dir.cwd().createFile(io, to, .{});
    defer dst.close(io);

    var buf: [128 * 1024]u8 = undefined;
    var vec: [1][]u8 = .{&buf};
    while (true) {
        const n = src.readStreaming(io, &vec) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) break;
        try dst.writeStreamingAll(io, buf[0..n]);
    }
}

/// Print a block of text with every line indented, so a paragraph written in
/// the catalogue keeps its shape on a terminal.
fn printIndented(w: *Io.Writer, indent: []const u8, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    // A blank line stays blank rather than becoming the indent's worth of
    // trailing spaces, which is invisible until someone pastes it somewhere.
    while (lines.next()) |line| {
        if (line.len == 0) try w.writeAll("\n") else try w.print("{s}{s}\n", .{ indent, line });
    }
}

/// Print one long sentence as indented lines that fit a terminal. The reasons
/// in the catalogue are written as sentences rather than as pre-wrapped text,
/// because they also appear in `docs/`, where the wrapping would be wrong.
fn printWrapped(w: *Io.Writer, indent: []const u8, text: []const u8) !void {
    const width = 76;
    var col: usize = indent.len;
    var first = true;
    var words = std.mem.tokenizeAny(u8, text, " \n");
    try w.writeAll(indent);
    while (words.next()) |word| {
        if (!first and col + 1 + word.len > width) {
            try w.print("\n{s}", .{indent});
            col = indent.len;
            first = true;
        }
        if (!first) {
            try w.writeAll(" ");
            col += 1;
        }
        try w.writeAll(word);
        col += word.len;
        first = false;
    }
    try w.writeAll("\n");
}

// ---------------------------------------------------------------------------
// shell-init

fn runShellInit(vars: *std.process.Environ.Map, args: []const []const u8, w: *Io.Writer) !u8 {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shell") and i + 1 < args.len) {
            i += 1;
            opts.shell = args[i];
        } else return reportBadOption(w, "shell-init", args[i]);
    }
    const dialect = try chooseDialect(vars, opts, w) orelse return 2;

    try w.writeAll(
        \\Adding one line to your shell's startup file makes every new terminal
        \\point at your default prefix, so anything you launch from it — wine, a
        \\launcher, a game — ends up in the same place without being told.
        \\
        \\
    );
    if (dialect.startupFile()) |file| {
        try w.print("Add this to {s}:\n\n", .{file});
    } else {
        try w.writeAll("Add this to your shell's startup file:\n\n");
    }
    try w.print("  {s}\n\n", .{dialect.hook()});
    try w.writeAll("Run the same line now to apply it to this terminal without opening a new one.\n");
    return 0;
}

// ---------------------------------------------------------------------------
// doctor and redist

/// The host report. Returns 0 when everything is satisfied, so a script can
/// gate on this command without reading its output.
fn runDoctor(io: Io, vars: *const std.process.Environ.Map, w: *Io.Writer) !u8 {
    var findings: [2 + toolchain.requirements.len]doctor.Finding = undefined;
    var where: [toolchain.requirements.len]?[]const u8 = @splat(null);
    var bufs: [toolchain.requirements.len][std.fs.max_path_bytes]u8 = undefined;

    findings[0] = doctor.archFinding(builtin.cpu.arch);
    findings[1] = doctor.rosettaFinding(exists(io, rosetta_marker));

    const path_var = vars.get("PATH") orelse "";
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
    return if (ok) 0 else 1;
}

/// Verify an Apple `redist/lib` tree and report what it is.
fn runRedist(gpa: std.mem.Allocator, io: Io, args: []const []const u8, w: *Io.Writer) !u8 {
    if (args.len == 0) {
        try w.writeAll("protium redist: needs a directory — the `redist/lib` from Apple's DMG\n");
        return 2;
    }
    const path = args[0];
    var into: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--into") and i + 1 < args.len) {
            i += 1;
            into = args[i];
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch {
        try w.print("protium redist: cannot open {s}\n", .{path});
        return 1;
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

    if (into) |dest| switch (redist.installStyle(hasWineModules(io, dest))) {
        .merge => try w.print(
            \\
            \\{s} holds Wine's own modules, so the tree merges into it:
            \\
            \\  ditto "{s}/" "{s}/"
            \\
            \\Apple's Read Me prefixes that with `mv external external.old; mv wine
            \\wine.old`. Do not do that here. Apple means it for a directory holding
            \\nothing but the payload — CrossOver's lib64/apple_gptk — and against a
            \\Wine module tree it moves ntdll.dll and every other module aside,
            \\leaving six shims where the Win32 implementation used to be.
            \\
            \\Wine's own d3d11, d3d12 and dxgi are overwritten, which is the point of
            \\installing D3DMetal. Copy them somewhere first if you want to A/B
            \\against WineD3D later.
            \\
        , .{ dest, path, dest }),
        .replace => try w.print(
            \\
            \\{s} holds no Wine modules, so it is a payload directory and Apple's own
            \\procedure applies — the .old copies make it a one-command revert:
            \\
            \\  cd {s}
            \\  mv external external.old; mv wine wine.old
            \\  ditto "{s}/" .
            \\
            \\`ditto` rather than `cp`, because it preserves the relative symlinks and
            \\the framework structure that the shims resolve through.
            \\
        , .{ dest, dest, path }),
    };

    return if (ok) 0 else 1;
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

/// Does `dest` hold Wine's own modules? This decides how the redistributable
/// must be installed into it, and getting it wrong destroys the Wine.
fn hasWineModules(io: Io, dest: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, dest, .{}) catch return false;
    defer d.close(io);
    d.access(io, redist.wine_module_marker, .{}) catch return false;
    return true;
}
