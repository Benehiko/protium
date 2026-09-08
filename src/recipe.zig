//! The Wine build, as data.
//!
//! `docs/wine-build.md` is the recipe written for a person; this file is the
//! same recipe written for the program, and the two are meant to be read
//! against each other. Every URL, every configure argument and every library
//! copied into the finished runtime appears here once, so that `protium
//! build` and the document cannot drift apart silently.
//!
//! Nothing here performs the build: no file is opened and no process is
//! spawned, which is what lets the whole recipe be checked by the test suite
//! on a host with no Wine, no toolchain and no network. `main.zig` carries it
//! out.
//!
//! What is deliberately *not* here is the `deps` prefix — the x86-64 FreeType,
//! GnuTLS, nettle, hogweed and GMP that Wine links against and `dlopen`s.
//! Those were built by hand and `docs/wine-build.md` records no configure line
//! for them, so protium checks for them and says what is missing rather than
//! running commands nobody has written down. See `deps` below.

const std = @import("std");

/// The Wine the CrossOver tree actually is, from `wine/VERSION`.
pub const wine_version = "11.0";
/// The CrossOver release the sources come from.
pub const crossover_version = "26.3.0";
/// The same release as it is spelled in a runtime's name.
pub const crossover_short = "26.3";

/// Something fetched over HTTPS before the build can start.
pub const Source = struct {
    /// The archive as it is saved inside `<root>/build`.
    archive: []const u8,
    url: []const u8,
    /// The exact version this URL points at, for the record. Nothing in the
    /// build is pinned to it; it is here so that a build can be quoted.
    version: []const u8,
    /// One line, printed before the fetch.
    why: []const u8,
};

/// CodeWeavers publish CrossOver's sources because the LGPL requires it. Only
/// `sources/wine` is used; the rest of the tarball is their bundled MoltenVK,
/// DXVK, vkd3d, FreeType and GStreamer, none of which this recipe touches.
pub const wine_source: Source = .{
    .archive = "crossover-sources-26.3.0.tar.gz",
    .url = "https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz",
    .version = crossover_version,
    .why = "CrossOver's published sources — 142 MB, of which only sources/wine is used",
};

/// Xcode ships bison 2.3 and Wine's configure rejects it by name, so a modern
/// one is built into the build directory rather than onto the host.
pub const bison_source: Source = .{
    .archive = "bison-3.8.2.tar.xz",
    .url = "https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz",
    .version = "3.8.2",
    .why = "Wine's parser generator; Xcode's is 2.3 and configure refuses it",
};

/// The PE half needs a mingw driver, which Apple clang does not have. This is
/// clang too, which is load-bearing rather than incidental — see `patches`
/// and docs/wine-build.md#the-pe-compiler-decides-more-than-it-looks.
pub const mingw_source: Source = .{
    .archive = "llvm-mingw-20260826-ucrt-macos-universal.tar.xz",
    .url = "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-macos-universal.tar.xz",
    .version = "20260826 (clang 23.1.0)",
    .why = "the PE cross-compiler; Apple clang has no mingw driver",
};

/// A patch applied to the extracted tree, in this order, before `configure`.
///
/// The order is the name: a runtime built with the first is `-p1`, with both
/// `-p2`, and the two are installed beside each other rather than over each
/// other so that `protium run --runtime <name>` can tell them apart.
pub const Patch = struct {
    /// The file name in `patches/`, which is also what is written into the
    /// tree's record of what has been applied.
    name: []const u8,
    /// One line, printed as it is applied.
    why: []const u8,
    /// The patch itself, embedded in the binary. protium is one file that can
    /// be copied anywhere, so a build cannot depend on a checkout being
    /// beside it.
    text: []const u8,
};

pub const patches = [_]Patch{
    .{
        .name = "0001-ntdll-test-only-the-byte-of-a-BOOLEAN-syscall-argument.patch",
        .why = "clang stores one byte for a BOOLEAN syscall argument and the unix side tests 32 bits — the Steam sign-in hang",
        .text = @embedFile("patch_0001"),
    },
    .{
        .name = "0002-advapi32-shell32-report-the-Windows-user-as-protium.patch",
        .why = "CodeWeavers hardcode the Windows user as `crossover` in three places; this makes it `protium`",
        .text = @embedFile("patch_0002"),
    },
};

/// The name the finished runtime is installed under, and the name of the
/// out-of-tree build directory that produced it. Both carry the patch level,
/// because a prefix cannot always move across that boundary: `-p2` changes the
/// Windows user, so a prefix made by `-p1` needs `protium prefix migrate-user`
/// first (docs/prefixes.md).
pub const runtime_name = std.fmt.comptimePrint(
    "wine-{s}-cx{s}-p{d}",
    .{ wine_version, crossover_short, patches.len },
);

pub const build_subdir = std.fmt.comptimePrint("build-p{d}", .{patches.len});

/// A file that must already be in `<root>/deps` before the build can start.
///
/// protium does not build these. `docs/wine-build.md` says they were "built
/// shared to a scratch prefix" and records no configure line for any of them,
/// and a command nobody has written down is not one this program should be
/// the first to run — the whole point of the project is that the environment
/// is understood rather than assumed. So the build checks, names what is
/// missing, and points at the document.
pub const Dep = struct {
    /// Relative to `<root>/deps`.
    path: []const u8,
    /// One line, printed when it is the one that is missing.
    why: []const u8,
};

pub const deps = [_]Dep{
    .{
        .path = "include/freetype2/ft2build.h",
        .why = "FreeType's headers; without them configure finds no font rasteriser",
    },
    .{
        .path = "lib/libfreetype.6.dylib",
        .why = "x86-64 FreeType, shared — Wine detects it by soname because it dlopens it, so a static library is not enough",
    },
    .{
        .path = "include/gnutls/gnutls.h",
        .why = "GnuTLS's headers; without them schannel is compiled out and no Windows program can open an encrypted socket",
    },
    .{
        .path = "lib/libgnutls.30.dylib",
        .why = "x86-64 GnuTLS, shared — Wine dlopens libgnutls.30.dylib by bare soname at run time",
    },
    .{
        .path = "lib/libnettle.8.dylib",
        .why = "GnuTLS needs it",
    },
    .{
        .path = "lib/libhogweed.6.dylib",
        .why = "GnuTLS needs it",
    },
    .{
        .path = "lib/libgmp.10.dylib",
        .why = "GnuTLS needs it",
    },
};

/// The dylibs copied into the finished runtime's `lib/`.
///
/// Recording a soname in `config.h` is not the same as having the library:
/// Wine `dlopen`s both FreeType and GnuTLS by bare soname at run time, and
/// protium puts the runtime's `lib/` on `DYLD_FALLBACK_LIBRARY_PATH` for every
/// launch. Without the files being there, a runtime whose `config.h` looks
/// right has no fonts and no TLS.
pub const bundled = [_][]const u8{
    "libfreetype.6.dylib",
    "libgnutls.30.dylib",
    "libnettle.8.dylib",
    "libhogweed.6.dylib",
    "libgmp.10.dylib",
};

/// Rewrite one copied dylib so it stands on its own.
///
/// The copies refer to each other by absolute path into the `deps` prefix, so
/// a runtime that appears to carry its own libraries breaks the day `deps` is
/// deleted. Each library gets its own `@loader_path` id, and every reference
/// it holds to another of the five is rewritten the same way. A `-change` for
/// a dependency the library does not have is a no-op, which is why the list is
/// the same for all five rather than five hand-written lists.
pub fn installNameArgv(
    gpa: std.mem.Allocator,
    deps_lib_dir: []const u8,
    lib: []const u8,
    target: []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{
        "/usr/bin/install_name_tool",
        "-id",
        try std.fmt.allocPrint(gpa, "@loader_path/{s}", .{lib}),
    });
    for (bundled) |other| {
        if (std.mem.eql(u8, other, lib)) continue;
        try argv.appendSlice(gpa, &.{
            "-change",
            try std.fs.path.join(gpa, &.{ deps_lib_dir, other }),
            try std.fmt.allocPrint(gpa, "@loader_path/{s}", .{other}),
        });
    }
    try argv.append(gpa, target);
    return argv.toOwnedSlice(gpa);
}

/// Where the pieces of the build live, under `<root>/build`.
pub const Paths = struct {
    /// `<root>/build`.
    build: []const u8,
    /// The extracted Wine tree.
    wine: []const u8,
    /// The out-of-tree build directory.
    out: []const u8,
    /// The prefix bison is installed into.
    tools: []const u8,
    /// The unpacked llvm-mingw.
    mingw: []const u8,
    /// `<root>/deps`.
    deps: []const u8,
    /// Where the finished runtime is installed.
    install: []const u8,
};

/// `PATH` for configure and make: the built bison first, then llvm-mingw,
/// then whatever the caller had.
///
/// llvm-mingw's `bin/` holds a `clang` that targets Windows, so putting it on
/// `PATH` shadows Apple clang and configure fails with `C compiler cannot
/// create executables`. That is survivable only because the host compiler is
/// pinned by absolute path in `configureArgv` below — the two rules are a
/// pair, and neither works without the other.
pub fn buildPath(gpa: std.mem.Allocator, p: Paths, inherited: ?[]const u8) ![]u8 {
    const rest = inherited orelse "/usr/bin:/bin:/usr/sbin:/sbin";
    return std.fmt.allocPrint(gpa, "{s}/bin:{s}/bin:{s}", .{ p.tools, p.mingw, rest });
}

/// The `configure` line from docs/wine-build.md, argument for argument.
pub fn configureArgv(gpa: std.mem.Allocator, p: Paths) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{
        try std.fs.path.join(gpa, &.{ p.wine, "configure" }),
        "--host=x86_64-apple-darwin",
        // The 32-bit PE modules are what 32-bit installers need; SteamSetup
        // is one, which is why `protium install` reads a PE header before
        // spawning it.
        "--enable-archs=i386,x86_64",
        "--disable-tests",
        "--with-mingw",
        try std.fmt.allocPrint(gpa, "--prefix={s}", .{p.install}),
        // Absolute, because llvm-mingw's `clang` is ahead of Apple's on PATH.
        "CC=/usr/bin/clang -arch x86_64",
        "CXX=/usr/bin/clang++ -arch x86_64",
        try std.fmt.allocPrint(gpa, "CPPFLAGS=-I{s}/include/freetype2 -I{s}/include", .{ p.deps, p.deps }),
        try std.fmt.allocPrint(gpa, "LDFLAGS=-L{s}/lib", .{p.deps}),
    });
    return argv.toOwnedSlice(gpa);
}

/// The soname added to the generated `config.h`.
///
/// `dlls/win32u/vulkan.c` refers to `SONAME_LIBVULKAN` inside a CodeWeavers
/// patch, behind no `#ifdef`, so the tree does not compile without it —
/// CodeWeavers always build against their bundled MoltenVK. D3DMetal never
/// touches Vulkan and Wine degrades gracefully when the library is absent, so
/// defining the name is sufficient: the resulting Wine really has no Vulkan
/// and Elden Ring reaches its title screen anyway.
pub const vulkan_define = "#define SONAME_LIBVULKAN \"libvulkan.1.dylib\"";

/// Whether `config.h` already carries the definition.
///
/// It has to look for the `#define`, not the name: configure leaves
/// `/* #undef SONAME_LIBVULKAN */` in the file, so a check for the bare name
/// is true before anything has been added. That mistake cost one aborted
/// build on 2026-09-08.
pub fn hasVulkanSoname(config_h: []const u8) bool {
    var it = std.mem.splitScalar(u8, config_h, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "#define SONAME_LIBVULKAN")) return true;
    }
    return false;
}

/// `config.h` with the definition added inside its include guard.
///
/// Inside, not appended: the guard's `#endif` is the last one in the file, and
/// a definition after it is a definition no translation unit ever sees.
pub fn withVulkanSoname(gpa: std.mem.Allocator, config_h: []const u8) ![]u8 {
    const guard_end = std.mem.lastIndexOf(u8, config_h, "#endif") orelse config_h.len;
    return std.fmt.allocPrint(gpa, "{s}\n{s}\n\n{s}", .{
        std.mem.trimEnd(u8, config_h[0..guard_end], " \t\r\n"),
        vulkan_define,
        config_h[guard_end..],
    });
}

const testing = std.testing;

test "the runtime is named for the Wine, the CrossOver release and the patch level" {
    // A build with both patches is -p2, and installs beside a -p1 rather than
    // over it. If a patch is added, this name changes, which is the point.
    try testing.expectEqualStrings("wine-11.0-cx26.3-p2", runtime_name);
    try testing.expectEqualStrings("build-p2", build_subdir);
}

test "every source is fetched over HTTPS from the publisher" {
    for ([_]Source{ wine_source, bison_source, mingw_source }) |s| {
        try testing.expect(std.mem.startsWith(u8, s.url, "https://"));
        // The archive name is what it is saved as, so it must be a file name
        // and not a path.
        try testing.expect(std.mem.indexOfScalar(u8, s.archive, '/') == null);
        try testing.expect(s.why.len > 0);
        try testing.expect(s.version.len > 0);
    }
    // The URL ends in the file the build then looks for.
    try testing.expect(std.mem.endsWith(u8, wine_source.url, wine_source.archive));
    try testing.expect(std.mem.endsWith(u8, bison_source.url, bison_source.archive));
    try testing.expect(std.mem.endsWith(u8, mingw_source.url, mingw_source.archive));
}

test "each patch carries its reason and its text" {
    for (patches) |p| {
        try testing.expect(p.why.len > 0);
        try testing.expect(std.mem.endsWith(u8, p.name, ".patch"));
        // Embedded rather than read from a checkout beside the binary, and it
        // is a unified diff applied with `patch -p1`, so it names `a/` and
        // `b/` paths.
        try testing.expect(std.mem.indexOf(u8, p.text, "\n--- a/") != null);
        try testing.expect(std.mem.indexOf(u8, p.text, "\n+++ b/") != null);
    }
    // The order is the patch level, and the patch level is in the runtime's
    // name, so a patch added in the middle would rename an existing build.
    try testing.expect(std.mem.startsWith(u8, patches[0].name, "0001-"));
    try testing.expect(std.mem.startsWith(u8, patches[1].name, "0002-"));
}

test "the configure line pins the host compiler by absolute path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const argv = try configureArgv(a, .{
        .build = "/r/build",
        .wine = "/r/build/wine",
        .out = "/r/build/build-p2",
        .tools = "/r/build/tools",
        .mingw = "/r/build/llvm-mingw",
        .deps = "/r/deps",
        .install = "/r/runtimes/wine-11.0-cx26.3-p2",
    });

    try testing.expectEqualStrings("/r/build/wine/configure", argv[0]);
    var saw_cc = false;
    var saw_archs = false;
    var saw_mingw = false;
    var saw_prefix = false;
    var saw_cppflags = false;
    for (argv) |arg| {
        // Not `clang`: llvm-mingw's bin/ is ahead of Apple's on PATH, and its
        // clang targets Windows.
        if (std.mem.eql(u8, arg, "CC=/usr/bin/clang -arch x86_64")) saw_cc = true;
        if (std.mem.eql(u8, arg, "--enable-archs=i386,x86_64")) saw_archs = true;
        if (std.mem.eql(u8, arg, "--with-mingw")) saw_mingw = true;
        if (std.mem.eql(u8, arg, "--prefix=/r/runtimes/wine-11.0-cx26.3-p2")) saw_prefix = true;
        if (std.mem.eql(u8, arg, "CPPFLAGS=-I/r/deps/include/freetype2 -I/r/deps/include")) saw_cppflags = true;
    }
    try testing.expect(saw_cc and saw_archs and saw_mingw and saw_prefix and saw_cppflags);
}

test "the build PATH puts the built bison and the PE compiler first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const p: Paths = .{
        .build = "/r/build",
        .wine = "/r/build/wine",
        .out = "/r/build/build-p2",
        .tools = "/r/build/tools",
        .mingw = "/r/build/llvm-mingw",
        .deps = "/r/deps",
        .install = "/r/runtimes/x",
    };
    try testing.expectEqualStrings(
        "/r/build/tools/bin:/r/build/llvm-mingw/bin:/usr/bin",
        try buildPath(a, p, "/usr/bin"),
    );
    // A caller with no PATH at all still gets a usable one, rather than a
    // build that cannot find `make`.
    try testing.expectEqualStrings(
        "/r/build/tools/bin:/r/build/llvm-mingw/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        try buildPath(a, p, null),
    );
}

test "the Vulkan soname is judged by the #define, not by the name appearing" {
    // configure leaves this behind, and it is exactly what a naive check for
    // the name would match.
    try testing.expect(!hasVulkanSoname("/* #undef SONAME_LIBVULKAN */\n"));
    try testing.expect(!hasVulkanSoname(""));
    try testing.expect(hasVulkanSoname("#define SONAME_LIBVULKAN \"libvulkan.1.dylib\"\n"));
    try testing.expect(hasVulkanSoname("  #define SONAME_LIBVULKAN \"x\"\r\n"));
}

test "the definition is added inside the include guard, where it is seen" {
    const a = testing.allocator;
    const before =
        \\#ifndef __WINE_CONFIG_H
        \\#define __WINE_CONFIG_H
        \\/* #undef SONAME_LIBVULKAN */
        \\#endif /* __WINE_CONFIG_H */
        \\
    ;
    const after = try withVulkanSoname(a, before);
    defer a.free(after);

    try testing.expect(hasVulkanSoname(after));
    const define_at = std.mem.indexOf(u8, after, vulkan_define).?;
    const endif_at = std.mem.lastIndexOf(u8, after, "#endif").?;
    try testing.expect(define_at < endif_at);
    // Adding it twice would be a second definition and a compiler warning, so
    // the caller checks first; this documents that it is the caller's job.
    try testing.expect(hasVulkanSoname(after));
}

test "every copied library is made to stand on its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const argv = try installNameArgv(a, "/r/deps/lib", "libgnutls.30.dylib", "/r/runtimes/x/lib/libgnutls.30.dylib");
    try testing.expectEqualStrings("/usr/bin/install_name_tool", argv[0]);
    try testing.expectEqualStrings("-id", argv[1]);
    try testing.expectEqualStrings("@loader_path/libgnutls.30.dylib", argv[2]);
    try testing.expectEqualStrings("/r/runtimes/x/lib/libgnutls.30.dylib", argv[argv.len - 1]);

    // The library is not rewritten to point at itself, and every other one of
    // the five is rewritten away from the deps prefix.
    var changes: usize = 0;
    for (argv, 0..) |arg, n| {
        if (!std.mem.eql(u8, arg, "-change")) continue;
        changes += 1;
        try testing.expect(std.mem.startsWith(u8, argv[n + 1], "/r/deps/lib/"));
        try testing.expect(!std.mem.eql(u8, argv[n + 1], "/r/deps/lib/libgnutls.30.dylib"));
        try testing.expect(std.mem.startsWith(u8, argv[n + 2], "@loader_path/"));
    }
    try testing.expectEqual(bundled.len - 1, changes);

    // No absolute deps path survives in what the runtime carries, or deleting
    // the deps prefix silently takes TLS with it.
    for (bundled) |lib| {
        const one = try installNameArgv(a, "/r/deps/lib", lib, "/r/runtimes/x/lib/");
        try testing.expectEqual(2 + 1 + (bundled.len - 1) * 3 + 1, one.len);
    }
}

test "every dependency the build refuses to guess at names a file and a reason" {
    for (deps) |d| {
        try testing.expect(d.why.len > 0);
        // Relative to <root>/deps, so it can be joined onto it.
        try testing.expect(!std.fs.path.isAbsolute(d.path));
    }
    // Both halves of what Wine dlopens are checked: the headers decide what
    // configure compiles in, the dylibs decide what exists at run time, and
    // having one without the other is the failure that cost a morning.
    var saw_gnutls_header = false;
    var saw_gnutls_lib = false;
    for (deps) |d| {
        if (std.mem.eql(u8, d.path, "include/gnutls/gnutls.h")) saw_gnutls_header = true;
        if (std.mem.eql(u8, d.path, "lib/libgnutls.30.dylib")) saw_gnutls_lib = true;
    }
    try testing.expect(saw_gnutls_header and saw_gnutls_lib);
}

test "every library that is bundled is one the deps prefix is checked for" {
    for (bundled) |lib| {
        var found = false;
        for (deps) |d| {
            if (std.mem.endsWith(u8, d.path, lib)) found = true;
        }
        try testing.expect(found);
    }
}
