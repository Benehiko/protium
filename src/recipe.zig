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
//! The `deps` prefix — the x86-64 FreeType, GnuTLS, nettle, hogweed and GMP
//! that Wine links against and `dlopen`s — is here too, as `dep_builds`. The
//! first one was built by hand and nothing recorded how; the configure lines
//! below are the ones that rebuilt it on 2026-09-30 and matched it. See
//! docs/wine-build.md#the-deps-prefix.

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
    /// The exact version this URL points at, for the record.
    version: []const u8,
    /// The archive's SHA-256, lower-case hex. A download that does not match
    /// is refused before anything is unpacked. See the table in
    /// docs/wine-build.md#toolchain for how each was checked.
    sha256: []const u8,
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
    .sha256 = "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872",
    .why = "CrossOver's published sources — 142 MB, of which only sources/wine is used",
};

/// Xcode ships bison 2.3 and Wine's configure rejects it by name, so a modern
/// one is built into the build directory rather than onto the host.
pub const bison_source: Source = .{
    .archive = "bison-3.8.2.tar.xz",
    .url = "https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz",
    .version = "3.8.2",
    .sha256 = "9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2",
    .why = "Wine's parser generator; Xcode's is 2.3 and configure refuses it",
};

/// The PE half needs a mingw driver, which Apple clang does not have. This is
/// clang too, which is load-bearing rather than incidental — see `patches`
/// and docs/wine-build.md#the-pe-compiler-decides-more-than-it-looks.
pub const mingw_source: Source = .{
    .archive = "llvm-mingw-20260826-ucrt-macos-universal.tar.xz",
    .url = "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-macos-universal.tar.xz",
    .version = "20260826 (clang 23.1.0)",
    .sha256 = "48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f",
    .why = "the PE cross-compiler; Apple clang has no mingw driver",
};

/// Wine Mono, Wine's own .NET runtime, fetched for `protium prefix new` rather
/// than for the build.
///
/// `wineboot` installs it into every new prefix. When it cannot find the
/// installer it opens a "download Wine Mono?" dialog and waits, which on a
/// machine nobody is watching is forever (the 2026-10-01 CI run). It looks,
/// in order, in a registry-named directory, in the runtime's
/// `share/wine/mono`, and then in `$WINE_HOST_XDG_CACHE_HOME/wine/`, which
/// Wine fills from the Unix `XDG_CACHE_HOME`; only that last one is checked
/// against the hash (`dlls/appwiz.cpl/addons.c`). protium uses the cache: the
/// runtime is what gets published, and protium does not redistribute this.
///
/// The version and the hash are the ones this Wine pins: `MONO_VERSION` and
/// `MONO_SHA` in `dlls/appwiz.cpl/addons.c` of CrossOver 26.3.0's tree. Wine's
/// own URL is plain HTTP; WineHQ serves the same file over HTTPS.
pub const wine_mono: Source = .{
    .archive = "wine-mono-10.4.1-x86.msi",
    .url = "https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.msi",
    .version = "10.4.1",
    .sha256 = "071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23",
    .why = "Wine's .NET runtime, which wineboot otherwise stops to ask about",
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
/// `dep_builds` builds whichever are missing; this list is what the build
/// then checks for before configuring Wine, because a library build can
/// finish and still not produce one.
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

/// One library of the `deps` prefix, built from its published source into it.
///
/// These are the commands the 2026-09-30 rebuild ran, one for one, and the
/// result matched the hand-built prefix the working runtime came from: same
/// versions, `x86_64`, the same `otool -L`, the same exported symbols, the
/// same headers. docs/wine-build.md#the-deps-prefix has the comparison.
pub const DepBuild = struct {
    name: []const u8,
    source: Source,
    /// Relative to `<root>/deps`. All of them present means this library is
    /// built and is skipped, which is how a prefix built by hand is kept.
    produces: []const []const u8,
    /// Passed after `dep_common_args`.
    configure: []const []const u8,
    /// Relative to the source tree: a file `configure` writes and the
    /// archive does not carry, so its presence means configure has run.
    configured: []const u8 = "config.status",
    /// Libraries already in the prefix that this configure is told about
    /// through `<VAR>_CFLAGS` and `<VAR>_LIBS` in the environment. GnuTLS's
    /// configure does not record these as its own variables (they are not in
    /// its `ac_precious_vars`), so they cannot go on the command line.
    links: []const Link = &.{},
};

pub const Link = struct {
    /// `GMP` for `GMP_CFLAGS` and `GMP_LIBS`.
    variable: []const u8,
    /// `gmp` for `-lgmp`.
    lib: []const u8,
};

/// In build order: each one links against the ones before it.
pub const dep_builds = [_]DepBuild{
    .{
        .name = "GMP",
        .source = .{
            .archive = "gmp-6.3.0.tar.xz",
            .url = "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz",
            .version = "6.3.0",
            .sha256 = "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898",
            .why = "big-number arithmetic, which Nettle's public-key half needs",
        },
        .produces = &.{ "include/gmp.h", "lib/libgmp.10.dylib" },
        .configure = &.{},
    },
    .{
        .name = "Nettle",
        .source = .{
            .archive = "nettle-3.10.tar.gz",
            .url = "https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz",
            .version = "3.10",
            .sha256 = "b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c",
            .why = "the ciphers and hashes GnuTLS is built on (libnettle and libhogweed)",
        },
        .produces = &.{ "include/nettle/nettle-meta.h", "lib/libnettle.8.dylib", "lib/libhogweed.6.dylib" },
        // Its assembly is the "fat" kind, choosing by CPUID at run time, which
        // is the right thing under Rosetta.
        .configure = &.{ "--disable-documentation", "--disable-openssl" },
    },
    .{
        .name = "GnuTLS",
        .source = .{
            .archive = "gnutls-3.8.4.tar.xz",
            .url = "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.4.tar.xz",
            .version = "3.8.4",
            .sha256 = "2bea4e154794f3f00180fa2a5c51fe8b005ac7a31cd58bd44cdfa7f36ebc3a9b",
            .why = "TLS for Wine's schannel; without it no Windows program can open an encrypted socket",
        },
        .produces = &.{ "include/gnutls/gnutls.h", "lib/libgnutls.30.dylib" },
        .configure = &.{
            // Its own copies, so nothing from Homebrew (arm64, and not ours
            // to ship) can be picked up.
            "--with-included-libtasn1",
            "--with-included-unistring",
            // Wine needs the library and nothing optional. `--without-zlib`
            // loses nothing: GnuTLS's zlib support dlopens `libz.so.1`, a
            // Linux name that never resolves on macOS.
            "--without-p11-kit",
            "--without-idn",
            "--without-brotli",
            "--without-zstd",
            "--without-zlib",
            "--without-tpm",
            "--without-tpm2",
            "--disable-nls",
            "--disable-cxx",
            "--disable-doc",
            "--disable-tests",
            "--disable-tools",
            "--disable-manpages",
        },
        .links = &.{
            .{ .variable = "GMP", .lib = "gmp" },
            .{ .variable = "NETTLE", .lib = "nettle" },
            .{ .variable = "HOGWEED", .lib = "hogweed" },
        },
    },
    .{
        .name = "FreeType",
        .source = .{
            .archive = "freetype-2.13.3.tar.xz",
            .url = "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz",
            .version = "2.13.3",
            .sha256 = "0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289",
            .why = "Wine's font rasteriser; without it every Win32 window paints blank",
        },
        .produces = &.{ "include/freetype2/ft2build.h", "lib/libfreetype.6.dylib" },
        // FreeType's archive ships a top-level Makefile and its configure
        // runs from `builds/unix`, which is where it leaves what it made.
        .configured = "builds/unix/config.status",
        // zlib and bzip2 are the system's; the rest are off so that what is
        // linked does not depend on what else is installed.
        .configure = &.{
            "--with-zlib=yes",
            "--with-bzip2=yes",
            "--with-png=no",
            "--with-harfbuzz=no",
            "--with-brotli=no",
        },
    },
};

/// The arguments every library's `configure` gets. `--host` because the
/// build machine is arm64 and these are x86-64; Rosetta runs configure's test
/// programs, so it is not a cross-compile in practice.
pub const dep_common_args = [_][]const u8{
    "--host=x86_64-apple-darwin",
    "--enable-shared",
    "--disable-static",
};

pub fn depConfigureArgv(gpa: std.mem.Allocator, deps_dir: []const u8, d: DepBuild) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, "./configure");
    try argv.appendSlice(gpa, &dep_common_args);
    try argv.append(gpa, try std.fmt.allocPrint(gpa, "--prefix={s}", .{deps_dir}));
    try argv.appendSlice(gpa, d.configure);
    return argv.toOwnedSlice(gpa);
}

pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// Variables removed from the inherited environment before a library is
/// built: each one can point the compiler or pkg-config at a Homebrew
/// library, which is arm64 and would either fail to link or, worse, be found.
pub const dep_env_cleared = [_][]const u8{
    "CPATH",
    "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH",
    "LIBRARY_PATH",
    "PKG_CONFIG",
    "PKG_CONFIG_SYSROOT_DIR",
};

/// What is set on top of the inherited environment to build `d`.
///
/// `PATH` is the system's alone, the compiler is Apple's by absolute path,
/// and pkg-config is confined to the prefix being built.
/// The oldest macOS a runtime built by this recipe loads on: the current
/// release and the one before it, macOS 26 and macOS 15.
///
/// Apple's compiler and linker stamp every Mach-O with the minimum OS it may
/// run on, taken from `MACOSX_DEPLOYMENT_TARGET` and otherwise from the
/// machine doing the build. Left unset, a runtime built on macOS 26 says
/// `minos 26.0` in every binary and macOS 15 refuses to load any of it. It is
/// set for the libraries in `deps` and for Wine's unix side alike, because
/// one library newer than the rest is enough to take the runtime down. Wine's
/// own loader and preloader pin `10.7` themselves, which is older and so
/// harmless. The PE side is Windows code and is not affected.
pub const macos_min = "15.0";

/// What is set on top of the inherited environment for the Wine build itself:
/// bison, configure, make and the install. `dep_env_cleared` is removed as
/// well.
///
/// pkg-config is confined to `deps` for the same reason as in `depEnv`. Wine's
/// configure asks it for FreeType's and GnuTLS's flags, and a Homebrew copy
/// answers first: on the GitHub runner, Homebrew's arm64 FreeType put
/// `-L/opt/homebrew/opt/freetype/lib` ahead of `deps`, and linking
/// `tools/sfnt2fon` found no FreeType for x86_64 at all. On a Mac whose
/// Homebrew has `gnutls.pc`, the same leak hands configure Homebrew's GnuTLS
/// headers instead of the 3.8.4 the runtime carries.
pub fn wineEnv(gpa: std.mem.Allocator, p: Paths) ![]const EnvVar {
    return gpa.dupe(EnvVar, &.{
        .{ .name = "MACOSX_DEPLOYMENT_TARGET", .value = macos_min },
        .{ .name = "PKG_CONFIG_LIBDIR", .value = try std.fmt.allocPrint(gpa, "{s}/lib/pkgconfig", .{p.deps}) },
        .{ .name = "PKG_CONFIG_PATH", .value = "" },
    });
}

pub fn depEnv(gpa: std.mem.Allocator, deps_dir: []const u8, d: DepBuild) ![]const EnvVar {
    var env: std.ArrayList(EnvVar) = .empty;
    const include = try std.fmt.allocPrint(gpa, "-I{s}/include", .{deps_dir});
    try env.appendSlice(gpa, &.{
        .{ .name = "PATH", .value = "/usr/bin:/bin:/usr/sbin:/sbin" },
        .{ .name = "CC", .value = "/usr/bin/clang -arch x86_64" },
        .{ .name = "CXX", .value = "/usr/bin/clang++ -arch x86_64" },
        .{ .name = "CFLAGS", .value = "-O2" },
        .{ .name = "CPPFLAGS", .value = include },
        .{ .name = "LDFLAGS", .value = try std.fmt.allocPrint(gpa, "-L{s}/lib", .{deps_dir}) },
        .{ .name = "PKG_CONFIG_LIBDIR", .value = try std.fmt.allocPrint(gpa, "{s}/lib/pkgconfig", .{deps_dir}) },
        .{ .name = "PKG_CONFIG_PATH", .value = "" },
        .{ .name = "MACOSX_DEPLOYMENT_TARGET", .value = macos_min },
    });
    for (d.links) |l| {
        try env.append(gpa, .{ .name = try std.fmt.allocPrint(gpa, "{s}_CFLAGS", .{l.variable}), .value = include });
        try env.append(gpa, .{
            .name = try std.fmt.allocPrint(gpa, "{s}_LIBS", .{l.variable}),
            .value = try std.fmt.allocPrint(gpa, "-L{s}/lib -l{s}", .{ deps_dir, l.lib }),
        });
    }
    return env.toOwnedSlice(gpa);
}

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

fn isSha256Hex(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test "every source, the libraries' included, is HTTPS and pinned by hash" {
    var all: [3 + dep_builds.len]Source = undefined;
    all[0] = wine_source;
    all[1] = bison_source;
    all[2] = mingw_source;
    for (dep_builds, 0..) |d, i| all[3 + i] = d.source;
    for (all) |s| {
        try testing.expect(std.mem.startsWith(u8, s.url, "https://"));
        try testing.expect(std.mem.endsWith(u8, s.url, s.archive));
        // Lower-case, because that is how the build prints the digest it
        // computed, and the two are compared as strings.
        try testing.expect(isSha256Hex(s.sha256));
        // The tree is found by the archive's stem, so it must have one.
        try testing.expect(std.mem.indexOf(u8, s.archive, ".tar.") != null);
    }
    try testing.expect(!isSha256Hex("AC99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"));
    try testing.expect(!isSha256Hex("ac99"));
}

test "Wine Mono is the file this Wine asks for, over HTTPS, pinned" {
    // The name is the one `addons.c` builds from MONO_VERSION and MONO_ARCH,
    // and Wine looks for exactly that name in the cache.
    try testing.expectEqualStrings("wine-mono-" ++ wine_mono.version ++ "-x86.msi", wine_mono.archive);
    try testing.expect(std.mem.startsWith(u8, wine_mono.url, "https://"));
    try testing.expect(std.mem.endsWith(u8, wine_mono.url, wine_mono.archive));
    try testing.expect(isSha256Hex(wine_mono.sha256));
}

test "every library is built after the ones it links against" {
    for (dep_builds, 0..) |d, i| {
        for (d.links) |l| {
            const want = try std.fmt.allocPrint(testing.allocator, "lib/lib{s}.", .{l.lib});
            defer testing.allocator.free(want);
            var earlier = false;
            for (dep_builds[0..i]) |before| {
                for (before.produces) |p| {
                    if (std.mem.startsWith(u8, p, want)) earlier = true;
                }
            }
            try testing.expect(earlier);
        }
    }
}

test "every file the build checks for is one a library build produces" {
    for (deps) |d| {
        var made = false;
        for (dep_builds) |b| {
            for (b.produces) |p| {
                if (std.mem.eql(u8, p, d.path)) made = true;
            }
        }
        try testing.expect(made);
    }
}

test "a library is configured for x86-64, shared, into the deps prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const gnutls = dep_builds[2];
    try testing.expectEqualStrings("GnuTLS", gnutls.name);
    const argv = try depConfigureArgv(a, "/r/deps", gnutls);
    try testing.expectEqualStrings("./configure", argv[0]);
    var saw_host = false;
    var saw_prefix = false;
    var saw_shared = false;
    var saw_tasn1 = false;
    var saw_no_p11 = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--host=x86_64-apple-darwin")) saw_host = true;
        if (std.mem.eql(u8, arg, "--prefix=/r/deps")) saw_prefix = true;
        if (std.mem.eql(u8, arg, "--disable-static")) saw_shared = true;
        if (std.mem.eql(u8, arg, "--with-included-libtasn1")) saw_tasn1 = true;
        if (std.mem.eql(u8, arg, "--without-p11-kit")) saw_no_p11 = true;
    }
    try testing.expect(saw_host and saw_prefix and saw_shared and saw_tasn1 and saw_no_p11);
}

test "the Wine build sees only the deps prefix through pkg-config, and targets the oldest macOS" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const env = try wineEnv(a, .{
        .build = "/r/build",
        .wine = "/r/build/wine",
        .out = "/r/build/build-p2",
        .tools = "/r/build/tools",
        .mingw = "/r/build/llvm-mingw",
        .deps = "/r/deps",
        .install = "/r/runtimes/x",
    });
    var libdir: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    for (env) |e| {
        try testing.expect(std.mem.indexOf(u8, e.value, "homebrew") == null);
        if (std.mem.eql(u8, e.name, "PKG_CONFIG_LIBDIR")) libdir = e.value;
        if (std.mem.eql(u8, e.name, "PKG_CONFIG_PATH")) path = e.value;
        if (std.mem.eql(u8, e.name, "MACOSX_DEPLOYMENT_TARGET")) target = e.value;
    }
    // LIBDIR replaces pkg-config's built-in search path, Homebrew's included,
    // and an empty PATH adds nothing back.
    try testing.expectEqualStrings("/r/deps/lib/pkgconfig", libdir.?);
    try testing.expectEqualStrings("", path.?);
    try testing.expectEqualStrings(macos_min, target.?);
}

test "a library's environment keeps Homebrew out and names what it links" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const env = try depEnv(a, "/r/deps", dep_builds[2]);
    var saw_path = false;
    var saw_cc = false;
    var saw_pkg = false;
    var saw_gmp = false;
    for (env) |e| {
        // No /opt/homebrew or /usr/local anywhere in it.
        try testing.expect(std.mem.indexOf(u8, e.value, "homebrew") == null);
        try testing.expect(std.mem.indexOf(u8, e.value, "/usr/local") == null);
        if (std.mem.eql(u8, e.name, "PATH") and std.mem.eql(u8, e.value, "/usr/bin:/bin:/usr/sbin:/sbin")) saw_path = true;
        if (std.mem.eql(u8, e.name, "CC") and std.mem.eql(u8, e.value, "/usr/bin/clang -arch x86_64")) saw_cc = true;
        if (std.mem.eql(u8, e.name, "PKG_CONFIG_LIBDIR") and std.mem.eql(u8, e.value, "/r/deps/lib/pkgconfig")) saw_pkg = true;
        if (std.mem.eql(u8, e.name, "GMP_LIBS") and std.mem.eql(u8, e.value, "-L/r/deps/lib -lgmp")) saw_gmp = true;
    }
    try testing.expect(saw_path and saw_cc and saw_pkg and saw_gmp);

    // Every library is stamped for the oldest macOS the runtime supports,
    // not for whatever the build machine runs.
    for (dep_builds) |d| {
        var target: ?[]const u8 = null;
        for (try depEnv(a, "/r/deps", d)) |e| {
            if (std.mem.eql(u8, e.name, "MACOSX_DEPLOYMENT_TARGET")) target = e.value;
        }
        try testing.expectEqualStrings(macos_min, target.?);
    }

    // A library that links nothing gets no _LIBS variables.
    for (try depEnv(a, "/r/deps", dep_builds[0])) |e| {
        try testing.expect(!std.mem.endsWith(u8, e.name, "_LIBS"));
    }
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
