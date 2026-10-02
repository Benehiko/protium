# What works

protium is early. This is where it stands, and why.

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
  works on either. See [docs/steam-login.md](steam-login.md).
* **Worked around:** CEF rendering. Chromium composites in a separate GPU
  process, and nothing it draws reaches the window, so Steam paints black.
  protium installs a stand-in `steamwebhelper.exe` that adds
  `--in-process-gpu`. This edits a Steam install protium does not own, a Steam
  update undoes it, and other CEF programs still render black. The real fix
  belongs in Wine. `protium install steam --undo` reverts it.
  See [docs/steam-rendering.md](steam-rendering.md).
* **Works, cause unexplained:** 32-bit programs, Steam's installer among
  them. On 2026-09-06 `wineboot` left `syswow64` empty in new prefixes, and
  nothing 32-bit started. Since 2026-09-07 it fills the directory, with nothing
  changed that we know of. `protium install` still checks, and refuses a 32-bit
  installer if the directory is empty.
  See [docs/install.md](install.md#syswow64-fills-itself-now).
* **Designed, not built:** talking to the native macOS Steam client, as
  Proton's `lsteamclient` does on Linux.
  See [docs/steam-bridge.md](steam-bridge.md).
* **Not attempted:** anti-cheat.

**Performance** on a Mac mini M4: Elden Ring holds 33 fps at 2560×1440 with every
setting on HIGH, and 59.7 fps, the game's own cap, at 1280×720 in the same
scene. A quarter of the pixels nearly doubles the frame rate, so the GPU is
the limit, not Rosetta or the Direct3D translation. These figures were
measured with a mod runtime injected, which costs a little.

## How it works

| Part | What it does | Source |
| --- | --- | --- |
| **Wine** | Implements Windows: loader, Win32, `winemac.drv` | CodeWeavers' published CrossOver sources (LGPL), built by you |
| **D3DMetal** | Translates Direct3D 12 and 11 to Metal | Apple's Game Porting Toolkit |

A game needs both. Wine alone renders nothing for Direct3D 12, and D3DMetal
alone has no process to run in. Proton cannot be ported to macOS;
[docs/why-not-proton.md](why-not-proton.md) explains why.
