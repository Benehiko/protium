const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Steam's user interface will not paint unless its Chromium runs the
    // display compositor in-process, and Steam forwards no switch that says
    // so. protium writes a stand-in `steamwebhelper.exe` into the prefix that
    // adds it — see src/webhelper.zig and docs/steam-rendering.md.
    //
    // It is built here, from source in this repository, by the same toolchain
    // as everything else: Zig cross-compiles to Windows without anything extra
    // being installed. Nothing is vendored and no PE is checked in.
    const webhelper = b.addExecutable(.{
        .name = "steamwebhelper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/webhelper.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            }),
            // Smallest, because it is embedded in the protium binary, and it
            // does nothing that benefits from being fast.
            .optimize = .ReleaseSmall,
        }),
    });
    // A console subsystem would put a terminal window in front of someone
    // every time Steam started a helper process.
    webhelper.subsystem = .Windows;

    const exe = b.addExecutable(.{
        .name = "protium",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Embedded rather than installed beside the binary: protium stays one file
    // that can be copied anywhere, and cannot be run against a stand-in from a
    // different version of itself.
    exe.root_module.addAnonymousImport("webhelper_shim", .{
        .root_source_file = webhelper.getEmittedBin(),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run protium").dependOn(&run.step);

    // Tests are rooted at src/root.zig, which imports every file. A file that
    // nothing imports has its tests silently skipped, so the root is the one
    // place that decides what is tested — watch the test count, not just the
    // exit status.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
        }),
    });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
