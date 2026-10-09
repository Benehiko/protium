# protium

**Play your Windows games on a Mac.** Run Windows Steam games on macOS with
Wine and Apple's D3DMetal, on Apple silicon.

Elden Ring on a Mac mini M4: 60 fps at 1280×720, the game's own cap, or 33 fps
at 2560×1440 with every setting on High. Your Steam library, in Windows Steam,
on macOS. No Boot Camp, no virtual machine, no subscription.

protium is a free, open-source command-line tool that sets up the two pieces
that make it work: **Wine**, which runs Windows programs on macOS, and
**D3DMetal**, the Direct3D-to-Metal translator from Apple's own Game Porting
Toolkit. Then it gets out of the way:

```sh
protium runtime install       # Wine, ready-built
protium d3dmetal install      # Apple's D3DMetal
protium prefix new default    # a Windows C: drive
protium install steam
protium run "elden ring"
```

It costs nothing, sends nothing anywhere, and everything it sets up is yours
to inspect. It runs single-player games; anti-cheat does not work.

> [!TIP]
> To play tonight, buy [CrossOver](https://www.codeweavers.com/crossover)
> instead. It ships Wine and D3DMetal prebuilt and supported. protium is free
> and early, and leaves you with an environment you can see into and change.

## Quickstart

### 1. What you need

* **An Apple silicon Mac** on macOS 15 or later. Apple's D3DMetal 4.0b2 needs
  macOS 26.4 or later.
* **Apple's [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)**
  DMG, which needs a free Apple developer account. Leave it in `~/Downloads`,
  where your browser saves it. [More about it](docs/d3dmetal.md).

### 2. Install protium

```sh
V=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/Benehiko/protium/releases/latest)
V=${V##*/}                   # the latest release's tag, such as v0.3.0
curl -LO https://github.com/Benehiko/protium/releases/download/$V/protium-$V-macos-aarch64.tar.gz
tar -xzf protium-$V-macos-aarch64.tar.gz
mkdir -p ~/.local/bin
install -m 755 protium-$V-macos-aarch64/protium ~/.local/bin/protium
protium version
```

If `protium version` fails, add `~/.local/bin` to your `PATH`. Every release
is signed; the [release notes](https://github.com/Benehiko/protium/releases)
show how to check it.

### 3. Set up Wine and D3DMetal

```sh
protium runtime install      # Wine from this release, and Rosetta 2 if your Mac lacks it
protium d3dmetal install     # Apple's D3DMetal, from the toolkit DMG in ~/Downloads
protium prefix new default   # create a Windows prefix
protium shell-init           # print a line to add to your shell's rc file
```

Wine is checked against the SHA-256 this release was signed with before it is
installed. If Rosetta 2 is missing, Apple asks you to accept its licence in
your terminal. Saved the toolkit somewhere else? `protium d3dmetal install
<path-to-dmg>`. Lost? `protium status` says what comes next.

Prefer to build Wine yourself? See
[Build Wine yourself](docs/wine-build.md#build-wine-yourself).

### 4. Install Steam and play

```sh
protium install steam
protium run steam            # sign in online, once
protium run "elden ring"     # by title, Steam app ID, or .exe name
```

protium installs Steam with the fixes it needs on a Mac, and finds your games
in every Steam library. Elden Ring's menu reads `OFFLINE`; that is expected,
and `CONTINUE` loads your save. [Using protium](docs/usage.md) covers Steam,
games and prefixes in full.

## Elden Ring with mods and co-op

[elden-ring-mods](https://github.com/Benehiko/elden-ring-mods) runs Elden Ring
on protium with Lua mods and private co-op over LAN or a VPN. Its launcher,
`ermod-engine`, finds protium on your `PATH` or at `~/.local/bin/protium`,
picks the prefix that holds Elden Ring, and launches through
`protium run --prefix <name>`:

```sh
./ermod-engine --dry-run              # finds your game and protium; launches nothing
./ermod-engine --backend protium      # play, through protium
```

It never writes to your game install or your saves, and Easy Anti-Cheat never
runs. Download it from its
[latest release](https://github.com/Benehiko/elden-ring-mods/releases/latest)
(`…-macos-aarch64.tar.gz`) and follow its
[macOS install guide](https://github.com/Benehiko/elden-ring-mods/blob/main/docs/install.md#macos).

## Learn more

* [Using protium](docs/usage.md): Steam, running games, prefixes, everyday commands
* [What works](docs/status.md): what plays, what doesn't yet, and how fast
* [D3DMetal](docs/d3dmetal.md): what Apple ships, and where to get it
* [Build Wine yourself](docs/wine-build.md#build-wine-yourself): from CodeWeavers' published sources
* [Why not Proton?](docs/why-not-proton.md)
* [elden-ring-mods](https://github.com/Benehiko/elden-ring-mods): Elden Ring with Lua mods and co-op, on protium
* [Contributing](CONTRIBUTING.md)

## FAQ

**Can I play Windows games on a Mac?** Yes, on an Apple silicon Mac. protium
runs them in Wine, and Apple's D3DMetal translates Direct3D to Metal. No Boot
Camp or virtual machine is involved.

**Can I play Steam games on macOS that only have a Windows version?** Yes.
protium installs Windows Steam into a Wine prefix, finds the games in your
Steam libraries, and launches them by title: `protium run "elden ring"`.

**Is it free?** Yes. protium is open source under Apache 2.0, and it has no
subscription. [CrossOver](https://www.codeweavers.com/crossover) is the
paid, supported option.

**Do online games with anti-cheat work?** No. protium runs single-player
games. [What works](docs/status.md) lists the details.

**Can I use an Xbox controller?** Yes, over Bluetooth or USB, from protium
v0.4.0. A new install gets the runtime that supports it,
`wine-11.0-cx26.3-p4`. If you are upgrading from an older runtime, protium
keeps using that one until you switch:
`protium use --runtime wine-11.0-cx26.3-p4`. USB responds faster than
Bluetooth, and rumble does not work yet.
[Game controllers](docs/controllers.md) has the details.

## Licence

protium's own code is [Apache 2.0](LICENSE). The Wine patches in
[`patches/`](patches/README.md) are LGPL-2.1-or-later, like Wine. Wine and
D3DMetal are not protium's to license:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) records their terms.

> [!IMPORTANT]
> protium ships no part of Apple's redistributable, and nothing built from this
> repository should.

protium is an independent project, not affiliated with or endorsed by Apple,
CodeWeavers, the Wine project or Valve.
