# protium

A Proton-shaped compatibility runtime for macOS: run Windows games on Apple
silicon by pairing a Wine built from published sources with Apple's D3DMetal.

Proton does not exist for macOS and cannot be ported — it is an ELF Wine
driving DXVK and VKD3D-Proton on Vulkan, none of which Apple ships. What macOS
has instead is Wine plus a Direct3D-to-Metal translation layer. protium
assembles that stack from sources and redistributables anyone can obtain, and
documents every part of it, so the environment a game runs in is a thing you
built rather than a product you rented.

## The two halves

A working environment is exactly two pieces, and they come from different
places:

| Half | What it is | Where it comes from |
| --- | --- | --- |
| **Wine** | the PE loader, the Win32 implementation, `winemac.drv` | CodeWeavers' published CrossOver sources (LGPL), built here |
| **D3DMetal** | D3D12/D3D11 → Metal, as PE shims plus a framework | Apple's Game Porting Toolkit DMG, redistributed under Apple's licence |

Neither half is optional. Wine alone runs a Direct3D 12 game and renders
nothing; D3DMetal alone has no process to live in. See
[`docs/why-not-proton.md`](docs/why-not-proton.md) for why there is no third
option, and [`docs/d3dmetal.md`](docs/d3dmetal.md) for what Apple actually
ships.

## Status

Early. What is established, and what is not, is stated plainly rather than
implied:

* **Documented and verified** — the anatomy of Apple's evaluation environment,
  the architecture constraint it imposes, and a reproducible Wine build recipe
  from CrossOver 26.3.0 sources, including the one source patch that build
  needs. See [`docs/wine-build.md`](docs/wine-build.md).
* **Implemented** — `protium doctor`, which checks a host for everything the
  recipe needs, and `protium redist`, which verifies an Apple redist tree and
  plans its installation into a Wine tree.
* **Designed, not built** — the Steam bridge: making a Windows game's
  `steam_api64.dll` talk to the *native* macOS Steam client, the way Proton's
  `lsteamclient` does on Linux. The evidence that this is possible, and the
  cheap experiment that would settle it, are in
  [`docs/steam-bridge.md`](docs/steam-bridge.md).
* **Not attempted** — anything about anti-cheat. protium is for running games
  offline and single-player.

## Requirements

* A Mac with Apple silicon, macOS 15 or later.
* Rosetta 2. D3DMetal is x86-64 only, so the whole Wine is x86-64 and runs
  translated. This is not a choice protium makes; see
  [`docs/d3dmetal.md`](docs/d3dmetal.md).
* Apple's *Evaluation environment for Windows games*, from
  <https://developer.apple.com/games/game-porting-toolkit/>. protium does not
  redistribute it.

## Use

```
protium doctor                          # is this host ready to build and run?
protium redist <dir>                    # verify an Apple redist tree
protium redist <dir> --into <wine-lib>  # plan the install into a Wine tree
```

`doctor` reports each prerequisite separately rather than failing at the first
one, because the answer people need is the whole list.

## Building

protium is Zig, and needs Zig 0.16.0 or newer:

```
zig build            # the binary, in zig-out/bin
zig build test       # the tests
zig fmt .            # formatting, enforced by the pre-commit hook
```

## Git hooks

The pre-commit hook is tracked in `.githooks/` rather than living in
`.git/hooks/`, so it is reviewable and shared. Activate it per clone:

```
git config core.hooksPath .githooks
```

It runs the fast checks only — formatting and a build — and leaves the full
test suite to CI, so committing never blocks for minutes. `git commit
--no-verify` bypasses it.

## Licensing, stated once

protium's own code is this repository's business. The two halves it assembles
are not:

* **Wine / CrossOver sources** are LGPL. CodeWeavers publish them because the
  licence requires it; building and using them is what the licence is for.
* **D3DMetal is Apple's**, distributed under the licence in Apple's DMG.
  protium reads and installs a copy you obtained yourself. It does not ship
  one, and neither should anything built from this repository.
