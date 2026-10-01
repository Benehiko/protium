# protium

Run Windows games on an Apple silicon Mac.

A Windows game needs two things macOS lacks: Windows itself, and a way to turn
Direct3D into Metal. Wine provides the first and Apple's D3DMetal the second.
Both are free, and neither comes packaged. protium builds Wine from
CodeWeavers' published sources, installs D3DMetal into it, and manages the
prefixes your games run in. It costs nothing and sends nothing anywhere.

protium runs single-player games. Anti-cheat does not work.

> [!TIP]
> To play tonight, buy [CrossOver](https://www.codeweavers.com/crossover)
> instead. It ships Wine and D3DMetal prebuilt and supported. protium asks for
> about an hour of setup, once, and leaves you with an environment you built
> yourself and can inspect.

## Quickstart

### 1. Get the prerequisites

* **Rosetta 2.** D3DMetal is x86-64 only, so the Wine is too
  ([why](docs/d3dmetal.md)). Install it with
  `softwareupdate --install-rosetta --agree-to-license`.
* **The Wine build tools**, listed in
  [docs/wine-build.md](docs/wine-build.md#toolchain). They go into a scratch
  directory, not onto your Mac.
* **Apple's Evaluation environment for Windows games**, inside the
  [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)
  DMG. Downloading it requires an Apple developer account. protium does not
  redistribute it. [docs/d3dmetal.md](docs/d3dmetal.md) gives the URL we
  tested and why it may not work for you.

### 2. Install protium

```sh
V=v0.2.0
curl -LO https://github.com/Benehiko/protium/releases/download/$V/protium-$V-macos-aarch64.tar.gz
tar -xzf protium-$V-macos-aarch64.tar.gz
mkdir -p ~/.local/bin
install -m 755 protium-$V-macos-aarch64/protium ~/.local/bin/protium
protium version
```

If `protium version` fails, add `~/.local/bin` to your `PATH`.

Every release is signed by the workflow that built it. The
[release notes](https://github.com/Benehiko/protium/releases) show how to check
the signature with cosign before you run anything. Files downloaded with
`curl` skip macOS quarantine. If you download with a browser, the release notes
also explain how to clear it.

### 3. Build the environment

```sh
protium doctor               # check the prerequisites
protium runtime install      # install the Wine this release was built with
protium d3dmetal install     # install Apple's D3DMetal from the toolkit DMG in ~/Downloads
protium prefix new default   # create a Windows prefix
protium shell-init           # print a line to add to your shell's rc file
```

Run `protium status` at any point to see where you are and what comes next.

`protium d3dmetal install` takes the toolkit's `.dmg`, the evaluation
environment inside it, either one mounted, or its `redist/lib` folder; without
a path it uses the `Game_Porting_Toolkit_*.dmg` in `~/Downloads`. It opens a
disk image in your terminal, where `hdiutil` asks you to accept Apple's
licence, checks the payload, and merges it into the runtime, keeping Wine's own
Direct3D modules aside. `protium d3dmetal check` reports which D3DMetal the
runtime has, or, given a path, what Apple's download holds.

`protium runtime install` downloads the Wine runtime that this release of
protium was built with, and installs it only if its SHA-256 matches the one
compiled into protium, which the release's signature covers. Because protium
downloads it rather than a browser, macOS does not quarantine it. To build the
same Wine on your Mac instead, run `protium build` in its place: it is
unattended, and takes about 10 minutes on an M4.

Downloaded the runtime archive from the releases page yourself, for a Mac
without a network connection, say? Give `protium runtime install` its path:

```sh
protium runtime install ~/Downloads/wine-11.0-cx26.3-p2-macos-x86_64.tar.gz
```

The same SHA-256 check applies, and the installed files are not quarantined.
Do not unpack the archive in Finder and copy the folder into place: that skips
the check, and Archive Utility passes the download's quarantine on to every
file it extracts.

`protium build` follows [docs/wine-build.md](docs/wine-build.md). It builds the
x86-64 FreeType, GnuTLS and the libraries GnuTLS needs from pinned sources when
they are missing. The document explains each step and the three mistakes that
each cost an hour to find.

### 4. Install and start Steam

```sh
protium install steam
```

This downloads Valve's installer and prints its size and SHA-256. It sets
`WINEMSYNC=1` in the prefix, since without it Steam's UI fails in a way that
looks like a network fault ([why](docs/wine-build.md#winemsync1-is-not-optional)).
It runs the installer, applies the fix that makes Steam's window paint
([details](docs/steam-rendering.md)), and prints the launch command.

Start Steam:

```sh
protium run steam
```

protium adds the three arguments Steam needs here: `-noreactlogin`,
`-noverifyfiles` and `-norepairfiles`. Without the last two, Steam restores its
own files, removes the rendering fix, and its window goes black. After a Steam
update, or whenever the window goes black, run `protium install steam` again.
It leaves Steam alone and restores the fix.

Sign in **online, once**, so Steam caches your credentials and licences. Then
install games from Steam as usual.

### 5. Play

With Steam signed in and running, start the game by the name Steam shows for
it:

```sh
protium run "elden ring"
```

protium looks the game up in Steam's records, in every Steam library in the
prefix, on any drive. It picks the game's program and skips installers,
bundled runtimes, crash reporters and Easy Anti-Cheat, which does not work
here. For Elden Ring that is `Game/eldenring.exe`. It also sets `SteamAppId`,
which a game needs to reach Steam when started directly, and starts the game
in its own directory, as Steam does. Elden Ring 2.7.1.0 refuses to start from
anywhere else: see [Where `protium run` starts a
program](docs/working-directory.md).

The app ID works too (`protium run 1245620`), and so does the executable's
file name (`protium run eldenring.exe`). Tab completion offers all three. If
protium cannot tell which program is the game, it lists the candidates. Run
the one you want by its file name or path.

> [!NOTE]
> The title screen reports `A connection error occurred. Unable to start in
> online mode.` and the menu reads `OFFLINE`. This is expected. `CONTINUE`
> loads your save.

> [!NOTE]
> Quitting the game from its menu ends in a Wine crash report instead of a
> clean exit. The game has already stopped by then. This is a known issue; see
> [Elden Ring crashes when it quits](docs/quit-crash.md).

If the game exits at once with `connect to global user failed`, Steam is not
signed in. See [Steam sign-in](#steam-sign-in).

## Steam sign-in

Online sign-in works on a runtime built with `patches/0001` and GnuTLS. It
reached `Logged On` on 2026-09-08. A Wine built without them fails twice: seven
starts in eight never open the connection gate, and without TLS every WebSocket
connection fails. [docs/steam-login.md](docs/steam-login.md) traces both.

Offline mode avoids the problem, and games need nothing more. Add these lines
to your account's block in
`<prefix>/drive_c/Program Files (x86)/Steam/config/loginusers.vdf`:

```
"WantsOfflineMode"        "1"
"SkipOfflineModeWarning"  "1"
```

These flags are not enough on their own. Steam chooses offline mode on its CEF
login page, which often never renders here, and the client stays logged off.
`protium run steam` passes `-noreactlogin`, which starts Steam on the legacy
login path instead.

## Everyday use

```sh
protium install list                   # software protium can fetch
protium install steam                  # install it into the default prefix
protium install clean                  # delete downloaded installers
protium run steam                      # start Steam with the arguments it needs
protium run "elden ring"               # a Steam game, by title or app ID
protium run eldenring.exe              # any .exe in the prefix, by file name
protium run ~/Downloads/Setup.exe      # run any Windows program
protium run "C:\Program Files\…\Game.exe"

protium prefix list                    # list prefixes; * marks the default
protium prefix new skyrim              # create a prefix
protium use skyrim                     # make it the default
protium prefix stop                    # stop the Wine running in a prefix
protium prefix remove skyrim           # delete a prefix, after confirming
protium prefix migrate-user            # move an old prefix to the protium user
```

A *prefix* is one Windows installation, with its own `C:` drive, registry and
programs. Give games that need different settings a prefix each.

Each prefix keeps its settings in a `protium.conf`: frame cap, ray tracing and
Wine options. protium applies them to everything launched in that prefix.
[docs/prefixes.md](docs/prefixes.md) covers them. `protium install list` marks
which installers have been tested; [docs/install.md](docs/install.md) covers
the command.

`protium prefix remove` shows the path, the size and any symlinks leading out
of the prefix, then asks. It never follows those links. A prefix can link into
another Steam library, and only the link is removed. `--force` skips the
question. protium refuses to remove a prefix while Wine runs in it, and prints
the `prefix stop` command to run first.

The Windows user inside a prefix is `protium`, with its profile at
`C:\users\protium`. Older prefixes use a `crossover` profile, which current
runtimes do not find, so Steam starts signed out. `protium prefix list` flags
these prefixes, and `protium prefix migrate-user` moves them. protium never
migrates on its own.
[Details](docs/prefixes.md#the-windows-user-is-protium).

## How it works

| Part | What it does | Source |
| --- | --- | --- |
| **Wine** | Implements Windows: loader, Win32, `winemac.drv` | CodeWeavers' published CrossOver sources (LGPL), built by you |
| **D3DMetal** | Translates Direct3D 12 and 11 to Metal | Apple's Game Porting Toolkit |

A game needs both. Wine alone renders nothing for Direct3D 12, and D3DMetal
alone has no process to run in. Proton cannot be ported to macOS;
[docs/why-not-proton.md](docs/why-not-proton.md) explains why.

## Status

protium is early. Here is what works and what does not.

* **Works:** the Wine build, `protium doctor`, `protium d3dmetal`, prefixes and
  launching. Elden Ring plays on a protium-built Wine with no CrossOver runtime:
  the save loads, the world renders and the character responds.
* **Works:** `protium install`. It downloads from the publisher, prints the
  size and SHA-256, configures the prefix, runs the installer, applies the
  fixes the program needs, and refuses when the installer cannot run.
* **Works with a workaround:** Steam sign-in. On an unpatched build, sign-in
  fails in `CCMInterface::LogOn()` because Wine's `GetLogicalDrives` never
  returns when the PE side is built with clang. `patches/` fixes it, and a
  patched runtime reaches Valve's servers. Offline mode with `-noreactlogin`
  works on either. See [docs/steam-login.md](docs/steam-login.md).
* **Worked around:** CEF rendering. Chromium composites in a separate GPU
  process, and nothing it draws reaches the window, so Steam paints black.
  protium installs a stand-in `steamwebhelper.exe` that adds
  `--in-process-gpu`. This edits a Steam install protium does not own, a Steam
  update undoes it, and other CEF programs still render black. The real fix
  belongs in Wine. `protium install steam --undo` reverts it.
  See [docs/steam-rendering.md](docs/steam-rendering.md).
* **Works, cause unexplained:** 32-bit programs, Steam's installer among
  them. On 2026-09-06 `wineboot` left `syswow64` empty in new prefixes, and
  nothing 32-bit started. Since 2026-09-07 it fills the directory, with nothing
  changed that we know of. `protium install` still checks, and refuses a 32-bit
  installer if the directory is empty.
  See [docs/install.md](docs/install.md#syswow64-fills-itself-now).
* **Designed, not built:** talking to the native macOS Steam client, as
  Proton's `lsteamclient` does on Linux.
  See [docs/steam-bridge.md](docs/steam-bridge.md).
* **Not attempted:** anti-cheat.

**Performance** on an M4: Elden Ring holds 33 fps at 2560×1440 with every
setting on HIGH, and 59.7 fps, the game's own cap, at 1280×720 in the same
scene. A quarter of the pixels nearly doubles the frame rate, so the GPU is
the limit, not Rosetta or the Direct3D translation. These figures were
measured with a mod runtime injected, which costs a little.

## Building from source

You need [Zig](https://ziglang.org/download/) 0.16.0 or newer.

```sh
git clone https://github.com/Benehiko/protium
cd protium
zig build --prefix ~/.local -Doptimize=ReleaseFast
```

This installs `~/.local/bin/protium`. A source build reports its version as
`dev`; pass `-Dversion=0.1.0` to set one.

## Contributing

```sh
zig build            # build the binary into zig-out/bin
zig build test       # run the tests
zig fmt .            # format; the pre-commit hook enforces it
```

The pre-commit hook lives in `.githooks/`, so it is tracked and reviewable.
Enable it in each clone with `git config core.hooksPath .githooks`. It checks
formatting and the build, and leaves the tests to CI.
`git commit --no-verify` bypasses it.

[docs/releasing.md](docs/releasing.md) explains how releases are built and
signed.

## Licensing

protium's own code is licensed under **[Apache 2.0](LICENSE)**. It vendors
nothing: no dependencies, no bundled sources, and no linking against Wine or
D3DMetal. The one exception is the Wine patches in
[`patches/`](patches/README.md), which the binary carries so `protium build`
can apply them. They modify Wine, so they are LGPL-2.1-or-later, like Wine.

Wine and D3DMetal are not protium's to license.
**[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)** records their terms, with
versions and evidence.

* **Wine and the CrossOver sources** are LGPL. CodeWeavers publish them because
  the licence requires it, and building and using them is what the licence
  allows. If you redistribute a Wine you built, the LGPL's conditions apply.
  protium's Apache licence does not cover those binaries.
* **D3DMetal belongs to Apple** and comes under the licence in Apple's
  download. protium reads and installs a copy you obtained yourself.

> [!IMPORTANT]
> protium ships no part of Apple's redistributable, and nothing built from this
> repository should.

protium is an independent project, not affiliated with or endorsed by Apple,
CodeWeavers, the Wine project or Valve.
