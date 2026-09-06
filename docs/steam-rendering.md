# The Steam client's window paints black

The Windows Steam client runs under a protium-built Wine, signs in, and
launches games. Its own window draws nothing: a black rectangle where the
library should be. This file records what that failure is and — more usefully —
the eleven things it is **not**, each of which was tried rather than reasoned
about.

*Recorded 2026-09-06, against Wine 11.0 built from `crossover-sources-26.3.0`
with D3DMetal 4.0b2, on an M4 Mac running macOS 26.6.1. Steam client build
1788652215, CEF/Chromium 126.0.6478.183.*

> [!IMPORTANT]
> **This does not stop a game running.** Steam only has to be signed in, and
> [`steam-login.md`](steam-login.md) gets it there without the window ever
> being readable. Elden Ring plays like this.

## The short version

Not solved. `-cef-disable-gpu` is worth passing anyway — it removes six GPU
process crashes per start — and `protium install steam` prints it for that
reason, with the reason attached. It does not make the window paint.

The failure is inside Chromium's presentation path, after compositing and
before the window: Chromium believes it composited a frame, and nothing
reaches the `HWND`.

## What is established

**Wine paints windows correctly.** `protium run winecfg` renders completely —
tabs, text, buttons, the lot — in the same prefix, in the same session, at the
same moment the Steam window is black. Whatever is broken is not `winemac.drv`
drawing a window.

**Steam works apart from its window.** In every run below the client reached
`SetLoginState: Success`, loaded the library, and wrote its logs. The UI
process is alive and its page is running: `webhelper_js.txt` records the whole
React app starting — `SteamApp Init - Before Login total time: 440ms`,
`Login: OnLoginUsersChanged` — and `cef_log.txt` carries console output from
`https://steamloopback.host/index.html`. The page renders. It does not arrive.

**Chromium always ends in software compositing.** Steam's own GPU report,
which the client writes to `logs/webhelper_gpu.txt`, ends every run with

```
[ gpu_compositing ]: disabled_software
[ direct_rendering_display_compositor ]: disabled_off_ok
```

**The GPU process crashes, and that is a separate fault.** Without
`-cef-disable-gpu`, `cef_log.txt` shows six of these:

```
GPU process exited unexpectedly: exit_code=-1073741819
The GPU process has crashed 3 time(s)
```

`-1073741819` is `0xC0000005`, an access violation. Chromium relaunches the
process three times, gives up on hardware, and continues on SwiftShader.
Adding `-cef-disable-gpu` and changing nothing else takes the count to zero,
in three separate starts — and the window is black either way, which is what
makes it a separate fault rather than the cause. (It is not proof against
every combination: adding `-gamepadui` on top brought three crashes back.)

**The hardware path exists.** The same report's `featureStatusForHardwareGpu`
section shows Chromium found a working Direct3D 11 device through D3DMetal:

```
GL_RENDERER: ANGLE (AMD, AMD Compatibility Mode (0x000066AF) Direct3D11 vs_5_0 ps_5_0, ...)
[ video_decode ]: enabled
```

alongside the note `Some drivers are unable to reset the D3D device in the GPU
process sandbox`. So the crash is plausibly a sandbox-plus-D3D11 interaction —
but see below, because turning the sandbox off does not help.

**Chromium is using DirectComposition.** `lsof` on the GPU process lists
`dcomp.dll` among its mapped modules, and Wine logs the call:

```
fixme:dcomp:DCompositionCreateDevice3 ..., {5f4633fe-1e08-4cb8-8c75-ce24333f5602}, ...
```

once per GPU process start. Wine's `dcomp.dll` implements
`DCompositionCreateDevice`, `…Device2` and `…Device3`, and stubs
`DCompositionCreateSurfaceHandle` outright — a DirectComposition that answers
"supported" and then composites nothing. That is the best-fitting theory for a
black window, and the two experiments that would confirm it both fail for a
different reason (below).

## Ruled out, each by trying it

Every row was run, and the window screenshotted afterwards.

| Tried | Result |
| --- | --- |
| `-cef-disable-gpu` | GPU crashes 6 → 0. **Still black.** |
| `-cef-force-gpu -cef-disable-gpu-sandbox` | Client fully up, still 6 crashes, still software compositing. **Still black.** |
| `-no-cef-sandbox` | GPU *rasterization* becomes `enabled` — so the sandbox is genuinely part of the crash — but the webhelper's child processes die and the client never signs in. **Worse.** |
| `-gamepadui` (Big Picture) | No window appears at all. |
| `explorer /desktop=…` (Wine virtual desktop) | **Still black.** |
| `WINEDLLOVERRIDES=dcomp=d` | The webhelper never starts. `dcomp.dll` is a load-bearing import, not an optional one. |
| A stand-in `dcomp.dll` returning `E_NOTIMPL` from every entry point | Same: no webhelper, no window. Chromium requires a DirectComposition device that succeeds. |
| Deleting `htmlcache` | No change. |
| `-cef-disable-gpu-compositing` | **Steam does not pass it on.** Only the six `-cef-*` flags in the table below reach CEF; anything else is dropped silently. |
| Restarting into a fresh client (Steam self-updated mid-session, 1788400362 → 1788652215) | No change. |
| Watching for a JavaScript failure | None. The page's own logs show a complete, successful start-up. |

### The flags Steam actually understands

Worth writing down, because most lists of these on the internet are wrong.
Taken from the strings in `steam.exe` itself:

```
-cef-disable-gpu           -cef-disable-gpu-sandbox   -cef-disable-sandbox
-cef-disable-seccomp-sandbox  -cef-force-accessibility  -cef-force-gpu
-no-cef-sandbox
```

That is the complete set. `-cef-<anything-else>` is **not** forwarded to
Chromium as `--<anything-else>`; it is ignored. This was checked by passing
`-cef-disable-gpu-compositing` and reading the resulting `steamwebhelper.exe`
command line out of `ps` — the switch is absent.

There is also no `--remote-debugging-port` route in: `steam.exe` contains no
string that enables it, so Chromium's own DevTools cannot be attached to
inspect what the compositor thinks it produced.

## Where to look next

The two experiments that would settle the DirectComposition theory both fail
because Chromium will not start without a DComp device that succeeds. The
useful version is therefore not "remove `dcomp`" but "**implement enough of
it**": a `dcomp.dll` whose `DCompositionCreateDevice2/3` return a device that
Chromium accepts and whose visual tree actually blits to the `HWND`. That is a
Wine-side change, and it would fix this for every CEF application rather than
for Steam.

Failing that, the two questions worth answering first:

1. **What exactly faults at `0xC0000005` in the GPU process?** Chromium's own
   crash handler catches it, so Wine never prints a backtrace and
   `-nocrashdialog` suppresses the rest. Running the webhelper's GPU process
   by hand, outside Steam, would let Wine's handler report the module and
   offset.
2. **Does any other CEF application paint here?** That separates "Steam's
   window" from "CEF under `winemac.drv`" in one test, and no test in this
   file does.

## What to do meanwhile

```sh
protium run "C:\Program Files (x86)\Steam\steam.exe" -noreactlogin -cef-disable-gpu
```

`-noreactlogin` is what gets the client signed in without the window —
[`steam-login.md`](steam-login.md) explains why — and `-cef-disable-gpu` saves
six process crashes on the way. `protium install steam` prints both, with
their reasons. Then launch the game directly rather than through Steam's UI,
which is what [the README](../README.md) already describes.
