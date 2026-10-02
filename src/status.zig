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
    /// Rosetta 2 is installed. protium's Wine is x86-64, so nothing after
    /// this runs without it.
    rosetta: bool = true,
    /// This protium was released with a runtime it can install, rather than
    /// being a development build that has only `protium build` to offer.
    runtime_published: bool = false,
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
    install_rosetta,
    install_runtime,
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
            .install_rosetta => "softwareupdate --install-rosetta",
            .install_runtime => "protium runtime install",
            .install_wine => "protium build",
            .install_d3dmetal => "protium d3dmetal install",
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
            .install_rosetta => "Rosetta 2 is not installed, and protium's Wine is x86-64, so nothing in it can run; `protium runtime install` offers it too",
            .install_runtime => "no Wine yet; this installs the one this release was built with, after checking its SHA-256",
            .install_wine => "no Wine yet, and this development build has no published one; `protium build` fetches CodeWeavers' sources and builds one",
            .install_d3dmetal => "the Wine has no D3DMetal, so a Direct3D game will render nothing — save Apple's Game_Porting_Toolkit_*.dmg (https://developer.apple.com/games/game-porting-toolkit/) in ~/Downloads, or give its path",
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
    if (!s.rosetta) return .install_rosetta;
    if (s.runtime_ambiguous) return .choose_runtime;
    if (!s.wine_installed) return if (s.runtime_published) .install_runtime else .install_wine;
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

test "a release build offers its runtime, a development build the build" {
    var s = complete;
    s.wine_installed = false;
    s.d3dmetal_installed = false;
    try testing.expectEqual(Step.install_wine, nextStep(s));
    s.runtime_published = true;
    try testing.expectEqual(Step.install_runtime, nextStep(s));
    try testing.expectEqualStrings("protium runtime install", Step.install_runtime.command().?);
}

test "Rosetta comes before everything but the root" {
    var s: State = .{ .rosetta = false, .runtime_published = true };
    try testing.expectEqual(Step.install_rosetta, nextStep(s));
    s.root_usable = false;
    try testing.expectEqual(Step.move_root, nextStep(s));
    s = complete;
    s.rosetta = false;
    try testing.expectEqual(Step.install_rosetta, nextStep(s));
}

test "the D3DMetal step says where Apple's download goes" {
    try testing.expect(std.mem.indexOf(u8, Step.install_d3dmetal.why(), "~/Downloads") != null);
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

test "every step says why, and all but the one manual step names a command" {
    for (std.enums.values(Step)) |s| {
        try testing.expect(s.why().len != 0);
        switch (s) {
            // Moving the root is a decision about where a disk's worth of files
            // belongs, and no command protium could print would make it.
            .move_root => try testing.expectEqual(@as(?[]const u8, null), s.command()),
            else => try testing.expect(s.command().?.len != 0),
        }
    }
}
