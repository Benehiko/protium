# Building the Wine half from source

What the recipe needs is an Apple silicon Mac with Xcode's command line tools;
`protium doctor` checks a host against the list. **Nothing is installed on the
host** — every build tool and the one runtime dependency are fetched into a
scratch directory of your choosing, referred to below as `$SCRATCH`.

*Verified end to end once, on 2026-09-05, against an M4 Mac running macOS
26.6.1 with Xcode 26.6 / Apple clang 21.* That is a record of one run rather
than a requirement: nothing in the recipe is pinned to those versions, and
anything below that turns out to be is a bug worth reporting.

## Where the source comes from

CodeWeavers publish CrossOver's sources because the LGPL requires it:

```
https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz   (142 MB)
```

Only `sources/wine` is needed; the tarball also carries CodeWeavers' bundled
MoltenVK, DXVK, vkd3d, FreeType, GStreamer and more, none of which this recipe
uses.

```
tar -xzf crossover-sources-26.3.0.tar.gz --include='sources/wine/*' --strip-components=1
cat wine/VERSION      # Wine version 11.0
```

This matters: the extracted tree is **Wine 11.0**, matching the
`wine-11.0-8726-g2e2f5fca349` string in a shipped CrossOver 26.3 binary. Apple's
Game Porting Toolkit formula, by contrast, still pins
`crossover-sources-22.1.1.tar.gz`, which is **Wine 7.7** — four major versions
older. Any pre-built free environment derived from that formula is on 7.7.

## Toolchain

| Need | Why the system copy will not do | Source |
| --- | --- | --- |
| bison ≥ 3.0 | Xcode ships bison 2.3, and configure rejects it | `ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz`, built to a scratch prefix |
| PE cross-compiler | Apple clang has no mingw driver | `mstorsjo/llvm-mingw`, `…-ucrt-macos-universal.tar.xz`, unpacked |
| unix-side compiler | — | Apple clang, with `-arch x86_64` |
| FreeType (x86-64) | Homebrew's is arm64 and cannot link into an x86-64 Wine | `freetype-2.13.3`, built shared to a scratch prefix |

**Apple's patched clang is not needed.** The `game-porting-toolkit-compiler`
dependency in Apple's formula is an artefact of the Wine 7.7 era; Wine 11's
configure accepts llvm-mingw's `x86_64-w64-mingw32-clang` directly.

## Three traps, each of which costs an hour

1. **llvm-mingw shadows Apple clang.** Its `bin/` contains a `clang` that
   targets Windows. Putting that directory on `PATH` makes configure fail with
   `C compiler cannot create executables` — the log shows `clang: error:
   unknown argument '-qversion'`. Pin the host compiler by absolute path:
   `CC="/usr/bin/clang -arch x86_64"`.
2. **FreeType must be a dylib.** Wine detects it by *soname* because it
   `dlopen`s it at runtime, so a static `libfreetype.a` produces `checking for
   -lfreetype... not found` even with the headers present. Build it
   `--enable-shared --disable-static`.
3. **CrossOver's tree does not build without Vulkan.** See below.

Not a trap, but worth knowing: because Rosetta executes x86-64 binaries,
configure reports `whether we are cross compiling... no` and runs its probes
normally. Building an x86-64 Wine on an arm64 Mac is not a cross-compile in
practice.

## The one source patch

`dlls/win32u/vulkan.c` fails to compile:

```
error: use of undeclared identifier 'SONAME_LIBVULKAN'
```

The reference sits inside a CodeWeavers patch:

```c
/* CW HACK 25909: Allow specifying libvulkan */
if (!(libvulkan = getenv( "CX_LIBVULKAN" )) || ...)
    libvulkan = SONAME_LIBVULKAN;
```

`SONAME_LIBVULKAN` appears exactly once in the file and behind no `#ifdef`
anywhere in it, so the tree simply cannot be built without Vulkan — CodeWeavers
always build against their bundled MoltenVK. A scan of the rest of `dlls/` for
the same pattern found no other unguarded soname reference.

D3DMetal never touches Vulkan, and Wine `dlopen`s the library at runtime and
degrades gracefully when it is absent, so defining the soname is sufficient and
safe. Add to the generated `include/config.h`, **inside** the include guard:

```c
#define SONAME_LIBVULKAN "libvulkan.1.dylib"
```

## Configure and build

```sh
export PATH="$SCRATCH/tools/bin:$SCRATCH/llvm-mingw/bin:$PATH"

$SRC/configure \
  --host=x86_64-apple-darwin \
  --enable-archs=i386,x86_64 \
  --disable-tests \
  --with-mingw \
  --prefix="$SCRATCH/wine-install" \
  CC="/usr/bin/clang -arch x86_64" \
  CXX="/usr/bin/clang++ -arch x86_64" \
  CPPFLAGS="-I$SCRATCH/x86deps/include/freetype2 -I$SCRATCH/x86deps/include" \
  LDFLAGS="-L$SCRATCH/x86deps/lib"

make -j"$(sysctl -n hw.ncpu)"
```

`--enable-archs=i386,x86_64` is deliberate: the 32-bit PE modules are needed
because the Windows Steam client is 32-bit. CrossOver ships `i386-windows` for
the same reason.

Confirm success by the status of `make` itself, not of a pipeline that ends in
`tail`.

## What a lean build gives up

configure reports a long list of missing libraries. Almost all are Linux-only
and irrelevant here — Wayland, X11, ALSA, PulseAudio, OSS, udev, inotify, v4l2,
gphoto2, sane, capi20, Samba NetAPI, krb5. Four are worth a decision:

| Missing | Consequence | Verdict |
| --- | --- | --- |
| `libvulkan`/MoltenVK | no Vulkan | irrelevant — D3DMetal goes straight to Metal |
| GStreamer / FFmpeg | no `winegstreamer` media playback | fine for games that decode video in-engine |
| SDL2 | no SDL joystick backend | controllers arrive through IOHID; `IOServiceMatching` probes yes |
| GnuTLS | no schannel/bcrypt TLS | Steam's CEF carries its own TLS |

FreeType is the one worth building, because without it Wine has no font
rasteriser at all and any Win32 UI — the Steam client's login window included —
renders blank.

## Runtime note

Wine recorded FreeType's soname as the bare `libfreetype.6.dylib`, so a launch
must make it findable — either `DYLD_FALLBACK_LIBRARY_PATH` pointing at the
scratch `lib`, or relocating the dylib into the Wine tree and patching its
install name, which is tidier for a permanent installation.

## Then install D3DMetal

The Wine tree is only half an environment. See [`d3dmetal.md`](d3dmetal.md);
`protium redist <dir> --into <wine>/lib` prints the right procedure for that
destination.

## Installing it somewhere durable

```sh
make install prefix="$HOME/.local/share/protium/runtimes/wine-11.0-cx26.3"
```

Install it under `runtimes/` in protium's root and protium finds it without
being told; the last path component is the name it will be known by. The root
is `$PROTIUM_HOME`, else `$XDG_DATA_HOME/protium`, else the path above — see
[`prefixes.md`](prefixes.md).

**The destination must not contain spaces.** Wine's install rules do not quote
paths, so a path under `~/Library/Application Support/` fails part-way through
with

```
error: Support/protium/wine-11.0-cx26.3/lib/wine/i386-windows : No such file or directory
```

after having already copied several hundred files. The macOS-idiomatic location
is unavailable for this reason; `~/.local/share/protium/` is not.

The installed tree is about 1.1 GB and mirrors CrossOver's layout exactly:
`lib/wine/{x86_64-unix, x86_64-windows, i386-windows}`.

Two things must then be added to it:

* **FreeType.** Wine recorded the bare soname `libfreetype.6.dylib`, so copy the
  dylib into `<install>/lib/`. protium puts that directory on
  `DYLD_FALLBACK_LIBRARY_PATH` for every launch, which is what makes the
  soname resolve; without the dylib being there, every launch comes up with no
  font rasteriser. See [`prefixes.md`](prefixes.md).
* **D3DMetal**, merged in — see [`d3dmetal.md`](d3dmetal.md) for why merged and
  not moved aside. `protium redist <apple-redist-lib> --into <install>/lib`
  prints the right procedure for that destination.

## Creating a prefix

```sh
protium prefix new default
```

This sets `WINEPREFIX` and the rest for you and runs `wineboot -u`. Expect
several minutes: it runs `wine.inf` through `setupapi`, and every bit of it is
x86-64 under Rosetta. protium waits for `wineboot`, then ends the session with
`wineserver -k` — `wineboot` returning is not the signal on its own, because
`wineserver` inherits stdout and lingers after it. The prefix is finished when
`system.reg` is written, roughly 1.7 MB, which is what protium checks for
before reporting success.

By hand, the same thing is:

```sh
export WINEPREFIX="<root>/prefixes/default"
export DYLD_FALLBACK_LIBRARY_PATH="<install>/lib"
"<install>/bin/wine" wineboot -u
```

Smoke test:

```
$ protium run cmd /c ver
Microsoft Windows 10.0.19045
```
