# protium

**Run Windows games on an Apple silicon Mac.** macOS only.

> [!IMPORTANT]
> **To just play a game this afternoon, buy
> [CrossOver](https://www.codeweavers.com/crossover).** It ships both halves
> pre-built and supported.
>
> protium makes *you* download Apple's Game Porting Toolkit and build Wine from
> source — about an hour, once. That is the point: you end up with an
> environment you assembled and can inspect, costing nothing and phoning
> nowhere.

A Windows game needs two things macOS lacks: a Windows to run in, and something
to turn Direct3D into Metal. Both are free — Wine from CodeWeavers' published
sources, D3DMetal from Apple — and neither is packaged for you. protium
assembles them, checks them, and gets out of the way.

Single-player games only. No anti-cheat.

## First step — install protium and build the environment

**Get the dependencies first:**

* [What the Wine build needs](docs/wine-build.md#toolchain) — bison, mingw-w64
  and the rest. Nothing is installed onto your Mac; it all goes to a scratch
  directory you delete afterwards.
* Apple's free [Evaluation environment for Windows
  games](https://developer.apple.com/games/game-porting-toolkit/), nested
  inside the Game Porting Toolkit DMG. Needs a signed-in Apple developer
  account; the exact URL tested, and why it may not resolve for you, are in
  [docs/d3dmetal.md](docs/d3dmetal.md). protium does not redistribute it, so
  you download it yourself.
* [Zig](https://ziglang.org/download/) 0.16.0 or newer, to build protium.
* Rosetta 2. D3DMetal is x86-64 only, so the whole Wine is
  ([docs/d3dmetal.md](docs/d3dmetal.md)).

**Build protium:**

```sh
git clone https://github.com/Benehiko/protium
cd protium
zig build --prefix ~/.local -Doptimize=ReleaseFast
```

One binary, at `~/.local/bin/protium`.

> [!NOTE]
> If `protium version` fails afterwards, `~/.local/bin` is not on your `PATH`.

**Then build the environment, in order:**

| | Command | Takes |
| --- | --- | --- |
| 1 | `protium doctor` — checks every prerequisite at once | seconds |
| 2 | Build Wine: **[docs/wine-build.md](docs/wine-build.md)** | ~1 hour, mostly unattended |
| 3 | `protium redist "/Volumes/…/redist/lib" --into ~/.local/share/protium/runtimes/<name>/lib` | minutes |
| 4 | `protium prefix new default` | minutes |
| 5 | `protium shell-init` — prints one line for your shell's rc file | seconds |

Step 2 is the only genuinely technical part; the recipe is written out command
by command, including the three mistakes that each cost an hour to find.

> [!WARNING]
> Step 3 has two possible install methods, and **one of them destroys the Wine
> you just spent an hour building**. protium looks at the destination and
> prints the correct one — read what it prints before running it.

`protium status` shows where you are and what comes next, at any point.

## Quickstart — Steam, then Elden Ring

### Install Steam

```sh
protium install steam
```

This fetches Valve's own installer, prints its size and SHA-256, adds
`WINEMSYNC=1` to the prefix's `protium.conf` — Steam's UI fails silently
without it, in a way that looks like a network fault
([why](docs/wine-build.md#winemsync1-is-not-optional)) — runs the installer
silently, applies the fix that makes Steam's window paint
([what and why](docs/steam-rendering.md)), and prints how to launch it.

Run it again on an install you already have: it leaves Steam alone and just
puts the rendering fix back, which is what a Steam update takes off.

`protium install list` shows everything protium knows how to fetch, with a
word beside each saying whether anyone has actually run it here.
**[docs/install.md](docs/install.md)** covers the command in full.

> [!WARNING]
> **This one currently stops before it installs**, and says so. Valve's
> `SteamSetup.exe` is a 32-bit program, and a prefix made by `protium prefix
> new` has an empty `syswow64`, so nothing 32-bit starts in it. The Wine is
> fine — its 32-bit modules are all there, and Steam installs and runs
> normally in a prefix whose `syswow64` was filled by something else. The
> measurements are in
> [docs/install.md](docs/install.md#a-32-bit-installer-cannot-run-in-a-prefix-protium-made).

> [!NOTE]
> Sign in **online, once**, so your credentials and game licences cache. Then
> install your game from Steam's UI as normal.

```sh
protium run "C:\Program Files (x86)\Steam\steam.exe" \
    -noreactlogin -noverifyfiles -norepairfiles
```

> [!IMPORTANT]
> Those three arguments are not optional, and `protium install steam` prints
> them with the reason for each. Steam's window paints black without the fix
> that command applies, and Steam puts its own file back — undoing the fix —
> if you launch it without `-noverifyfiles -norepairfiles`. Run `protium
> install steam` again after a Steam update, or any time the window goes
> black. [docs/steam-rendering.md](docs/steam-rendering.md) has the whole
> story.

### Every launch after that, offline

Online sign-in works on a runtime built with `patches/0001` and carrying
GnuTLS, and it reached `Logged On` on 2026-09-08. On a Wine built by the recipe
as first written it fails twice over: seven starts in eight never open the
connection gate, and the build has no TLS, so every WebSocket connection
manager fails regardless. [docs/steam-login.md](docs/steam-login.md) traces
both. Offline mode sidesteps the whole question and a game needs nothing more,
but it is no longer the only route.

Add these to your account's block in
`<prefix>/drive_c/Program Files (x86)/Steam/config/loginusers.vdf`:

```
"WantsOfflineMode"        "1"
"SkipOfflineModeWarning"  "1"
```

> [!IMPORTANT]
> Those flags are necessary but **not sufficient**. Offline mode is chosen by
> Steam's CEF login page, which often never renders here, leaving the client
> logged off forever. Start it on the legacy login path instead:
>
> ```sh
> protium run "C:\Program Files (x86)\Steam\steam.exe" -noreactlogin
> ```

### Run Elden Ring

Launch the game directly, with Steam signed in and running. `eldenring.exe`
rather than `start_protected_game.exe` skips Easy Anti-Cheat, which does not
work here anyway.

```sh
SteamAppId=1245620 protium run \
  "C:\Program Files (x86)\Steam\steamapps\common\ELDEN RING\Game\eldenring.exe"
```

`SteamAppId` is what the game's own `SteamAPI_Init` reads when there is no
`steam_appid.txt` beside the executable.

> [!NOTE]
> The title screen reports `A connection error occurred. Unable to start in
> online mode.` and the menu reads `OFFLINE`. **That is correct and expected.**
> `CONTINUE` loads the save and plays.

> [!TIP]
> If instead the game exits immediately with `connect to global user failed`,
> Steam is not signed in — see the offline step above.

## Everyday use

```sh
protium install list                   # software protium can fetch for you
protium install steam                  # …and install, into the default prefix
protium run ~/Downloads/Setup.exe      # install something yourself
protium run "C:\Program Files\…\Game.exe"

protium prefix list                    # your prefixes; * is the default
protium prefix new skyrim              # another one
protium prefix stop                    # shut down the Wine running in one
protium prefix remove skyrim           # delete one, after showing what goes
protium use skyrim                     # make it the default

protium install clean                  # delete the installers it downloaded
```

A *prefix* is one Windows installation — its own `C:` drive, registry and
programs. Games that disagree about what they need get one each.

Each prefix keeps its settings in a `protium.conf` inside it — frame cap, ray
tracing, Wine's own knobs — applied automatically to anything launched there.
Full details in **[docs/prefixes.md](docs/prefixes.md)**.

`protium prefix remove` prints the path, the size and the symlinks that lead
out of the prefix, then asks. It never follows one of those links: a prefix
can hold a link into somebody else's Steam library, and only the link goes.
`--force` answers the question and nothing more — a prefix with Wine running
in it is refused either way, with the `prefix stop` line to run first.

## How it works

| Half | What it is | Where it comes from |
| --- | --- | --- |
| **Wine** | the Windows implementation — loader, Win32, `winemac.drv` | CodeWeavers' published CrossOver sources (LGPL), built by you |
| **D3DMetal** | Direct3D 12/11 → Metal | Apple's Game Porting Toolkit |

Neither is optional: Wine alone renders nothing for a Direct3D 12 game, and
D3DMetal alone has no process to live in. There is no third option — in
particular Proton cannot be ported here, for reasons in
[docs/why-not-proton.md](docs/why-not-proton.md).

## Status

Early, and honest about which is which.

* **Working** — the Wine build recipe, `protium doctor`, `protium redist`, and
  everything above about prefixes and launching. Elden Ring *plays* on a
  protium-built Wine with no CrossOver runtime involved: save loaded, world
  rendering, character responding to input.
* **Working with a workaround** — signing the Windows Steam client in. Online
  fails inside `CCMInterface::LogOn()` on an unpatched build, because Wine's
  `GetLogicalDrives` never returns when the PE side is clang-built; the root
  cause is measured, proven live, and patched in `patches/`, and a runtime
  built with it reaches Valve's servers. Offline mode plus `-noreactlogin`
  works on either. All in [docs/steam-login.md](docs/steam-login.md).
* **Working** — `protium install`. It fetches from the publisher, prints the
  size and SHA-256 of what arrived, configures the prefix, runs the installer,
  applies the fixes a program needs here, and refuses when it can see the
  installer cannot run. [docs/install.md](docs/install.md).
* **Worked around, not fixed** — CEF rendering. Chromium's display compositor
  runs in a separate GPU process and nothing it composites reaches the window
  here, so Steam paints black. protium writes a stand-in `steamwebhelper.exe`
  that adds `--in-process-gpu`, which works but is the wrong place for the fix:
  it edits a Steam install protium does not own, a Steam update undoes it, and
  every other CEF program still gets nothing. The real fix is a Wine patch.
  Reversible with `protium install steam --undo`
  ([docs/steam-rendering.md](docs/steam-rendering.md)).
* **Broken, and diagnosed** — 32-bit programs in a prefix `protium prefix new`
  made. `wineboot` leaves `syswow64` empty, so nothing 32-bit starts, and
  that is what stops `protium install steam` on a fresh prefix. The Wine's own
  32-bit modules are complete and work once the directory is filled
  ([docs/install.md](docs/install.md#a-32-bit-installer-cannot-run-in-a-prefix-protium-made)).
* **Designed, not built** — talking to the *native* macOS Steam client the way
  Proton's `lsteamclient` does on Linux. The evidence, and the experiment that
  would settle it, are in [docs/steam-bridge.md](docs/steam-bridge.md).
* **Not attempted** — anti-cheat.

**Performance**, on an M4: Elden Ring holds 33 fps at 2560×1440 with every
setting on HIGH, and 59.7 fps — the game's own cap — at 1280×720 on the same
scene. Quartering the pixels moving it that far means the limit is the GPU,
not Rosetta and not the Direct3D-to-Metal translation. Measured with a mod
runtime injected, which costs a little of its own.

## Contributing

```sh
zig build            # the binary, in zig-out/bin
zig build test       # the tests
zig fmt .            # formatting, enforced by the pre-commit hook
```

The pre-commit hook is tracked in `.githooks/` rather than `.git/hooks/`, so it
is reviewable and shared. Activate it per clone with
`git config core.hooksPath .githooks`. It runs the fast checks only —
formatting and a build — and leaves the test suite to CI. `git commit
--no-verify` bypasses it.

## Licensing

protium's own code is **[Apache 2.0](LICENSE)**. It vendors nothing: no
dependencies, no bundled sources, and no linking against either half it
assembles.

The two halves it assembles are not protium's to license, and their terms are
recorded with the versions and evidence behind them in
**[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)**:

* **Wine / CrossOver sources** are LGPL. CodeWeavers publish them because the
  licence requires it; building and using them is what the licence is for. If
  you go on to *redistribute* a Wine you built, the LGPL's conditions come with
  it — protium's Apache licence does not cover those binaries.
* **D3DMetal is Apple's**, under the licence in Apple's download. protium reads
  and installs a copy you obtained yourself.

> [!IMPORTANT]
> protium ships no part of Apple's redistributable, and neither should anything
> built from this repository.

protium is an independent project, not affiliated with or endorsed by Apple,
CodeWeavers, the Wine project or Valve.
