# The Steam client's window painted black, and why

For a while the Windows Steam client ran under a protium-built Wine, signed in,
launched games — and drew nothing. A black rectangle where the library should
be. This file records what that was, how it was found, and the fix protium now
applies.

*Recorded 2026-09-06, against Wine 11.0 built from `crossover-sources-26.3.0`
with D3DMetal 4.0b2, on an M4 Mac running macOS 26.6.1. Steam client build
1788652215, CEF/Chromium 126.0.6478.183.*

## The answer

**Chromium's display compositor runs in a separate GPU process, and under this
Wine nothing that process composites reaches the window.** Move the compositor
into the browser process — which is all `--in-process-gpu` does — and the
window paints: store, library, account menu, everything.

`protium install steam` applies this, and `protium install steam --undo` takes
it back off.

The switch is Chromium's, not Steam's. `steam.exe` forwards exactly six
`-cef-*` flags and silently drops anything else, and there is no configuration
file, environment variable or registry key that adds one. So protium writes a
stand-in `steamwebhelper.exe` into the prefix that appends the switch and
launches Valve's own binary, which is moved to `steamwebhelper-real.exe` beside
it rather than deleted. The stand-in is about eighty lines of Zig in
[`src/webhelper.zig`](../src/webhelper.zig), cross-compiled to
`x86_64-windows` by this repository's own `build.zig` and embedded in the
protium binary. Nothing is vendored and no PE is checked in.

Steam checks `bin/cef` against its own package on every start and puts its file
back, so the client has to be launched with Steam's own `-noverifyfiles` and
`-norepairfiles`. `protium install steam` prints the whole command, with the
reason for each argument:

```sh
protium run "C:\Program Files (x86)\Steam\steam.exe" \
    -noreactlogin -noverifyfiles -norepairfiles
```

Launch Steam any other way and it replaces the stand-in; run `protium install
steam` again to put it back. The same applies after a Steam client update.

### How to tell it is working

Steam's own `logs/cef_log.txt` has **no GPU lines at all**:

```sh
grep -ic gpu "…/Steam/logs/cef_log.txt"     # 0
```

and there is no `--type=gpu-process` among the `steamwebhelper` processes. That
is exactly the signature the same client wrote under CrossOver when it worked.

## How it was found

Eleven things were tried first and none of them was it — flags, a Wine virtual
desktop, Big Picture, DLL overrides, a hand-built `dcomp.dll`. The full list is
below, because a fix is worth less than the list of things that were not it.

What actually broke it open was a **control**: the prefix in question is a copy
of a CrossOver bottle, so its registry, its Steam install and its settings are
identical on both sides and the Wine is the only variable. CrossOver's own logs
are still on disk and still readable after the trial expires.

CrossOver's `cef_log.txt` covers sessions from 2026-08-21 to 2026-09-05, on the
same Chromium build, and contains **zero** GPU-related lines. Its
`webhelper_gpu.txt` is 822 bytes for six sessions and holds only:

```
Client version: no bootstrapper found
Disabling GPU acceleration: Disabled/CommandLine
```

with no report body, because there was no GPU process to report on. protium's
copy of that same file, from the same prefix, was 2.3 MB of full GPU reports.
Under protium the same `-cef-disable-gpu` produced the *same* first line and
then one more:

```
Disabling GPU acceleration: Disabled/CommandLine
GPU process started: start count: 0
```

That extra line was the whole difference in one place. Chromium keeps a GPU
process for its display compositor even under `--disable-gpu`, so the only
switch that removes it is `--in-process-gpu` — and passing it turned the window
on immediately.

## Ruled out, each by trying it

Every row was run, and the window screenshotted afterwards.

| Tried | Result |
| --- | --- |
| `-cef-disable-gpu` | GPU-process crashes 6 → 0. **Still black.** |
| `-cef-force-gpu -cef-disable-gpu-sandbox` | Client fully up, still crashes, still software compositing. **Still black.** |
| `-no-cef-sandbox` | GPU *rasterization* becomes `enabled`, so the sandbox is genuinely part of the crash — but the webhelper's children die and the client never signs in. **Worse.** |
| `-gamepadui` (Big Picture) | No window at all. |
| `explorer /desktop=…` (Wine virtual desktop) | **Still black.** |
| `WINEDLLOVERRIDES=dcomp=d` | The webhelper never starts: `dcomp.dll` is a load-bearing import. |
| A stand-in `dcomp.dll` returning `E_NOTIMPL` everywhere | Same. Chromium requires a DirectComposition device that succeeds. |
| CrossOver's own `dcomp.dll` swapped into the runtime | Steam starts and signs in. **Still black** — which killed the DirectComposition theory outright. |
| CrossOver's x86-64 MoltenVK as `<runtime>/lib/libvulkan.1.dylib` | Wine loads it and the `libvulkan` errors stop, but the webhelper never finishes starting. **Worse.** |
| Deleting `htmlcache` | No change. |
| `-cef-disable-gpu-compositing` | **Steam does not pass it on** — see below. |
| A stand-in `steamwebhelper.exe` adding `--in-process-gpu` | **This is the fix.** |

### The GPU-process crash is real, and is not the cause

Without `-cef-disable-gpu`, `cef_log.txt` shows six of these per start:

```
GPU process exited unexpectedly: exit_code=-1073741819
The GPU process has crashed 3 time(s)
```

`-1073741819` is `0xC0000005`, an access violation. Chromium relaunches the
process three times, gives up on hardware and continues on SwiftShader. Steam's
GPU report also carries the note `Some drivers are unable to reset the D3D
device in the GPU process sandbox`, and the hardware path is genuinely
available — `GL_RENDERER: ANGLE (AMD, AMD Compatibility Mode … Direct3D11 …)`
through D3DMetal.

None of that matters for the window: with the crashes eliminated it was still
black, and with `--in-process-gpu` the crashes are irrelevant because there is
no GPU process to crash. The two faults are independent, and only one of them
was ever visible.

### The flags Steam actually understands

Worth writing down, because most lists of these are wrong. Taken from the
strings in `steam.exe` itself:

```
-cef-disable-gpu           -cef-disable-gpu-sandbox   -cef-disable-sandbox
-cef-disable-seccomp-sandbox  -cef-force-accessibility  -cef-force-gpu
-no-cef-sandbox
```

That is the complete set. `-cef-<anything-else>` is **not** forwarded to
Chromium as `--<anything-else>`; it is dropped. Checked by passing
`-cef-disable-gpu-compositing` and reading the resulting `steamwebhelper.exe`
command line out of `ps` — the switch is absent. There is likewise no
`--remote-debugging-port` route in: `steam.exe` contains no string that enables
it, so Chromium's own DevTools cannot be attached.

## What is still not known

* **Why the GPU process cannot present.** The fix sidesteps the question rather
  than answering it. Something in Chromium's cross-process path — shared
  textures, or the presentation to the `HWND` — does not survive
  `winemac.drv`. Answering it properly would fix every CEF application here,
  not just Steam, and would belong upstream in Wine.
* **What faults at `0xC0000005`.** Chromium's own crash handler catches it, so
  Wine never prints a backtrace and `-nocrashdialog` suppresses the rest.
  Launching the GPU process by hand, outside Steam, would let Wine's handler
  name the module and offset.
* **Whether Valve changed something.** The control ran client `1785799196` and
  this ran `1788652215`. Since the fix works on the current one, this now
  matters only for the history.

## Related

Signing in is a separate problem with a separate answer:
[`steam-login.md`](steam-login.md). The command that applies the fix, and the
catalogue it comes from, are in [`install.md`](install.md).
