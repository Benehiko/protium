# Changelog

Each release's notes, newest first. `make notes` turns a version's section,
followed by `tools/release-notes.md`, into the notes on its GitHub release; a
pre-release such as `v0.2.0-rc1` uses its version's section. `make tag`
refuses a version that has no section here, so write the notes first, in a
pull request like any other change.

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
