# The Steam bridge: designed, not built

This is the piece that would make protium a compatibility *tool* rather than a
Wine build recipe. It is not implemented. What follows is the evidence that it
is possible, the design it would take, and the cheap experiment that should
come before any of it.

## The problem

A Windows game's `steam_api64.dll` expects to reach a Steam client through
Windows IPC. Two arrangements are possible on macOS:

* **Windows Steam inside the prefix.** Works today, and is what every existing
  macOS solution does. The cost is that you run a whole second Steam: its CEF
  UI process (`steamwebhelper`) is the least stable thing in the environment,
  and when it dies the game's `SteamAPI_Init()` fails with `connect to global
  user failed` or hangs before the title screen.
* **The native macOS Steam client**, bridged. This is what Proton does on
  Linux, and it is why Proton is more than Wine.

## What Proton actually does

Two components, both open source in the Proton tree:

* `lsteamclient` — a Wine module that thunks the Windows Steamworks API onto
  the *native* `steamclient.so`, with generated thunks per interface version.
* `steam.exe` / `steam_helper` — an in-prefix stub the game's library talks to,
  plus the environment setup (`STEAM_COMPAT_*`).

## Evidence that the macOS client can host this

**1. The native client's `steamclient.dylib` is universal.**

```
$ lipo -archs ~/Library/Application\ Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib
x86_64 arm64
```

Since D3DMetal forces an x86-64 Wine anyway, that Wine can `dlopen` the x86-64
slice **in process** — exactly the shape `lsteamclient` relies on.

**2. Wine on macOS already has the module split this needs.** Apple's own
D3DMetal ships as paired `lib/wine/x86_64-windows/d3d12.dll` and
`lib/wine/x86_64-unix/d3d12.so`, which is precisely a PE module fronting a
Mach-O unix library. The mechanism is proven in the exact environment.

**3. The macOS client contains the whole Steam Play surface.** Strings in
`steamclient.dylib`:

```
/compatibilitytools.d                     GetCompatToolMappingPriority
/usr/share/steam/compatibilitytools.d     Software\Valve\Steam\CompatToolMapping
SetProtonEnvironment                      STEAM_COMPAT_APP_ID
proton_compat_config                      STEAM_COMPAT_CLIENT_INSTALL_PATH
@sSteamCmdForcePlatformType               PROTON_HIDE_PROCESS_WINDOW
```

and in `steamui.dylib`: `Apps.ClearProton`, `proton_launch_params`.

**This is not proof the code paths are reachable.** Valve build one source tree
across platforms, and the Linux `/usr/share/...` paths in that list suggest the
block is compiled in unconditionally rather than shipped deliberately. It makes
the question an experiment rather than a guess.

## Do the experiment before the work

Cost: about an hour. Value: it decides whether the rest is worth starting.

1. Create `~/Library/Application Support/Steam/compatibilitytools.d/protium/`
   with a `compatibilitytool.vdf` and a `toolmanifest.vdf` whose tool is a
   script that logs its argv and exits.
2. Restart Steam. Does the tool appear in Steam Play settings, or in a Windows
   game's compatibility tab?
3. Force it for a Windows-only title and press Play. Is the script invoked, and
   is it invoked as `waitforexitandrun <exe>`?

If Steam never calls the script, the compatibility-tool route is closed on
macOS and the bridge can only be driven by a launcher of our own — which is
fine, and much less work than `lsteamclient` itself.

Note that a launcher of our own is a perfectly good target. Steam does not have
to *launch* the game; it only has to be running and signed in for the bridge to
have a client to talk to.

## Getting Windows depots

Not a blocker. The macOS client contains `@sSteamCmdForcePlatformType`, and
steamcmd takes it as a console variable:

```
steamcmd +@sSteamCmdForcePlatformType windows +login <user> +app_update <id> validate +quit
```

An already-installed Windows depot in another prefix can also simply be added
as a Steam library folder rather than re-downloaded.

## Order of work

1. The compatibility-tool probe above.
2. A native-client launch path that sets the environment and runs the game
   under protium's Wine, with Windows Steam still in the prefix. This isolates
   the launcher from the bridge.
3. `lsteamclient` for macOS — the real work, and a permanent maintenance
   surface as Steamworks interface versions change. Do not start it before
   step 1 has an answer.

## Probe result, 2026-09-05: inconclusive, leaning negative

The probe above was run. A tool was registered at
`~/Library/Application Support/Steam/compatibilitytools.d/protium-probe/` with a
`compatibilitytool.vdf` (`from_oslist windows`, `to_oslist macos`), a
`toolmanifest.vdf` naming a script, and a script that logs its argv. Steam was
then started fresh.

Four signals, all pointing the same way, none decisive:

* Steam had **never created `compatibilitytools.d`** itself. On Linux it does,
  at startup.
* **No `compat_log.txt`** appeared in `logs/`. On Linux, Steam writes one
  recording which tools it discovered.
* After a full startup, **nothing in `logs/` or `config/` mentions the tool**,
  and `config.vdf` gained no `CompatToolMapping` section.
* **`steamui.dylib` carries no user-facing Steam Play strings** — no "force the
  use of a specific compatibility tool", no "compatibility tool". The internal
  identifiers (`Apps.ClearProton`, `proton_launch_params`) are there, but those
  are the compiled-in shared-source symbols already noted above, not UI.

The script was never invoked, but that proves nothing on its own: nothing was
launched through the tool.

### A method that does not work here, recorded so it is not tried again

Checking whether Steam *read* the `.vdf` files by comparing their access times
before and after startup looks conclusive and is worthless: a control — reading
a file and re-checking — showed the access time does not move on this volume.
macOS does not maintain atime here. Any conclusion drawn from those timestamps
is an artefact.

### What would actually settle it

* **The UI.** Open a Windows-only title's Properties. If there is no
  Compatibility tab, and Settings has no Steam Play section, the mechanism is
  not exposed and the question is closed.
* **A syscall trace.** `sudo fs_usage -w -f filesys` filtered to the Steam
  process while it starts, looking for any open of `compatibilitytools.d`. This
  is the decisive one; it needs root.

### It would not change the plan either way

Even a Steam that happily invoked our tool would only decide *who spawns the
process*. The game would still call `SteamAPI_Init()` and still find no client
inside the prefix. The bridge is the work; the registration is not.
