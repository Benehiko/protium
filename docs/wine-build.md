# Building the Wine half from source

What the recipe needs is an Apple silicon Mac with Xcode's command line tools;
`protium doctor` checks a host against the list. **Nothing is installed on the
host** — every build tool and every runtime dependency is fetched into a
scratch directory of your choosing, referred to below as `$SCRATCH`.

**Keep `$SCRATCH` afterwards.** The source tree in it is evidence: the day the
sign-in bug was found, the decisive step was reading `GetLogicalDrives` and
`NtQueryDirectoryObject` in the tree the runtime was built from
([`steam-login.md`](steam-login.md#wines-source-kept-this-time-says-what-that-means)),
and the recipe as first written had deleted it. `~/.local/share/protium/build`
is where it lives on the machine this was verified on — `wine/` is the tree,
`build-p1/` the out-of-tree build, `tools/` and `llvm-mingw/` the toolchain.

*Verified end to end on 2026-09-05, against an M4 Mac running macOS 26.6.1
with Xcode 26.6 / Apple clang 21, and again on 2026-09-08 (macOS 26.6.2 build
25G83, Xcode 26.6 build 17F113, Apple clang 21.0.0 `clang-2100.1.1.101`,
llvm-mingw 20260826 = clang 23.1.0, bison 3.8.2) with the patch below
applied.* That is a record of two runs rather than a requirement: nothing in
the recipe is pinned to those versions, and anything below that turns out to be
is a bug worth reporting — except the compiler *family* of the PE side, which
is load-bearing; see [The PE compiler decides
more than it looks](#the-pe-compiler-decides-more-than-it-looks).

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
| PE cross-compiler | Apple clang has no mingw driver | `mstorsjo/llvm-mingw`, `…-ucrt-macos-universal.tar.xz`, unpacked (20260826, which is clang 23.1.0, on 2026-09-08) |
| unix-side compiler | — | Apple clang, with `-arch x86_64` |
| FreeType (x86-64) | Homebrew's is arm64 and cannot link into an x86-64 Wine | `freetype-2.13.3`, built shared to a scratch prefix |
| GnuTLS, nettle, hogweed, GMP (x86-64) | same reason; Wine's schannel `dlopen`s `libgnutls.30.dylib` | built shared to the same scratch prefix |

The scratch prefix these land in is what `protium` keeps as
`~/.local/share/protium/deps` — `include/{freetype2,gnutls,nettle,gmp.h}` and
`lib/lib{freetype,gnutls,nettle,hogweed,gmp}.dylib`, all `x86_64` by `lipo
-archs`, with absolute install names. The 2026-09-08 rebuild pointed `CPPFLAGS`
and `LDFLAGS` at it directly and rebuilt none of them; the generated
`config.h` then has `SONAME_LIBFREETYPE "libfreetype.6.dylib"` and
`SONAME_LIBGNUTLS "libgnutls.30.dylib"`, so a build from this recipe has
schannel, which an earlier version of this document said it lacked.

**Apple's patched clang is not needed.** The `game-porting-toolkit-compiler`
dependency in Apple's formula is an artefact of the Wine 7.7 era; Wine 11's
configure accepts llvm-mingw's `x86_64-w64-mingw32-clang` directly.

### The PE compiler decides more than it looks

llvm-mingw is clang. CrossOver, Homebrew and Apple's formula all compile the PE
half with **mingw-w64 GCC** — CrossOver 26.3's `kernelbase.dll` carries the
string `GCC: (GNU) 13.2.0`, protium's carries `clang version 23.1.0` — and the
difference is not cosmetic. For a `BOOLEAN` argument to a system call, GCC
writes 32 bits into the stack slot (`movl $0x0, 0x20(%rsp)`) and clang writes
one byte (`movb $0x0, 0x20(%rsp)`). Both are legal Windows code. But Wine's
syscall dispatcher hands the slot to the unix side whole, and the unix side is
Apple clang, which as a SysV callee assumes a `char` argument was zero-extended
to 32 bits and tests `%r8d`. With GCC's store that assumption holds by
accident; with clang's it holds only if the seven bytes above the argument
happened to be zero already. When they are not, `NtQueryDirectoryObject` sees
`restart = TRUE` on every call and `GetLogicalDrives` never returns — which is
the whole Steam sign-in failure, measured and proven in
[`steam-login.md`](steam-login.md#the-caller-read-directly--and-the-bug-it-exposes).

So a clang PE side plus a clang unix side is a combination nobody else ships,
and it has at least one real bug that GCC's codegen hides. The recipe keeps
llvm-mingw, because a mingw-w64 GCC for a macOS host is not something to fetch
and unpack, and carries a patch for the measured case instead (below). The
general fix — GCC for the PE side, or a unix side that stops trusting the
upper bits of narrow arguments — is open.

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

## Two source patches

### `patches/0001-ntdll-test-only-the-byte-of-a-BOOLEAN-syscall-argument.patch`

Apply it to the tree before `configure`:

```sh
cd $SCRATCH/wine && patch -p1 < /path/to/protium/patches/0001-ntdll-test-only-the-byte-of-a-BOOLEAN-syscall-argument.patch
```

It changes nine lines of `dlls/ntdll/unix/sync.c`: `NtQueryDirectoryObject`'s
two `BOOLEAN` arguments go through an empty `asm` with an in/out constraint
before they are read, which makes clang treat them as fresh 8-bit values and
test the byte rather than the register. Checked with the same Apple clang at
`-O2`: the unpatched function compiles to `testl %r8d, %r8d`, the patched one
to `testb %r8b, %r8b`. The patch header says why; the section above says what
it costs not to have it.

### `SONAME_LIBVULKAN`

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
safe. The resulting Wine really does have no Vulkan — Elden Ring
reaches its title screen anyway, with `err:vulkan:vulkan_init_once Failed to
load libvulkan.1.dylib` in the log throughout.

The `CX_LIBVULKAN` variable that patch reads is **not** a way to add one back.
The string survives into `win32u.so`, but setting it to an x86-64
`libMoltenVK.dylib` changes nothing: the loader still tries the bare
`libvulkan.1.dylib` soname and fails. Anything that genuinely needs Vulkan
needs a rebuild with `SONAME_LIBVULKAN` pointed at a real x86-64 library —
note that Homebrew's MoltenVK is arm64 and cannot be loaded into this Wine. Add to the generated `include/config.h`, **inside** the include guard:

```c
#define SONAME_LIBVULKAN "libvulkan.1.dylib"
```

A script that checks whether this has been done must grep for the `#define`,
not the name: configure leaves `/* #undef SONAME_LIBVULKAN */` in the file, so
`grep -q SONAME_LIBVULKAN` is true before the line is added. That cost one
aborted build on 2026-09-08.

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
for 32-bit installers and games — `SteamSetup.exe` is one, which is why
`protium install` reads the installer's PE header before spawning it. The
Steam client itself is not the reason any more: `steam.exe` in client build
1788652215 is `PE32+ executable (GUI) x86-64` by `file(1)`, and it loads
`steamclient64.dll`, `tier0_s64.dll` and a 64-bit `steamwebhelper.exe`. An
earlier version of this document said the client was 32-bit. CrossOver ships
`i386-windows` all the same.

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
| GnuTLS | no schannel/bcrypt TLS | not actually given up: the `deps` prefix carries it, and `config.h` records `SONAME_LIBGNUTLS` |

FreeType is the one worth building, because without it Wine has no font
rasteriser at all and any Win32 UI — the Steam client's login window included —
renders blank. GnuTLS turned out to be worth it too: the Steam client's own
HTTP stack goes through schannel, and `bootstrap_log.txt` fetching its update
manifest over HTTPS is that library at work.

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
root="${PROTIUM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/protium}"
make install prefix="$root/runtimes/wine-11.0-cx26.3"
```

Install it under `runtimes/` in protium's root and protium finds it without
being told; the last path component is the name it will be known by. A build
with protium's patches applied is named for its patch level —
`wine-11.0-cx26.3-p1` is the first — and installed **beside** the unpatched
one, never over it, so that `protium run --runtime <name>` can A/B the two from
the same prefix. The `root`
line above is protium's own rule spelled out — `$PROTIUM_HOME`, else
`$XDG_DATA_HOME/protium`, else `$HOME/.local/share/protium` — so someone who
keeps the 1.1 GB tree on another disk sets `PROTIUM_HOME` and changes nothing
else here. `protium status` prints the root it resolved; see
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
  prints the right procedure for that destination. A second runtime built from
  the same tree can take it from the first instead of from Apple's DMG: `ditto`
  `lib/external` and `lib/d3dmetal-shims` across, move the new build's own
  `d3d10.dll d3d11.dll d3d12.dll dxgi.dll` into `lib/wine-d3d-originals`, copy
  the four shims into `lib/wine/x86_64-windows`, and recreate the four
  `x86_64-unix/*.so` symlinks to `../../external/libd3dshared.dylib`. `protium
  redist <install>/lib` then reports the version it found, and it had better be
  the same one.

A second runtime from the same tree has one more step, or the prefix pays for
it. Wine keeps the modification time of the `wine.inf` it last ran in
`$WINEPREFIX/.update-timestamp` (`1788642089` in the Elden Ring prefix, which
is `share/wine/wine.inf`'s mtime in the first runtime) and re-runs
`wineboot --update` — minutes of `setupapi`, a rewritten registry, and the
hang recorded in [`steam-login.md`](steam-login.md#two-traps-this-cost-time-to-find)
— whenever the runtime's copy is newer. The rebuilt `wine.inf` is
byte-identical (`cmp`), so `touch -r <old>/share/wine/wine.inf
<new>/share/wine/wine.inf` is honest, and a prefix then moves between the two
runtimes without noticing.

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

## WINEMSYNC=1 is not optional

A Wine built from these sources runs Steam, shows its UI, and then fails every
webhelper connection:

```
WebUITransport: Websocket connection from: https://steamloopback.host
WebUITransport: TCP connection request
WebUITransport: Connection rejected
```

about ten times a minute, ending in Steam's *Unexpected Transport Error*
(0x3999, 0x3008 — the code varies). Steam reaches the internet and can render
its login window; it simply cannot talk to its own UI process.

The cause is `msync`, CodeWeavers' macOS synchronisation backend (mach ports,
their analogue of esync/fsync). `dlls/ntdll/unix/msync.c` is in the tree and
compiled in, but it is inert unless switched on at runtime:

```c
do_msync_cached = getenv("WINEMSYNC") && atoi(getenv("WINEMSYNC"));
```

There is no `--enable-msync` configure option and nothing in `config.h`, so a
straightforward build gives no hint it exists. CrossOver's own launcher sets
the variable, which is why the identical Steam works there.

**Set `WINEMSYNC=1` for every process touching a prefix**, `wineserver`
included — msync refuses to mix, and says so:

```
Server is running with WINEMSYNC but this process is not, please enable
WINEMSYNC or restart wineserver.
```

### How this was found

Everything else was eliminated first, and each elimination cost time:

* Not the CEF GPU process. It does crash — no Vulkan — but CEF disables GPU
  acceleration itself and continues. `-cef-disable-gpu` skips the churn.
* Not stale caches. Deleting `htmlcache` and `package/` changed nothing.
* Not a half-applied update, despite `steam.exe` being dated two days before
  the `steamui/` package. Those timestamps come from the package contents and
  a clean reinstall reproduces them exactly.
* Not a version mismatch. Stripping the install to `steam.exe`, `config/`,
  `userdata/` and re-bootstrapping a fresh 1 GB client changed nothing.
* Not TLS, though TLS was genuinely broken too and had to be fixed first.

The decisive step was a control: run **the same prefix and the same Steam under
CrossOver's wine**. It worked immediately, and its first log lines were
`msync: bootstrapped mach port` / `msync: up and running` — a subsystem our
build had never mentioned. Comparing runtime logs across the two Wines found in
one step what four rounds of guessing had not.

Note that CrossOver's `bin/wine` refuses a prefix that is not one of its
bottles (`'cxbottle.conf' is not readable`); copying `cxbottle.conf` from an
existing bottle is enough to let the control run.
