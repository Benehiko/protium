# Game controllers

A controller that macOS has paired reaches a Windows game under protium through
one path, and until 2026-10-09 that path was closed at two points. This
document records what they were, what protium does about each, and how to
check a controller from the command line.

*Measured 2026-10-09 with an Xbox Wireless Controller (`045e:0b13`, firmware
5.9.2709.0) paired over Bluetooth LE, against Wine 11.0 from
`crossover-sources-26.3.0` on macOS 26. Reported as: Steam shows the
controller connected, and Elden Ring does not respond to it.*

## The short version

* **The prefix has to let the controller through.** protium writes two
  values under `HKLM\System\CurrentControlSet\Services\winebus` — `Enable
  SDL`=0 and `DisableInput`=1 — when it creates a prefix, and into an older
  prefix the first time `protium run` launches something in it. winebus reads
  them when it starts, so a prefix that was already running needs `protium
  prefix stop` once.
* **The runtime has to read it correctly.** Over Bluetooth, `patches/0003`
  teaches Wine's XInput readers the layout the controller uses. Over USB,
  `patches/0004` decodes the raw Xbox protocol macOS hands over. Both are in
  `wine-11.0-cx26.3-p4` and later.
* **Rumble needs `wine-11.0-cx26.3-p6`.** `patches/0005` drives the motors
  over USB, `patches/0006` over Bluetooth; see
  [Rumble over USB](#rumble-over-usb) and
  [Rumble over Bluetooth](#rumble-over-bluetooth).
* **USB is faster.** The controller reports every 8 ms on USB and every
  30 ms on Bluetooth; see [Latency](#latency-where-it-goes).

## The one path a controller has

Wine's `winebus.sys` has several backends. In protium's build only one of them
can carry a controller:

| Backend | State here |
| --- | --- |
| SDL | not built: `SDL support not compiled in!` |
| CrossOver's Xbox bus | turns itself off: `disabled: running on macOS Sequoia or later` |
| udev / evdev | Linux only |
| IOHID | works, and sees the controller |

IOHID finds the controller and describes it correctly:

```
trace:hid:handle_DeviceMatchingCallback dev 0x7faaea805ca0, desc {vid 045e,
  pid 0b13, version 0509, input -1, uid 1f8e2dcb, is_gamepad 1, is_hidraw 1, bus_type 0}.
```

## First block: winebus drops it

IOHID hands the controller over as a raw (`hidraw`) device, and winebus
refuses a gamepad on that path by default:

```
warn:hid:bus_main_thread ignoring hidraw device 045e:0b13 with usages 0001:0005
```

The rule exists for Linux, where SDL or evdev would carry a gamepad and hidraw
would be a duplicate. winebus accepts it when SDL is off and evdev is
disabled — and neither exists in this build, so saying so changes nothing
else. With `Enable SDL`=0 and `DisableInput`=1, the same trace says `creating
hidraw device 045e:0b13`, and the prefix gains `HID\VID_045E&PID_0B13&IG_00`
(the device XInput opens) and `…&XI_00`.

Before this, a prefix's `HKLM\System\CurrentControlSet\Enum\HID` held only
Wine's own virtual mouse and keyboard, `VID_845E&PID_0001` and `PID_0002`.
That is the quickest way to tell whether a controller was dropped.

## Second block: XInput misreads it

Over Bluetooth, the controller's report descriptor (from `ioreg -l -c
IOHIDDevice`) is not the shape Wine's XInput readers assume:

| Control | The controller reports | Wine read it as |
| --- | --- | --- |
| Left stick | Generic X / Y | X / Y ✓ |
| Right stick | Generic Z / Rz | Rx / Ry, which it does not have — so: no right stick |
| Triggers | Simulation Brake / Accelerator | Z / Rz — the right stick |
| Buttons | A=1, B=2, X=4, Y=5, LB=7, RB=8, View=11, Menu=12, LS=14, RS=15 | usages 1–10 in order |
| Y axes | down is positive, as HID's are | up is positive |

On Linux, SDL rewrites the report before Wine sees it. Here nothing does, and
a capture with the controller in hand showed exactly what the table predicts:
`R=(4,17)` throughout, both triggers resting at 128 and following the right
stick, the bumpers arriving as Back and Start, and X as Y. Every report also
logged `HidP_GetUsageValue rx returned 0xc0110004` (`HIDP_STATUS_USAGE_NOT_FOUND`).

`patches/0003` changes both readers — `dlls/xinput1_3/main.c`, which every
`xinput1_*.dll` and `xinputuap.dll` is built from, and `dlls/winexinput.sys`,
which builds the DirectInput-facing gamepad. A gamepad with Z and Rz, Brake and
Accelerator, and no Rx or Ry is read as this layout: Z/Rz as the right stick,
Brake/Accelerator as the triggers, the buttons renumbered, Y taken as HID gives
it. Anything else is read exactly as before. With it, XInput's capabilities
change from `RX=0 RY=0` to `RX=7 RY=7`, the triggers rest at 0, and both
readers log `right stick on Z/Rz, triggers on Brake/Accelerator: Xbox Bluetooth
layout`.

## Over USB: raw GIP, decoded

*Measured 2026-10-09 with the same controller on a USB-C cable, where it is
`045e:0b12`.*

On macOS 15 and later, Apple's `XboxUSBDevice` driver owns the controller
(`UsbExclusiveOwner`), and IOHID gets two devices from it, neither of them
usable as it stands:

| Device | What it is | What Wine could do with it |
| --- | --- | --- |
| `045e:0b12` "Controller" | primary usage gamepad, but the descriptor is vendor-defined bytes only: input reports `0x20` (18 bytes) and `0x07`, outputs `0x01` and `0x05` — the controller's own GIP packets | admitted as a raw gamepad, then `winexinput` finds nothing to read (`HidP_GetButtonCaps returned 0xc0110004`) and XInput reports no controller |
| `045e:028e` "GamePad-1" | `AppleGCSyntheticDevice`: a 360-style HID gamepad macOS publishes for GameController's sake, every 8 ms | invisible: `IOHIDManager` never offers it, to Wine or to a native program |

CrossOver's `bus_xbox360.c` is no help: it speaks the Xbox 360 protocol over
IOUSB, not GIP, and disables itself on Sequoia because GameController owns the
device.

Report `0x20` is GIP's input packet, the one Linux's `xpad` decodes:

| Bytes | Field |
| --- | --- |
| 0–3 | header: `20`, flags, sequence, length (`2c`; the payload is cut at 18 bytes) |
| 4–5 | buttons: Menu `0x0004`, View `0x0008`, A `0x0010`, B `0x0020`, X `0x0040`, Y `0x0080`, d-pad `0x0100`–`0x0800` (up, down, left, right), LB `0x1000`, RB `0x2000`, LS `0x4000`, RS `0x8000` |
| 6–9 | left and right trigger, 0–1023 |
| 10–17 | LX, LY, RX, RY, signed 16-bit, up positive |

`patches/0004` recognises such a device — Microsoft's vendor ID, vendor pages
and no buttons or axes in its descriptor — and builds for it the gamepad the
SDL backend builds, translating each report with SDL's button numbering. It
stays flagged hidraw, so the same two registry values admit it.

Measured against a native IOHID listener as for Bluetooth below: reports every
8.0 ms (median, 3.9 ms at the fastest), XInput's state 1.2 ms behind them
(p90 1.7 ms), and all 247 stick values identical, Y included. Of the
buttons, a raw capture showed A, B, LB, RB, LS and RS at the bits above; X,
Y, Menu, View, the d-pad and the guide report are GIP's documented layout,
not yet seen from this controller.

### Rumble over USB

Under `patches/0004` alone the decoded gamepad had no haptics in its
descriptor and its haptics callbacks returned `STATUS_NOT_SUPPORTED`, so
`XInputGetCapabilities` reported no force feedback and `XInputSetState` did
nothing. `patches/0005` (`wine-11.0-cx26.3-p5`) adds the haptics collection
the SDL backend adds, and turns each request into GIP's rumble command, as
Linux's `xpad` sends it to an Xbox One controller:

| Byte | Value |
| --- | --- |
| 0–3 | `09` (rumble), `00`, sequence, `09` (payload length) |
| 4–5 | `00`, `0f` (all four motors) |
| 6–7 | left and right trigger motor, intensity / 512 |
| 8–9 | left (strong) and right (weak) motor, intensity / 512 |
| 10–12 | on period `ff`, off period `00`, repeat `ff`: run until the next command |

Stopping sends the same command with every motor at zero. All 13 bytes are
written as output report `0x01`.

Why report `0x01` with `09` still in the first byte: the passthrough device's
descriptor (`ioreg`, 2026-10-09, `045e:0b12` on macOS 26) is

```
05010905a1010600ff150026ff00850109017508950c9102850509057508950491028507
090775089505810285200920750895128102c0
```

which declares output report `0x01` with 12 bytes and `0x05` with 4, and the
device's `MaxOutputReportSize` is 13. The device is Apple's DriverKit driver
`/System/Library/DriverExtensions/XboxGamepad.dext` (`CoreController` 13.6.2,
class `XboxSeriesXGamepad`). Its x86-64 code, read with `otool -tV`:

* `XboxWirelessGamepad::setReport` accepts an output report only when the
  report ID is `0x01` and the buffer 13 bytes, or the ID `0x05` and the buffer
  5 bytes. Anything else returns `0xe00002c2`; `IOHIDDeviceSetReport` with
  report `0x09` came back `0xe00002eb`.
* `XboxHIDDevice::setReport` then hands the buffer, as it is, to the USB OUT
  pipe (`IOUSBHostPipe::AsyncIO`). It does not prepend the report ID or look
  at the bytes.

So the report ID only gets the buffer past the driver; the controller sees the
buffer. Measured with a native program (`IOHIDDeviceSetReport`, outside Wine)
and the controller in hand:

| Report ID | First byte | Driver | Controller |
| --- | --- | --- | --- |
| `0x09` | `09` | `0xe00002eb` | nothing |
| `0x01` | `01` | success | nothing: GIP command `01` is not rumble |
| `0x01` | `09` | success | vibrates, and stops on the zero command |

Through Wine, the same day, in a fresh prefix on a development runtime with
`patches/0005` (only `winebus.so` rebuilt), a console probe built as in
[Checking a controller](#checking-a-controller) got:

```
caps ret 0 flags 0x1 vib L=255 R=255
on  ret 0
off ret 0
```

`XINPUT_CAPS_FFB_SUPPORTED` (`0x1`) is set, where before the patch the
capabilities reported no vibration. Under `WINEDEBUG=+hid` each
`XInputSetState` reached `gip_device_haptics_start` (`rumble_intensity 65535,
buzz_intensity 65535`) and `gip_device_haptics_stop`, and no
`IOHIDDeviceSetReport returned` warning was logged. The controller vibrated at
full strength for the two seconds between the two calls, and stopped.

A refused write logs `IOHIDDeviceSetReport returned` with the `IOReturn` on
the hid channel. Not yet tried: a game driving it, and the trigger motors on
their own (XInput has no call for them).

### Rumble over Bluetooth

*Measured 2026-10-10 with the same controller paired over Bluetooth
(`045e:0b13`).*

Over Bluetooth the controller reaches XInput as its raw HID device, and that
device has no Haptics page collection, the only thing XInput's reader looks
for. XInput therefore reported no force feedback and `XInputSetState` did
nothing.

Its descriptor (`IOHIDDeviceGetProperty`, `kIOHIDReportDescriptorKey`)
carries rumble on the Physical Interface Device page instead, as output
report `0x03` inside a Set Effect Report collection (`0f:21`);
`MaxOutputReportSize` is 9:

| Byte | Usage (`0f:…`) | Value |
| --- | --- | --- |
| 0 | — | report ID `03` |
| 1 | DC Enable Actuators `97`, 4 bits | `0f`: all four |
| 2–5 | Magnitude `70`, 4 × 8 bits, 0–100 | left trigger, right trigger, left motor, right motor |
| 6 | Duration `50`, 10 ms units | `ff` |
| 7 | Start Delay `a7` | `00` |
| 8 | Loop Count `7c` | `eb` |

Written natively with `IOHIDDeviceSetReport` as `03 0f 00 00 3c 3c ff 00 eb`,
the bytes SDL's HIDAPI driver uses, the controller vibrates; the same report
with zero magnitudes stops it.

`patches/0006` (`wine-11.0-cx26.3-p6`) teaches `dlls/xinput1_3/main.c`, which
every `xinput1_*.dll` and `xinputuap.dll` is built from, to look for this
report when there is no haptics collection — an output Magnitude array of four
bytes on the PID page — and to write each `XInputSetState` as it: all four
actuators enabled, the left and right motor scaled to the Magnitude's logical
maximum, the triggers at zero, and duration `ff` with loop count `eb` so that
the motors run until the next call. The output report passes through
`winexinput.sys` to winebus's raw IOHID device, which writes it unchanged.

Through Wine, in a fresh prefix with the rebuilt xinput DLLs, the probe from
[Checking a controller](#checking-a-controller) got:

```
caps ret 0 flags 0x1 vib L=255 R=255
on  ret 0
off ret 0
```

and `WINEDEBUG=+xinput` showed `Found PID rumble, report 3 collection 3`, then
`magnitudes 0 0 100 100` and `magnitudes 0 0 0 0`. The controller vibrated at
full strength for the two seconds between, and stopped. Not yet tried: a game
driving it, and DirectInput force feedback over Bluetooth.

## Latency: where it goes

With both fixes in place, Elden Ring responded to the controller and the
response felt late. Measured the same day, with the game running:

| Stage | Median | p90 | Max |
| --- | --- | --- | --- |
| Controller → macOS: gap between reports | 30.0 ms | 31.1 ms | 47.6 ms |
| macOS → XInput in the prefix | 0.9 ms | 1.4 ms | 5.8 ms |

The first row is a native IOHID listener (`IOHIDDeviceRegisterInputReportCallback`
on `045e:0b13`) timestamping each report with `mach_continuous_time`. The second
is a console program in the prefix polling `XInputGetState` every millisecond
and timestamping each new packet with `QueryPerformanceCounter`, which on macOS
is the same clock in the same units (`monotonic_counter` in
`dlls/ntdll/unix/sync.c`). The two streams were matched on the left stick's
raw value: all 266 XInput packets had a native report behind them.

So Wine adds about a millisecond, and its resolution here is the 1 ms poll.
What the controller costs is the Bluetooth link: a report roughly every 30 ms
(about 33 a second), so an input waits 15 ms on average before macOS has it at
all. That is the link macOS negotiated, not anything in Wine, and a native
game sees the same rate.

Whatever remains is the game's own frame pipeline — an input is read on one
frame and shown a frame or more later, so at a low frame rate that dominates.
Two things tell the cases apart: whether the keyboard feels as late as the
controller (then it is the frames, not the controller), and the frame rate
itself, which Apple's Metal HUD shows over any Metal app, D3DMetal included,
with `MTL_HUD_ENABLED=1`.

Wine's own tracing is not free either: `WINEDEBUG=+xinput` writes a line from
the game's thread on every poll, and `+hid` several per report. Measure
latency with `WINEDEBUG=-all`.

## Checking a controller

`joy.cpl` needs a window, and Wine cannot open one from a shell outside the
login session (`launchctl managername` says `Background`): the Mac driver
fails with `The graphics driver is missing`. A console program does not need
one. Twenty lines of C against `xinput.h`, built with the llvm-mingw that
`protium build` leaves in `<root>/build/llvm-mingw`, calling
`XInputGetCapabilities` and then polling `XInputGetState`, is enough to see
every control:

```sh
x86_64-w64-mingw32-clang -O1 -o xiprobe.exe xiprobe.c -lxinput
protium run ./xiprobe.exe
```

To see what winebus did with a device, start a prefix from nothing with
`WINEDEBUG=+hid,+plugplay`; winebus only enumerates when it starts, so a
prefix whose wineserver is already running shows nothing new.

Run a probe in a throwaway prefix rather than a working one: `/tmp` is
refused (`'/tmp' is not owned by you`), so use somewhere under your home.

## Still open

* **Steam Input.** Whether Elden Ring needs Steam Input off for this
  controller has not been measured.
* **Steam saw the controller when the prefix did not.** Before the fix,
  Steam reported the controller as connected while the prefix's `Enum\HID` held
  no `VID_045E` device at all. How Steam saw it is not known.
* **Other controllers.** Only `045e:0b13` over Bluetooth has been measured.
  winebus accepts a DualShock 4 or DualSense over hidraw even without the
  registry values (`is_hidraw_enabled` in `dlls/winebus.sys/main.c`), but
  their reports are not XInput's layout either, `patches/0003` does not
  cover them, and how XInput reads them is not measured.
