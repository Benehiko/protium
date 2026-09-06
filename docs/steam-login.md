# Signing the Windows Steam client in, and the one call that fails

The Windows Steam client runs under a protium-built Wine, but it will not sign
in from cached credentials. This document records what that failure actually is
— it is much narrower than "networking is broken" — and the offline-mode route
that gets a game running today regardless.

*Recorded 2026-09-05, against Wine 11.0 built from `crossover-sources-26.3.0`
with D3DMetal 4.0b2, on an M4 Mac running macOS 26.6.1.*

## The short version

A game does not need Steam to be online. It needs Steam to be *running and
signed in*, and offline mode satisfies that. Elden Ring plays this way — title
screen, save loaded, world rendering, character responding to input — with no
CrossOver runtime involved. See
[Offline mode](#offline-mode-the-route-that-works) below.

The online path is still broken, and the fault is one call.

## The failure, stated precisely

Steam's connection manager logs its sign-in decisions to
`logs/connection_log.txt`. On the cached-credentials path both Wines take the
identical route until a single line:

```
[Logged Off, 4, 0] [U:1:…] LogOn() called; not connected yet, scheduling connection. Schedule init returned N
```

| Wine | `N` | What happens next |
| --- | --- | --- |
| CrossOver 26.3 | `1` | `CCMInterface::YieldingConnect` runs, `GetCMListForConnect` returns, connects, `Logged On` |
| protium build | `22` | `YieldingConnect` never runs |

After the `22`, the client emits

```
EConnect called - scheduling connection for 50ms from now
```

roughly eighteen times a second, indefinitely — 8159 such lines accumulated in
one evening. The scheduled connect never fires, so nothing else is ever logged.
`steamclient64.dll` carries three sibling guard strings (`EConnect called while
we're already connected`, `… but connection job is already running`, `… but
connection retry loop is in progress`); none of them is ever hit, so from the
client's point of view it is neither connected, nor connecting, nor retrying.
The scheduler is `CScheduledFunction<CCMInterface>`, one of a family the client
also exposes through a `dump_scheduled_functions` console command.

This is reproducible on demand: the same prefix, the same Steam files, minutes
apart, CrossOver signing in and the protium build looping.

## It is not the network

Every layer below the connection manager works, and works identically:

* **Sockets, DNS, HTTP.** Steam's own connectivity probe succeeds on IPv4, and
  both the IPv6 HTTP and IPv6 UDP probes report `SUCCESS`.
* **TLS and HTTPS.** `logs/bootstrap_log.txt` shows the client fetching its
  update manifest from `https://client-update.fastly.steamstatic.com` and
  getting `HTTP 304 Not Modified` two minutes into a run that is otherwise
  stuck. This is the client's own HTTP stack over Wine's schannel, not CEF's.
* **Adapter enumeration.** `wine ipconfig /all` produces byte-identical output
  under both Wines — 28 adapters, the same four with IPv4 addresses, the same
  default gateway.
* **The CM connection itself.** Earlier the same evening, before any credentials
  were cached, this Wine connected to `155.133.226.78:27017` over UDP,
  completed the connection, and signed in with a JWT. The log line was
  `Clearing in-memory token - 1 (OK): cached creds not available`, and the
  client then took the anonymous path — which works.

So the client can reach Steam, and can sign in. It fails only when it starts
from cached credentials and has to schedule its own connection.

## It is not the black CEF window

These looked like two independent blockers. They are not related, and neither
causes the other. `logs/steamui_login.txt` shows the user-interface state
machine reaching the same point under both Wines:

```
[ None ] Starting login
[ None ] SetLoginState: WaitingForNetwork - OK
[ WaitingForNetwork ] Timed out waiting for network
[ WaitingForNetwork ] Initiating LogOn via state machine transition
```

The interface calls `LogOn()` in both cases. Under CrossOver the call returns
`1` and the client proceeds; under this build it returns `22` and stops. The
rendering problem is real but separate, and it does not need solving to launch
a game.

## Ruled out this session

Each of these was tested, not assumed:

* **Network adapter enumeration** — identical output from both Wines.
* **Spurious power-state events.** `CCMInterface::OnSystemPowerStateResume`
  initiates a reconnect, which would have explained a reconnect loop.
  `connection_log.txt` contains zero power-state lines, ever.
* **DLL overrides.** CrossOver's `wine` is a Perl wrapper; it *deletes*
  `WINEDLLOVERRIDES` and only sets it from an explicit `--dll` option. There is
  no hidden override to copy.
* **msync.** The bottle's `cxbottle.conf` sets `WINEMSYNC=1` in its
  `[EnvironmentVariables]` section, so the CrossOver control ran with msync too.
  Both sides are at parity, and both build it from the same sources.
* **Missing Wine modules.** The two builds' module sets differ only by
  `cxcompatdb`, `winegstreamer`, `winelib`, `winemetal`, vkd3d, and CrossOver's
  own `cx*.exe` tooling. Nothing sign-in related is absent.

## Offline mode, the route that works

Offline mode skips the connection manager entirely. Steam reads the flags from
`config/loginusers.vdf`, so it can be forced without touching the interface —
which matters while the window still paints black:

```
"WantsOfflineMode"        "1"
"SkipOfflineModeWarning"  "1"
```

The account must have signed in online at least once so that the credentials
and the game's licence are cached. `logs/steamui_login.txt` then reports:

```
[ None ] Start offline - 1
[ None ] SetLoginState: WaitingForLibraryReady - OK
[ WaitingForLibraryReady ] SetLoginState: Success - OK
```

`SetLoginState: Success`, and no `EConnect` lines at all — the loop is gone
because nothing is trying to connect.

With that client running, the game is launched directly rather than through
Steam. Launching `eldenring.exe` instead of `start_protected_game.exe` also
bypasses Easy Anti-Cheat, which is what mod loaders need anyway:

```sh
export WINEPREFIX=~/.local/share/protium/prefixes/eldenring
export WINEMSYNC=1
export SteamAppId=1245620
cd ".../steamapps/common/ELDEN RING/Game"
~/.local/share/protium/wine-11.0-cx26.3/bin/wine eldenring.exe
```

`SteamAppId` is what `SteamAPI_Init` reads when there is no `steam_appid.txt`
beside the executable; the running client then registers the app and the game's
own restart check is satisfied.

This reaches actual gameplay. The game opens on its title screen, then reports

```
A connection error occurred. Unable to start in online mode.
Starting in offline mode.
```

which is the correct and expected consequence of an offline Steam — the title
menu then reads `OFFLINE` beside `App Ver. 1.16.2`. `CONTINUE` loads the save
and the world draws: full HUD, foliage, rain and ember particles, terrain to
the horizon, and the character moves under keyboard input.

D3DMetal serves the Direct3D 12 calls and the Metal shader converter compiles
the shaders, both of them logging as they go:

```
[D3DMetal:LOG][EndQuery_block_invoke] Unsupported: ID3D12GraphicsCommandListMTL::EndQuery - Type = 2
[metal-shaderconverter] Warning: Unsupported: culldistance
```

Both messages are noise from features the game asks for and does not need.

## Driving the game without touching the keyboard

Worth knowing when scripting a check: **AppleScript key events do not reach
Wine.** `System Events key code …` returns success and does nothing, even with
the game frontmost and holding focus — confirmed by querying System Events,
which reported the process as `frontmost: true` with one window while the title
screen ignored every keypress.

What works is posting the event at the HID level, which is what real hardware
does:

```c
CGEventRef down = CGEventCreateKeyboardEvent(NULL, keycode, true);
CGEventPost(kCGHIDEventTap, down);
```

A dozen lines of C against `ApplicationServices` is enough, and the game then
responds to keypresses and to keys held for a duration. This is the difference
between "the window is up" and "the game is playable", and only the second one
is worth claiming.

## Two traps this cost time to find

**Alternating the two Wines over one prefix re-initialises it every time.**
Wine compares `$WINEPREFIX/.update-timestamp` against its own `wine.inf`; the
two builds ship different ones, so each launch after the other runs a full
`wineboot --init`. That is slow, it rewrites the registry, and it can hang
outright — `rundll32.exe setupapi,InstallHinfSection DefaultInstall` was seen
blocked in a Cocoa run loop at 0% CPU for six minutes, after erroring on
`wineusb.inf`. Writing `disable` into `.update-timestamp` stops the churn, at
the cost of not picking up changes from a rebuilt Wine. Separate prefixes are
the cleaner answer where the comparison does not require a shared one.

**`CX_LIBVULKAN` does not work in this build.** The string is present in
`win32u.so`, and the CodeWeavers patch it belongs to reads the variable before
falling back to `SONAME_LIBVULKAN`. Setting it to CrossOver's
`libMoltenVK.dylib` changes nothing: the loader still tries the bare
`libvulkan.1.dylib` soname and fails. This build therefore has no Vulkan at
all. It does not stop Elden Ring rendering, because D3DMetal does not use
Vulkan — but it does mean the variable cannot be used to test a MoltenVK
against this Wine. Homebrew's MoltenVK is arm64 and cannot be loaded into an
x86-64 Wine either; the only x86-64 copy on a typical machine is CrossOver's.

## Where to look next

The remaining question is what `Schedule init` returns `22` from. The value is
stable per build — three runs each returned `22` here and `1` under CrossOver —
so it is a real code and not a counter. Steam's `EResult` 22 is
`k_EResultPending`, and `k_EResultPending` is one of the six `EResult` names
`steamclient64.dll` carries as strings, which fits a scheduler that is waiting
on something that never completes.

Finding what it waits on means locating the call site: the format string
`LogOn() called; not connected yet, scheduling connection. Schedule init
returned %d` sits at file offset 19455104 in `steamclient64.dll`, and the call
that produces the value is immediately before the log call.
