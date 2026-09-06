# CEF rendering under a protium Wine

**Status: worked around, not fixed.**

Steam's window painted black. It signed in, loaded the library and launched
games, and drew nothing. protium now ships a workaround that makes it paint.
The workaround is in the wrong place and should be replaced. This file records
what the fault is, what we did, and what we should do instead.

*Measured 2026-09-06 against Wine 11.0 built from `crossover-sources-26.3.0`
with D3DMetal 4.0b2, on an M4 Mac running macOS 26.6.1. Steam client
1788652215, CEF/Chromium 126.0.6478.183.*

## The fault

Chromium splits work across processes. Renderers turn HTML into layers, the
browser process owns the window, and the GPU process hosts the *display
compositor*, the piece that puts the finished frame onto the window handle.

Since Chromium M79 the display compositor lives in the GPU process, so every
frame crosses a process boundary on its way to the window. That happens even
with hardware acceleration off: software compositing keeps the compositor in
the GPU process and only changes who does the drawing.

Under a protium Wine that boundary is where the frame is lost. The page renders
correctly, the client works, and nothing reaches the window.

This is a Wine fault, not a Steam fault. It should affect any CEF or Chromium
application under this Wine, though we have only measured Steam.

## What we did

Chromium's `--in-process-gpu` runs the GPU service as a thread inside the
browser process. The compositor then shares a process with the window, no
boundary is crossed, and the window paints.

Steam will not pass the switch on. `steam.exe` forwards exactly six `-cef-*`
flags and drops anything else, and there is no config file, environment
variable or registry key that adds one. So protium writes a stand-in
`steamwebhelper.exe` into the prefix. It appends the switch and launches
Valve's binary, which is moved to `steamwebhelper-real.exe` beside it.

The stand-in is `src/webhelper.zig`, cross-compiled to `x86_64-windows` by
`build.zig` and embedded in the protium binary. Nothing is vendored and no PE
is checked in.

`protium install steam` applies it. `protium install steam --undo` removes it
and restores Valve's file byte for byte.

Steam re-checks `bin/cef` against its own package on every start and puts its
file back, so the client also has to be launched with Steam's own
`-noverifyfiles` and `-norepairfiles`.

## Why this is the wrong fix

1. **It modifies someone else's software.** protium replaces a file inside a
   Steam install it does not own.
2. **Steam updates undo it.** A client update replaces the stand-in. Running
   `protium install steam` again puts it back, but the user has to know that.
3. **It disables Steam's file verification.** `-noverifyfiles` and
   `-norepairfiles` are needed for the stand-in to survive, and they switch off
   a check that exists for good reasons.
4. **It fixes one application.** Every other CEF program under this Wine has
   the same fault and gets nothing.
5. **It is coupled to Steam's internals.** Two hardcoded filenames and a
   directory layout that Valve can change at any time.

## What the real fix looks like

Patch Wine so cross-process presentation works, and build that patch into the
protium Wine. That fixes CEF everywhere instead of Steam specifically, removes
the stand-in, removes the two launch flags, and survives Steam updates.

We have not identified the failing call. The candidates are the shared texture
or shared memory handoff between the GPU process and the browser process, and
the presentation call itself made from one process against a window owned by
another. `winemac.drv` is the suspect.

Next steps for that work:

* Run the webhelper's GPU process by hand, outside Steam, so Wine's own crash
  handler reports a module and offset instead of Chromium's handler swallowing
  it.
* Test a second CEF application to confirm the fault is not Steam specific.
* Trace the presentation path with Wine debug channels on the winemac driver.

## How it was found

The prefix is a copy of a CrossOver bottle, so the registry, the Steam install
and the settings are identical on both sides. The Wine is the only variable,
and CrossOver's logs stay readable after its trial expires. That made it a real
control.

CrossOver's `cef_log.txt`, across sessions from 2026-08-21 to 2026-09-05 on the
same Chromium build, has zero GPU lines. Its `webhelper_gpu.txt` is 822 bytes
for six sessions with no report body, because there was no GPU process. Our
copy of the same file was 2.3 MB of full GPU reports.

Under `-cef-disable-gpu` both sides logged the same first line. Only ours
logged a second:

```
Disabling GPU acceleration: Disabled/CommandLine
GPU process started: start count: 0
```

The working configuration had no GPU process at all. That pointed straight at
`--in-process-gpu`.

## Ruled out

Each of these was run and the window screenshotted.

| Tried | Result |
| --- | --- |
| `-cef-disable-gpu` | GPU process crashes 6 to 0. Still black. |
| `-cef-force-gpu -cef-disable-gpu-sandbox` | Client up, still crashing, still black. |
| `-no-cef-sandbox` | GPU rasterization becomes enabled, but the webhelper's children die and the client never signs in. |
| `-gamepadui` (Big Picture) | No window at all. |
| `explorer /desktop=...` (virtual desktop) | Still black. |
| `WINEDLLOVERRIDES=dcomp=d` | Webhelper never starts. `dcomp.dll` is a load-bearing import. |
| A stand-in `dcomp.dll` returning `E_NOTIMPL` | Same. Chromium needs a DirectComposition device that succeeds. |
| CrossOver's `dcomp.dll` in our runtime | Steam starts and signs in. Still black. Killed the DirectComposition theory. |
| CrossOver's x86-64 MoltenVK as `<runtime>/lib/libvulkan.1.dylib` | Loads, and the `libvulkan` errors stop, but the webhelper never finishes starting. Worse. |
| Deleting `htmlcache` | No change. |
| `-cef-disable-gpu-compositing` | Steam does not pass it on. |

### The GPU process crash is a separate bug

Without `-cef-disable-gpu` the GPU process dies six times per start with
`0xC0000005`, an access violation. Chromium relaunches it three times, gives up
on hardware and continues on SwiftShader. Steam's GPU report also notes `Some
drivers are unable to reset the D3D device in the GPU process sandbox`.

That crash is real and is not why the window was black: eliminating it left the
window black. It is now moot, because there is no GPU process to crash.

### Steam's actual flag list

Taken from the strings in `steam.exe`. Most lists of these online are wrong.

```
-cef-disable-gpu           -cef-disable-gpu-sandbox   -cef-disable-sandbox
-cef-disable-seccomp-sandbox  -cef-force-accessibility  -cef-force-gpu
-no-cef-sandbox
```

That is all of them. `-cef-<anything-else>` is not forwarded to Chromium as
`--<anything-else>`, it is dropped. Confirmed by passing
`-cef-disable-gpu-compositing` and reading the resulting webhelper command line
out of `ps`. There is also no `--remote-debugging-port` route in, so Chromium's
DevTools cannot be attached.

## Checking whether it is working

```sh
grep -ic gpu "<prefix>/drive_c/Program Files (x86)/Steam/logs/cef_log.txt"
```

Zero, and no `--type=gpu-process` among the `steamwebhelper` processes. That is
the same signature the client wrote under CrossOver when it worked.

## Related

Signing in is a different problem with a different answer, in
[`steam-login.md`](steam-login.md). The command that applies the workaround is
described in [`install.md`](install.md).
