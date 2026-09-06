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

> [!WARNING]
> Set `WINEMSYNC=1` in the prefix's `protium.conf` **before** installing.
> Steam's UI fails silently without it, in a way that looks like a network
> fault ([why](docs/wine-build.md#winemsync1-is-not-optional)).

```sh
curl -Lo /tmp/SteamSetup.exe https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe
protium run /tmp/SteamSetup.exe
```

> [!NOTE]
> Sign in **online, once**, so your credentials and game licences cache. Then
> install your game from Steam's UI as normal.

```sh
protium run "C:\Program Files (x86)\Steam\steam.exe"
```

### Every launch after that, offline

Online sign-in is broken here — it fails inside one call, and
[docs/steam-login.md](docs/steam-login.md) names it. Offline mode sidesteps it
entirely, and a game needs nothing more.

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
protium run ~/Downloads/Setup.exe      # install something
protium run "C:\Program Files\…\Game.exe"

protium prefix list                    # your prefixes; * is the default
protium prefix new skyrim              # another one
protium use skyrim                     # make it the default
```

A *prefix* is one Windows installation — its own `C:` drive, registry and
programs. Games that disagree about what they need get one each.

Each prefix keeps its settings in a `protium.conf` inside it — frame cap, ray
tracing, Wine's own knobs — applied automatically to anything launched there.
Full details in **[docs/prefixes.md](docs/prefixes.md)**.

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
  fails inside `CCMInterface::LogOn()`; offline mode plus `-noreactlogin`
  works. Both in [docs/steam-login.md](docs/steam-login.md).
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
