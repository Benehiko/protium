# protium

**Run Windows games on an Apple silicon Mac.**

A Windows game needs two things macOS does not have: a Windows to run in, and
something to turn its Direct3D graphics into Metal. Both are freely available —
Wine, from published source, and D3DMetal, from Apple. Neither is packaged for
you. protium assembles them, checks them, and then gets out of the way: one
command to launch a game, and a terminal that already knows which Windows
installation it belongs to.

Nothing here is rented, and nothing phones home. What you end up with is an
environment you built and can inspect.

## What you need

* An Apple silicon Mac (M1 or later) with Rosetta 2 installed.
* Apple's free **Evaluation environment for Windows games**, from
  <https://developer.apple.com/games/game-porting-toolkit/>. Apple's page
  states which macOS version that release needs. protium does not redistribute
  it, so you download it yourself.
* An afternoon, once. Step 3 below builds Wine from source and is the only
  genuinely technical part.

protium is for single-player games. It does nothing about anti-cheat, and
games that require it will not run.

## Installing

### 1. Get protium

protium is written in Zig, so you need [Zig](https://ziglang.org/download/)
0.16.0 or newer to build it. This part takes seconds.

```sh
git clone https://github.com/Benehiko/protium
cd protium
zig build --prefix ~/.local -Doptimize=ReleaseFast
```

That puts a single binary at `~/.local/bin/protium`. If `protium version` does
not work afterwards, `~/.local/bin` is not on your `PATH` yet.

### 2. Check your Mac

```sh
protium doctor
```

This reports every prerequisite at once, rather than stopping at the first
thing missing, and says where each one comes from.

### 3. Build the Wine half

This is the long step: roughly an hour, mostly unattended, following the recipe
in **[docs/wine-build.md](docs/wine-build.md)**. It is written out command by
command, including the three mistakes that each cost an hour to find.

Nothing gets installed onto your Mac by it — every build tool is fetched into a
scratch folder you can delete afterwards.

### 4. Add Apple's graphics half

Open Apple's download, find the `redist/lib` folder inside it, and let protium
check it and tell you how to install it:

```sh
protium redist "/Volumes/.../redist/lib" --into ~/.local/share/protium/runtimes/<name>/lib
```

There are two ways to install this folder and one of them destroys the Wine you
just built. protium looks at the destination and prints the correct one. See
[docs/d3dmetal.md](docs/d3dmetal.md).

### 5. Create a Windows installation

```sh
protium prefix new default
```

A *prefix* is one Windows installation — its own `C:` drive, its own registry,
its own installed programs. You can have as many as you like; games that
disagree about what they need get one each. This takes a few minutes.

### 6. Make it automatic

```sh
protium shell-init
```

This prints one line to add to your shell's startup file. After that, every new
terminal already points at your default prefix, so anything you launch from it
lands in the right place without being told.

At any point, `protium status` shows where you are and what the next step is.

## Using it

```sh
protium run ~/Downloads/Setup.exe      # install something
protium run "C:\Program Files\...\Game.exe"

protium prefix list                    # your prefixes; * is the default
protium prefix new skyrim              # another one
protium use skyrim                     # make it the default
```

Each prefix keeps its settings in a `protium.conf` file inside it — frame rate
cap, ray tracing, Wine's own knobs — and they apply automatically to anything
launched there. `protium prefix new` writes a commented starter file listing
what you can set. Full details in **[docs/prefixes.md](docs/prefixes.md)**.

## How it works

An environment is exactly two pieces, from two different places:

| Half | What it is | Where it comes from |
| --- | --- | --- |
| **Wine** | the Windows implementation — the loader, Win32, `winemac.drv` | CodeWeavers' published CrossOver sources (LGPL), built by you |
| **D3DMetal** | Direct3D 12/11 → Metal | Apple's Game Porting Toolkit |

Neither is optional: Wine alone launches a Direct3D 12 game and renders
nothing, and D3DMetal alone has no process to live in.
[docs/why-not-proton.md](docs/why-not-proton.md) explains why there is no third
option, and in particular why Proton cannot be ported here.

Because D3DMetal is x86-64 only, the whole Wine is x86-64 and runs under
Rosetta. That is forced, not a choice — see [docs/d3dmetal.md](docs/d3dmetal.md).

## Status

Early, and honest about which is which:

* **Working** — the Wine build recipe, `protium doctor`, `protium redist`, and
  everything on this page about prefixes and launching. Elden Ring reaches its
  title screen on a protium-built Wine with no CrossOver runtime involved, with
  the Windows Steam client signed in offline —
  [docs/steam-login.md](docs/steam-login.md) has the recipe.
* **Working with a workaround** — signing the Windows Steam client in. The
  online path fails inside one call in `CCMInterface::LogOn()`; offline mode
  sidesteps it and is enough to launch a game. Both are in
  [docs/steam-login.md](docs/steam-login.md).
* **Designed, not built** — talking to the *native* macOS Steam client the way
  Proton's `lsteamclient` does on Linux. The evidence, and the experiment that
  would settle it, are in [docs/steam-bridge.md](docs/steam-bridge.md).
* **Not attempted** — anti-cheat.

## Building and contributing

```sh
zig build            # the binary, in zig-out/bin
zig build test       # the tests
zig fmt .            # formatting, enforced by the pre-commit hook
```

The pre-commit hook is tracked in `.githooks/` rather than `.git/hooks/`, so it
is reviewable and shared. Activate it per clone with `git config core.hooksPath
.githooks`. It runs the fast checks only — formatting and a build — and leaves
the test suite to CI. `git commit --no-verify` bypasses it.

## Licensing, stated once

protium's own code is this repository's business. The two halves it assembles
are not:

* **Wine / CrossOver sources** are LGPL. CodeWeavers publish them because the
  licence requires it; building and using them is what the licence is for.
* **D3DMetal is Apple's**, under the licence in Apple's download. protium reads
  and installs a copy you obtained yourself. It does not ship one, and neither
  should anything built from this repository.
