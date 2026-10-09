# Changelog

Each release's notes, newest first. `make notes` turns a version's section,
followed by `tools/release-notes.md`, into the notes on its GitHub release; a
pre-release such as `v0.2.0-rc1` uses its version's section. `make tag`
refuses a version that has no section here, so write the notes first, in a
pull request like any other change.

## v0.4.0

Game controllers reach Windows games, over Bluetooth and USB.

### Changed

* **The runtime is now `wine-11.0-cx26.3-p4`,** built with the two controller
  patches below. `protium runtime install` installs it beside the
  `wine-11.0-cx26.3-p2` you have and does not make it the default. With no
  default set, every command then stops and asks you to pick a runtime; with
  `-p2` set as the default, protium keeps using `-p2`, without the controller
  fixes. Either way, switch with
  `protium use --runtime wine-11.0-cx26.3-p4`. A prefix moves between `-p2`
  and `-p4` freely: the new patches change only how controllers are read.
* **`protium run` now writes two registry values into a prefix that lacks
  them,** `Enable SDL`=0 and `DisableInput`=1 under the `winebus` service. It
  says so the one time it does.

### Fixed

* **A paired controller did nothing in a game.** Wine saw it and then dropped
  it, because winebus refuses a gamepad over the one path this build has —
  IOHID — unless told SDL and evdev are not there. protium now says so in
  every prefix: when it creates one, and the first time `protium run`
  launches something in an older one. A prefix that is already running needs
  `protium prefix stop` once. See `docs/controllers.md`.
* **An Xbox controller over Bluetooth had no right stick,** its stick moved
  the triggers, its triggers did nothing, and its bumpers read as Back and
  Start. `patches/0003` reads the layout it uses.
* **An Xbox controller on USB was not a controller at all.** macOS hands it
  to Wine as raw Xbox protocol (GIP) packets, which nothing in Wine read.
  `patches/0004` decodes them; over USB the controller reports every 8 ms,
  against 30 ms over Bluetooth. Rumble is not implemented.

## v0.3.1

`--yes` answers a question, and `--force` no longer does.

### Changed

* **`--force` no longer answers a question.** `prefix new`, `prefix remove`,
  `prefix migrate-user` and `install clean` refuse it, and say to use `--yes`
  (`-y`) instead. A script that passed `--force` to them stops there rather
  than going ahead. v0.3.0 still took it, with a note. `prefix stop`,
  `install` and `d3dmetal install` keep `--force`, where it means redo or do
  it harder.

### Fixed

* **The docs said `--force`** where `prefix remove`, `install clean` and
  `prefix new` take `--yes`: `docs/prefixes.md`, `docs/install.md` and
  `docs/wine-build.md`.

## v0.3.0

The easy way in: `protium runtime install` is the whole of getting Wine.

### New

* **`protium runtime install` sets up Rosetta 2 as well.** protium's Wine is
  x86-64, because D3DMetal is, so it checks for Rosetta before downloading
  anything and, if it is missing, runs Apple's `softwareupdate
  --install-rosetta` in your terminal, where Apple asks you to accept its
  licence. protium never accepts it for you. `protium prefix new` checks too,
  before it boots a prefix, rather than failing inside Wine.
* **`--yes` (`-y`) answers a command's question,** on `prefix new`, `prefix
  remove`, `prefix migrate-user` and `install clean`. Every check still runs.
  `--force` (`-f`) now only means redo or do it harder: `install`, `d3dmetal
  install` and `prefix stop`.
* **Short options:** `-y`, `-f`, `-p <prefix>` and `-r <runtime>`.
* **`protium doctor` checks what running protium's Wine needs** — Apple
  silicon and Rosetta. **`protium doctor build`** checks what `protium build`
  needs, which is Xcode's command line tools: the build fetches its own bison
  and llvm-mingw.
* **`protium status` and `runtime install` say where Apple's download goes:**
  the Game Porting Toolkit's `.dmg` in `~/Downloads`, or any path given to
  `protium d3dmetal install`. On a release build, `status` suggests
  `protium runtime install` rather than `protium build`.

### Changed

* **`--force` on `prefix new`, `prefix remove`, `prefix migrate-user` and
  `install clean` still answers the question, with a note to use `--yes`.** It
  will stop doing so in a later release.
* **An option a command does not take is an error,** where it used to be
  ignored, and so is an unknown one starting with a single dash: `prefix
  remove games -x` no longer reads `-x` as a name.
* **`protium doctor` no longer looks for bison, flex and llvm-mingw on your
  `PATH`.** Nothing used them: `protium build` fetches its own.

## v0.2.0

The first release that carries Wine itself.

### New

* **`protium runtime install`** installs the Wine runtime this release was
  built with, instead of building one on your Mac. protium downloads it from
  this release and installs it only if its SHA-256 matches the one compiled
  into protium, which the release's signature covers. Because protium downloads
  it rather than a browser, macOS does not quarantine it. `protium build` still
  builds the same Wine on your Mac.
* **The runtime is built by the release itself,** on a GitHub macOS 15 runner,
  and published with the exact source archives it was built from. It carries
  every licence text its contents need, in `licenses/`.
* **macOS 15 and later.** The runtime is built for macOS 15.0. It was checked
  on macOS 15 by the workflow that built it, and played on macOS 26.
* **`protium build` builds FreeType, GnuTLS, Nettle and GMP itself,** from
  pinned, signature-checked sources, where it used to require them prebuilt.
  Every download is pinned by SHA-256, and retried when the failure may pass.
* **New prefixes get Wine Mono** without Wine's "download Wine Mono?" dialog:
  `protium prefix new` fetches it once and checks it against the hash Wine
  pins. .NET programs run in a new prefix.
* **`protium run` finds Steam games** in every Steam library, deeper, and by
  title, and sets `SteamAppId` from Steam's manifest.
* **`protium d3dmetal install` replaces `protium redist`.** It takes Apple's
  Game Porting Toolkit `.dmg`, the evaluation environment in it, either one
  mounted, or its `redist/lib` folder, and with no path uses the
  `Game_Porting_Toolkit_*.dmg` in `~/Downloads`. It checks Apple's payload and
  merges it into the runtime, keeping Wine's own Direct3D modules aside, so
  there is no longer a second, destructive install method to choose between.
  `protium d3dmetal check` reports the runtime's D3DMetal, or what Apple's
  download holds. Tab-completion knows both. `protium redist` is gone.

### Fixed

* **A program protium finds is started in its own directory,** as Steam and
  Explorer start it. Elden Ring 2.7.1.0 stopped at start-up when it was started
  anywhere else.
* **The Wine build no longer picks up Homebrew's libraries** through
  pkg-config. It linked Homebrew's GnuTLS headers on a Mac that had them, and
  failed on a machine whose Homebrew FreeType was arm64.

### Known issues

* Elden Ring ends in a Wine crash report when you quit it from its menu, after
  the game has already stopped. See `docs/quit-crash.md`.

### Licences

* `THIRD-PARTY-NOTICES.md` lists the eighteen libraries Wine links into its
  own DLLs, the libraries a runtime carries in `lib/`, and Wine Mono, which is
  fetched and never shipped.

## v0.1.0

First release. Apple silicon (macOS aarch64) only.
