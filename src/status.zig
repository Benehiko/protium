//! Is this installation finished, and if not, what is the single next thing
//! to do?
//!
//! `doctor` answers a different question and answers it differently: it lists
//! every missing prerequisite at once, because that is a shopping list and
//! someone can fill it in one pass. An installation is not a list — each step
//! depends on the one before it, and there is no use telling someone to boot a
//! prefix they cannot create yet. So this file reports one step, and the order
//! it walks is the whole of its logic.

const std = @import("std");

/// What has been observed about an installation. Every field is something the
/// caller looked up; nothing here does the looking.
pub const State = struct {
    /// Wine's install rules do not quote paths, so a root containing a space
    /// cannot hold a runtime at all. This outranks everything else, because
    /// every later step would fail inside it.
    root_usable: bool = true,
    /// More than one runtime, or more than one prefix, with nothing recorded
    /// to pick between them.
    runtime_ambiguous: bool = false,
    prefix_ambiguous: bool = false,
    /// A runtime directory holding a `bin/wine`.
    wine_installed: bool = false,
    /// D3DMetal merged into that runtime: `lib/external/libd3dshared.dylib`.
    d3dmetal_installed: bool = false,
    /// A prefix directory exists.
    prefix_exists: bool = false,
    /// …and `wineboot` has finished with it, which `system.reg` records.
    prefix_booted: bool = false,
    /// This protium process inherited `PROTIUM_PREFIX`, which is true exactly
    /// when the shell hook is in effect in the shell that ran it.
    shell_active: bool = false,
};

pub const Step = enum {
    move_root,
    install_wine,
    install_d3dmetal,
    choose_runtime,
    create_prefix,
    boot_prefix,
    choose_prefix,
    install_shell_hook,
    ready,

    /// What to run, or `null` when the step is not a single command.
    pub fn command(s: Step) ?[]const u8 {
        return switch (s) {
            .move_root => null,
            .install_wine => null,
            .install_d3dmetal => "protium redist <apple-redist-lib> --into <runtime>/lib",
            .choose_runtime => "protium use --runtime <name>",
            .create_prefix => "protium prefix new default",
            .boot_prefix => "protium prefix new <name>",
            .choose_prefix => "protium use <name>",
            .install_shell_hook => "protium shell-init",
            .ready => "protium run <path-to-game.exe>",
        };
    }

    /// One line saying why this is next.
    pub fn why(s: Step) []const u8 {
        return switch (s) {
            .move_root => "the root holds a space, and Wine's install rules do not quote paths — set PROTIUM_HOME to a path without one",
            .install_wine => "no Wine yet; build one from CodeWeavers' sources and install it into <root>/runtimes/<name> — see docs/wine-build.md",
            .install_d3dmetal => "the Wine has no D3DMetal, so a Direct3D game will render nothing — see docs/d3dmetal.md",
            .choose_runtime => "several runtimes are installed and none is recorded as the default",
            .create_prefix => "no prefix yet; a prefix is the Windows installation your games live in",
            .boot_prefix => "the prefix exists but was never finished — re-run the command that creates it",
            .choose_prefix => "several prefixes exist and none is recorded as the default",
            .install_shell_hook => "the environment is complete; add the shell hook so every new terminal inherits it",
            .ready => "everything is set up, and this shell is pointed at it",
        };
    }
};

/// Walk the installation in dependency order and return the first thing that
/// is not done.
pub fn nextStep(s: State) Step {
    if (!s.root_usable) return .move_root;
    if (s.runtime_ambiguous) return .choose_runtime;
    if (!s.wine_installed) return .install_wine;
    if (!s.d3dmetal_installed) return .install_d3dmetal;
    if (s.prefix_ambiguous) return .choose_prefix;
    if (!s.prefix_exists) return .create_prefix;
    if (!s.prefix_booted) return .boot_prefix;
    if (!s.shell_active) return .install_shell_hook;
    return .ready;
}

const testing = std.testing;

const complete: State = .{
    .wine_installed = true,
    .d3dmetal_installed = true,
    .prefix_exists = true,
    .prefix_booted = true,
    .shell_active = true,
};

test "a finished installation with the hook in effect has nothing left to do" {
    try testing.expectEqual(Step.ready, nextStep(complete));
}

test "the steps are reported in the order they can actually be done" {
    var s = complete;
    s.shell_active = false;
    try testing.expectEqual(Step.install_shell_hook, nextStep(s));
    s.prefix_booted = false;
    try testing.expectEqual(Step.boot_prefix, nextStep(s));
    s.prefix_exists = false;
    try testing.expectEqual(Step.create_prefix, nextStep(s));
    s.d3dmetal_installed = false;
    try testing.expectEqual(Step.install_d3dmetal, nextStep(s));
    s.wine_installed = false;
    try testing.expectEqual(Step.install_wine, nextStep(s));
}

test "an unusable root outranks everything, because every later step fails inside it" {
    var s = complete;
    s.root_usable = false;
    try testing.expectEqual(Step.move_root, nextStep(s));
}

test "a graphics-less Wine is reported before a prefix is suggested for it" {
    // Wine alone launches a Direct3D 12 game and renders nothing, so being
    // told to create a prefix first would send someone to a black window.
    const s: State = .{ .wine_installed = true, .prefix_exists = true, .prefix_booted = true };
    try testing.expectEqual(Step.install_d3dmetal, nextStep(s));
}

test "ambiguity is resolved before the thing it is ambiguous about is used" {
    const runtimes: State = .{ .runtime_ambiguous = true, .wine_installed = true };
    try testing.expectEqual(Step.choose_runtime, nextStep(runtimes));

    var prefixes = complete;
    prefixes.prefix_ambiguous = true;
    try testing.expectEqual(Step.choose_prefix, nextStep(prefixes));
}

test "every step says why, and all but the two manual ones name a command" {
    for (std.enums.values(Step)) |s| {
        try testing.expect(s.why().len != 0);
        switch (s) {
            .move_root, .install_wine => try testing.expectEqual(@as(?[]const u8, null), s.command()),
            else => try testing.expect(s.command().?.len != 0),
        }
    }
}
