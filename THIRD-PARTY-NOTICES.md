# Third-party notices

protium's own code is Apache 2.0 (`LICENSE`, `NOTICE`). This file covers
everything else — the software protium builds, installs and launches but does
not own.

## What protium distributes

This is the load-bearing fact, so it goes first. `build.zig.zon` declares no
dependencies and every file under `src/` is original to this repository.
protium does not vendor, bundle or mirror Wine, D3DMetal or anything else it
assembles. A protium binary contains exactly three things that are not
Apache-2.0-only protium code:

* **Zig's standard library**, compiled in, under Zig's MIT licence — see
  [Zig](#zig-standard-library) below.
* **The Wine patches in `patches/`**, embedded as text so `protium build` can
  apply them without a checkout beside it (`addPatches` in `build.zig`). A
  patch is a change to Wine's LGPL source and quotes Wine's own lines as
  context, so the patches are **LGPL-2.1-or-later**, like the files they
  change — see [patches/README.md](patches/README.md). They are carried in
  source form, which is the form the LGPL asks for.
* **The `steamwebhelper.exe` stand-in**, built from `src/webhelper.zig`. That
  is protium's own code, and is Apache 2.0.

A release archive (`make release`, [docs/releasing.md](docs/releasing.md))
carries the licence text for each: `LICENSE` and `NOTICE`,
`licenses/LGPL-2.1.txt` with the patches beside it in `patches/`, and
`licenses/zig-MIT.txt` taken from the Zig toolchain that built the binary.

What protium does with the rest, instead of shipping it:

* **Wine** — prints a recipe (`docs/wine-build.md`) that *you* run against
  sources *you* download. protium never links Wine; it executes `wine` as a
  separate process.
* **D3DMetal** — copies a payload *you* obtained from Apple into a Wine tree,
  after checking its shape (`src/redist.zig`). It never contains a copy.

So no third-party licence imposes conditions on protium's own source, and
protium is not a combined or derivative work of Wine or D3DMetal: the patches
are the one piece of Wine it carries, and they stay under Wine's licence. The obligations below attach to
the artefacts on your disk after you follow the recipe, and they are yours from
that point on.

## Wine

| | |
| --- | --- |
| **Licence** | GNU Lesser General Public License, version 2.1 or later |
| **Text** | `COPYING.LIB` at the root of the extracted source tree |
| **Version** | Wine 11.0 |
| **Obtained from** | `https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz` |
| **Copyright** | The Wine project authors and contributors; see `AUTHORS` in the source tree |

CodeWeavers publish CrossOver's sources because the LGPL requires it. Building
them and using the result is exactly what that licence exists to permit.

Evidence for the version claim, recorded in
[docs/wine-build.md](docs/wine-build.md#where-the-source-comes-from): `cat
wine/VERSION` in the extracted tree reports `Wine version 11.0`, matching the
`wine-11.0-8726-g2e2f5fca349` string found in a shipped CrossOver 26.3 binary.

Only `sources/wine` is extracted. The tarball also carries CodeWeavers'
bundled MoltenVK, DXVK, vkd3d, FreeType and GStreamer, each under its own
terms; protium's recipe uses none of them, so none is built or installed.

**If you redistribute a Wine you built** — a binary tree, a `.dmg`, a Homebrew
cask — the LGPL's conditions travel with it: convey the source or a written
offer for it, keep the copyright and licence notices intact, and preserve the
recipient's ability to relink. protium's Apache licence does not cover those
binaries and cannot relax those terms.

## D3DMetal (Apple Game Porting Toolkit)

| | |
| --- | --- |
| **Licence** | Apple's, proprietary — the agreement inside the disk image |
| **Text** | shipped in the DMG; also presented at download time |
| **Version** | D3DMetal 4.0b2 (`CFBundleShortVersionString`, `D3DMetal.framework/Versions/A/Resources/Info.plist`) |
| **Obtained from** | `Evaluation environment for Windows games 4.0 beta 2.dmg`, nested inside `Game_Porting_Toolkit_4.0_beta_2.dmg`, downloaded 2026-09-05 |
| **Download URL** | `https://download.developer.apple.com/Developer_Tools/Game_Porting_Toolkit_4.0_beta_1/Game_Porting_Toolkit_4.0_beta_2.dmg` — requires an Apple developer account, and is not a permanent link ([docs/d3dmetal.md](docs/d3dmetal.md)) |
| **Copyright** | Apple Inc. |

**protium ships no part of this and neither should anything built from this
repository.** `protium redist` reads a copy you downloaded under your own
acceptance of Apple's terms and installs it into your own Wine tree. Apple's
agreement governs what you may then do with it — in particular whether you may
pass it on, which is a question for that agreement and not for this file.

The payload and its structure are recorded in
[docs/d3dmetal.md](docs/d3dmetal.md#the-download-contains-no-wine): a
framework, one shared library, and six PE shims each paired with a unix-side
symlink. `src/redist.zig` verifies that shape rather than a fixed file list,
because the list changes between releases.

## Zig standard library

| | |
| --- | --- |
| **Licence** | MIT (Expat) |
| **Text** | `LICENSE` at the root of the Zig installation; shipped as `licenses/zig-MIT.txt` in every release archive |
| **Version** | Zig 0.16.0 |
| **Copyright** | Zig contributors |

The only third-party code linked into the protium binary. MIT asks that its
notice travel with copies, so `make release` copies it from the toolchain that
did the build, and refuses to package without it.

## Build-time tools

These build Wine. None is linked into protium, none is distributed by it, and
none ends up in a prefix. They are fetched into a scratch directory you delete
afterwards — see [docs/wine-build.md](docs/wine-build.md#toolchain) — and are
listed here for completeness rather than obligation.

| Tool | Version in the recipe | Licence |
| --- | --- | --- |
| GNU Bison | 3.8.2 | GPL-3.0-or-later. Its output carries the Bison parser exception, which is why a GPL tool can generate part of an LGPL Wine. |
| llvm-mingw | `…-ucrt-macos-universal` release, `mstorsjo/llvm-mingw` | A bundle, not one licence: LLVM/clang/lld are Apache-2.0 WITH LLVM-exception; the mingw-w64 runtime and headers carry their own permissive terms. Consult the `LICENSE*` files inside the unpacked release. |
| FreeType | 2.13.3 | Dual: the FreeType License (BSD-style, requires attribution) or GPL-2.0-or-later, at your choice. |
| Apple clang / Xcode command line tools | as installed | Apple's, per Xcode's agreement. |
| Zig | 0.16.0 or newer | MIT. Builds protium itself; not part of the Wine recipe. Its standard library is linked in — see above. |

Licences for the first three are stated from their upstream projects' published
terms, not verified against a tree on this machine — the recipe deliberately
leaves nothing installed to inspect. Each release ships its own licence text;
that text governs, not this table.

## Trademarks

Apache 2.0 grants no trademark rights (§6), and this file grants none either.

protium is an independent project. It is not affiliated with, endorsed by, or
sponsored by Apple Inc., CodeWeavers Inc., the Wine project, Valve Corporation,
Bandai Namco Entertainment or FromSoftware. Names such as Apple, Metal,
D3DMetal, Game Porting Toolkit, CrossOver, Wine, Windows, Direct3D, Steam and
Elden Ring are used nominatively — to say truthfully which software this
assembles, runs on, or has been tested against — and remain the property of
their respective owners.
