//! Reading an installation off the disk: which root, which runtime, which
//! prefix, and what the prefix's own settings say.
//!
//! This is the second I/O edge, alongside `main.zig`. It opens directories and
//! reads files; it decides nothing. Every choice it appears to make is
//! delegated to `layout` or `env`, which are testable without an installation
//! to point them at.

const std = @import("std");
const Io = std.Io;

const layout = @import("layout.zig");
const env = @import("env.zig");
const redist = @import("redist.zig");
const plist = @import("plist.zig");
const status = @import("status.zig");

pub const Session = struct {
    arena: std.mem.Allocator,
    io: Io,
    vars: *const std.process.Environ.Map,
    root: []const u8,
    /// The root's `defaults` file, already parsed. Missing is not an error:
    /// an installation with one runtime and one prefix never needs it.
    defaults: []const env.Setting,

    /// A name asked for on the command line, or in the environment, or
    /// recorded as the default — whichever applies — resolved against what is
    /// actually installed.
    pub const Resolved = struct {
        name: []const u8,
        dir: []const u8,
    };

    pub fn open(
        arena: std.mem.Allocator,
        io: Io,
        vars: *const std.process.Environ.Map,
    ) (layout.RootError || error{OutOfMemory})!Session {
        const root = try layout.resolveRoot(
            arena,
            vars.get("PROTIUM_HOME"),
            vars.get("XDG_DATA_HOME"),
            vars.get("HOME"),
        );
        var s: Session = .{
            .arena = arena,
            .io = io,
            .vars = vars,
            .root = root,
            .defaults = &.{},
        };
        s.defaults = s.readSettings(root, layout.defaults_file, null) catch &.{};
        return s;
    }

    pub fn join(s: Session, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(s.arena, parts);
    }

    pub fn exists(s: Session, path: []const u8) bool {
        Io.Dir.cwd().access(s.io, path, .{}) catch return false;
        return true;
    }

    /// The directories directly inside `<root>/<sub>`, sorted. A root that
    /// does not exist yet lists as empty rather than failing, because "not
    /// installed" is a state `status` reports rather than an error.
    pub fn installed(s: Session, sub: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const path = try s.join(&.{ s.root, sub });
        var dir = Io.Dir.cwd().openDir(s.io, path, .{ .iterate = true }) catch return out.items;
        defer dir.close(s.io);

        var it = dir.iterate();
        while (try it.next(s.io)) |entry| {
            switch (entry.kind) {
                .directory, .sym_link => {},
                else => continue,
            }
            // A name protium would refuse to create is not one it should
            // offer to use either.
            layout.checkName(entry.name) catch continue;
            try out.append(s.arena, try s.arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, out.items, {}, lessThan);
        return out.items;
    }

    /// Resolve a runtime: what was asked for, else `$PROTIUM_RUNTIME`, else
    /// the recorded default, else the only one installed.
    pub fn runtime(s: Session, asked: ?[]const u8) !Resolved {
        return s.resolveIn(layout.runtimes, "PROTIUM_RUNTIME", "runtime", asked);
    }

    /// Resolve a prefix, by the same rules.
    pub fn prefix(s: Session, asked: ?[]const u8) !Resolved {
        return s.resolveIn(layout.prefixes, "PROTIUM_PREFIX", "prefix", asked);
    }

    fn resolveIn(
        s: Session,
        sub: []const u8,
        var_name: []const u8,
        default_key: []const u8,
        asked: ?[]const u8,
    ) !Resolved {
        const present = try s.installed(sub);
        const name = try layout.choose(
            asked,
            s.vars.get(var_name),
            env.lookup(s.defaults, default_key),
            present,
        );
        layout.checkName(name) catch return error.BadName;
        const dir = try s.join(&.{ s.root, sub, name });
        if (!s.exists(dir)) return error.NoSuchName;
        // Duped because `choose` may have returned a slice into the process's
        // own environment block, and this name is later written back into that
        // same block. Owning it here keeps that from being an aliasing
        // question that depends on the order of operations inside a `put`.
        return .{ .name = try s.arena.dupe(u8, name), .dir = dir };
    }

    pub fn site(s: Session, rt: Resolved, px: Resolved) env.Site {
        _ = s;
        return .{
            .runtime_name = rt.name,
            .runtime_dir = rt.dir,
            .prefix_name = px.name,
            .prefix_dir = px.dir,
        };
    }

    /// What the calling shell already had, which the computed environment adds
    /// to rather than replaces.
    pub fn inherited(s: Session) env.Inherited {
        return .{
            .path = s.vars.get("PATH"),
            .dyld_fallback = s.vars.get("DYLD_FALLBACK_LIBRARY_PATH"),
        };
    }

    /// A prefix's own `protium.conf`, if it has one. Problems are appended to
    /// `problems` when it is given, so a caller that can print them does, and
    /// `env` — which is evaluated by a shell and cannot print prose — does not.
    pub fn prefixSettings(
        s: Session,
        px: Resolved,
        problems: ?*std.ArrayList(env.Problem),
    ) ![]const env.Setting {
        return s.readSettings(px.dir, layout.prefix_config, problems) catch &.{};
    }

    fn readSettings(
        s: Session,
        dir_path: []const u8,
        name: []const u8,
        problems: ?*std.ArrayList(env.Problem),
    ) ![]const env.Setting {
        var dir = try Io.Dir.cwd().openDir(s.io, dir_path, .{});
        defer dir.close(s.io);
        // The arena keeps the text alive, which the settings slice into.
        const text = try dir.readFileAlloc(s.io, name, s.arena, .limited(1 << 16));

        var settings: std.ArrayList(env.Setting) = .empty;
        var discard: std.ArrayList(env.Problem) = .empty;
        try env.parse(s.arena, text, &settings, problems orelse &discard);
        return settings.items;
    }

    /// D3DMetal's version, read from the framework merged into a runtime, or
    /// null when the runtime has no D3DMetal in it.
    pub fn d3dmetalVersion(s: Session, rt: Resolved) ?[]const u8 {
        const lib = s.join(&.{ rt.dir, layout.lib_dir }) catch return null;
        if (!s.exists(std.fs.path.join(s.arena, &.{ lib, redist.shared_library }) catch return null)) {
            return null;
        }
        var dir = Io.Dir.cwd().openDir(s.io, lib, .{}) catch return null;
        defer dir.close(s.io);
        const xml = dir.readFileAlloc(s.io, redist.framework_plist, s.arena, .limited(1 << 20)) catch return null;
        return plist.stringValue(xml, "CFBundleShortVersionString") orelse "unknown";
    }

    /// Everything `status` needs, observed rather than assumed.
    pub fn observe(s: Session, rt: ?Resolved, rt_err: ?anyerror, px: ?Resolved, px_err: ?anyerror) status.State {
        var state: status.State = .{
            .root_usable = layout.rootIsUsable(s.root),
            .runtime_ambiguous = failedWith(rt_err, error.Ambiguous),
            .prefix_ambiguous = failedWith(px_err, error.Ambiguous),
            .shell_active = s.vars.get("PROTIUM_PREFIX") != null,
        };
        if (rt) |r| {
            state.wine_installed = s.exists(s.join(&.{ r.dir, layout.wine_loader }) catch "");
            state.d3dmetal_installed = s.d3dmetalVersion(r) != null;
        }
        if (px) |p| {
            state.prefix_exists = true;
            state.prefix_booted = s.exists(s.join(&.{ p.dir, layout.boot_marker }) catch "");
        }
        return state;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn failedWith(maybe: ?anyerror, want: anyerror) bool {
    const err = maybe orelse return false;
    return err == want;
}
