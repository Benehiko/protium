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
    \\  protium run <program> [args...]   Launch something in the default prefix.
    \\  protium prefix list               Show the prefixes and which is default.
    \\  protium prefix new <name>         Create a prefix and boot it.
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
    try bw.writeAll("# Written by `protium use`. KEY=VALUE, one per line; `#` is a comment.\n");
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

    try w.print("protium prefix: no such subcommand `{s}` — try `list` or `new`\n", .{sub});
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
