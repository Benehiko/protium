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

Start the client as `steam.exe -noreactlogin`. The offline-mode flags in
`loginusers.vdf` are necessary but not sufficient on their own — the CEF
login page has to render to choose offline mode, and when it does not, the
client sits logged off forever. The legacy login path has no such
dependency. See [The flags are necessary, not
sufficient](#the-flags-are-necessary-not-sufficient--use--noreactlogin).

The online path is still broken, and the fault is one call. Clicking **go
online** in a client that signed in offline is the same failure — see [What
`Schedule init returned 22` actually
is](#what-schedule-init-returned-22-actually-is).

It is not a networking fault at all. Every connection attempt is gated on a
thread named `MachineIDInfoThread`, which never finishes: it re-asks the
wineserver for the first entry of `\DosDevices` several hundred thousand times
a second and never advances past it. Measured on a running client — see
[Confirmed at runtime](#confirmed-at-runtime-the-thread-is-machineidinfothread).

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

### Clicking **go online** hits the same call

Once offline sign-in works and the window paints, the client shows a **go
online** button. It does nothing, and it is this failure — not a separate one.
Pressing it drives `steam://open/goonline`, which `logs/console_log.txt`
records three times per press, and `logs/steamui_login.txt` records as

```
[ Success ] UI Request: go online
[ Success ] Initiating LogOn
```

with nothing after it. `connection_log.txt` for the same second shows
`SetSteamID`, then `Schedule init returned 22`, then the `EConnect` loop again.
Four presses on 2026-09-06 produced four identical pairs. The button is a
second route into `LogOn()`, so it lands on exactly the branch described below.

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
root="${PROTIUM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/protium}"
export WINEPREFIX="$root/prefixes/eldenring"
export WINEMSYNC=1
export SteamAppId=1245620
cd ".../steamapps/common/ELDEN RING/Game"
"$root/runtimes/wine-11.0-cx26.3/bin/wine" eldenring.exe
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

### The flags are necessary, not sufficient — use `-noreactlogin`

Recorded 2026-09-06, on the same prefix that had signed in offline the night
before. With both flags still set and correct, five consecutive client starts
reached the end of UI init and then never began the login state machine at
all: no `Starting login`, no `Start offline`, nothing written to
`steamui_login.txt`, and `webhelper_js.txt` stopping dead after

```
SteamApp Init - Before Login total time: 474.68 ms
Login: OnLoginStateChange  0 1 0 0
```

The tell is in `connection_log.txt`. A client that signed in offline logs the
account's own ID:

```
[Logged Off, 0, 0] [U:1:<account>] CCMInterface::SetSteamID( [U:1:<account>] )
[Logged Off, 0, 0] [U:1:<account>] LogOff()
```

A stuck one logs only the null ID, `SetSteamID( [U:1:0] )`, and never anything
else. Connectivity is identical in both cases — the connectivity test passes
either way — so a passing network test says nothing about whether the client
signed in.

What fixed it was starting the client on the legacy login path instead of the
CEF one:

```sh
wine "C:\Program Files (x86)\Steam\steam.exe" -noreactlogin
```

Offline sign-in completed 20 seconds later, with `Start offline - 1` and
`SetLoginState: Success`. This fits the black-window problem above: offline
mode is chosen by the React login page, so a login page that never renders
never chooses it, and `-noreactlogin` removes the dependency.

Tried first, and neither made any difference: deleting the CEF cache at
`drive_c/users/crossover/AppData/Local/Steam/htmlcache`, and adding
`"MostRecent" "1"` to the login record. One success, so this is a workaround
that worked rather than a settled explanation.

### How a logged-off client looks to the game

The game does not say "Steam is not signed in". It fails
`SteamAPI_Init()` and exits:

```
[S_API] SteamAPI_Init(): Loaded 'steamclient64.dll' OK.
[S_API FAIL] SteamAPI_Init() failed; connect to global user failed.
```

and then calls `ExitProcess(0)` before the title screen — a clean exit code,
no crash, no error dialog. Under a mod loader this is worth knowing, because
the loader's own injection completes normally first and its log looks
perfectly healthy right up to that line. Read `connect to global user failed`
as "the client is not signed in", not as a broken injection.

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

## What `Schedule init returned 22` actually is

*Read out of `steamclient64.dll` on 2026-09-06, client 1788652215,
`caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee`, and
`tier0_s64.dll`,
`30f7bb8d9b86006852493c26124ba253bd9e7ffd40a8b3c7254f86a9032c3be3`. All
addresses below are virtual addresses at the DLL's preferred image base
`0x138000000`; the file is not relocated on disk, so a file offset converts to
a VA by adding `0x138001A00` for anything in `.rdata` (`.rdata` RVA `0x116b000`,
raw pointer `0x1169600`).*

The value is not an `EResult`. That reading was a coincidence — it is the
return code of the client's own connect-scheduling function, which returns `1`,
`0x0b`, `0x16` (22) or `0x1d` depending on which branch it takes.

### The call site

The format string sits at file offset 19455104, VA `0x13928f680`, and has
exactly one cross-reference in `.text`:

```
1385a55fe: mov  rcx, rbx            ; this = CCMInterface
1385a5601: call 0x1385a1010         ; <- the value comes from here
1385a5606: mov  r8d, eax
1385a5609: lea  rdx, [rip+0xcea070] ; "LogOn() called; not connected yet, ..."
```

`0x1385a1010` is the connect-scheduling function — `EConnect`, by its own log
strings. The same call appears at `0x1385a54b1`, feeding the sibling message
`… scheduling new connection and logon. Schedule init returned %d`.

### What `EConnect` does

```
EConnect(this):
  if (this->0x5f4 && already_connected())          -> log "EConnect called while we're already connected"        ; return 0x0b
  if (FindJob(g_jobmgr+0x250, this->0x158))        -> log "EConnect called but connection job is already running" ; return 0x1d
  if (this->0x160 == 1)                            -> log "EConnect called but connection retry loop is in progress"; return 0x1d
  if (!gate(g_jobmgr))                             -> log "EConnect called - scheduling connection for 50ms from now"
                                                      set_timer(this+0xb38, 50000)
                                                      return 0x16          ; <- 22
  ... allocate a 0x208-byte job named "YieldingConnect", start it, return 1
```

So `22` does not mean an error and does not mean "pending on the network". It
means *the gate said no*, and the client rescheduled itself for 50 ms later.
That is the same branch that writes the `EConnect called - scheduling
connection for 50ms from now` line, which is why those two messages always
appear together and why the log fills at roughly eighteen lines a second.

### The gate

`0x138977de0`, called with the job manager (`[0x1397eb9b8]`) as `this`:

```
gate(jobmgr):
  if (jobmgr->0x1090 == 0) {
      jobmgr->0x1090 = 10;
      tier0_s64!CThread::Start(jobmgr+0x1098, 0);
  }
  return jobmgr->0x1090 != 10;
```

`?Start@CThread@@QEAA_N_K@Z` is resolved from the `tier0_s64.dll` import
descriptor (IAT slot `0x13916c350`, which falls in that DLL's IAT range
`0x116bf78`–`0x116c4a8`). `10` is a sentinel: the worker started from that
`CThread` is what publishes a real value into `+0x1090`. The store that does it
is at `0x138985819`, and it writes `1` or `2` — never `10` — depending on the
result of the call immediately before it.

Two consequences follow, and together they explain everything observed:

* **The first `EConnect` after a client start always returns 22.** The thread
  cannot have published yet. That is normal, and under a working Wine the
  retry 50 ms later finds `+0x1090` set and proceeds to `YieldingConnect`.
* **If the worker never publishes, the client can never recover.** The
  initialiser is guarded by `+0x1090 == 0`, and the sentinel `10` is not zero,
  so `CThread::Start` is called exactly once for the life of the process. Every
  subsequent `EConnect` re-reads `10`, returns 22 and rearms the 50 ms timer.
  This is why the loop is permanent, why it survives clicking **go online**
  repeatedly, and why only restarting the client clears it.

### What `CThread::Start` depends on

`tier0_s64.dll` export ordinal 240, RVA `0x13800` (VA `0x13f013800` at its
preferred base `0x13f000000`). Imports resolved from its IAT the same way:

```
if (m_hThread && GetExitCodeThread(m_hThread, &code) && code == STILL_ACTIVE)
        -> AssertFailed(tier0 line 0xf12); return false
hEvent = CreateEventA(...)                  ; asserts at line 0x806 on failure
hThread = CreateThread(...)                 ; asserts at line 0xf2d on failure
WaitForSingleObject(hEvent, 60000)          ; 60 s handshake
```

So the whole sign-in path hangs on one `CreateThread` plus a 60-second event
handshake in `tier0_s64.dll`. The `EConnect` call returns within the same
logged second, so the 60-second wait is not being hit — the thread is created
and `Start` returns promptly, and the failure is downstream of that: the
worker's body never reaches the store at `0x138985819`.

~~This has not yet been confirmed at runtime.~~ It has — see the next section.
`+0x1090` holding `10` was an inference from which branch is taken; it is now
a read of live memory.

## Confirmed at runtime: the thread is `MachineIDInfoThread`

*Measured 2026-09-07 against the same client build 1788652215, Wine 11.0 from
`crossover-sources-26.3.0`, D3DMetal 4.0b2, on the same M4 host. Every number
below came off a running client, not out of a disassembler.*

The inference above is confirmed, and the thread it blamed now has a name.

### Taking the measurement

`winedbg` can read the client's memory while it loops. It is a PE module in the
runtime — `lib/wine/x86_64-windows/winedbg.exe` — so it needs no build of its
own:

```sh
protium run winedbg --command "info process"            # Wine pids; steam.exe is one
protium run winedbg --command "info share" <pid>        # steamclient64 load address
protium run winedbg --command "p *(long long*)<addr>" <pid>
```

Three practical notes, each of which cost a detour:

* **Addresses move.** `steamclient64` loaded at `0x6fffe5e70000`,
  `0x6fffe5ea0000` and `0x6fffe5fc0000` on three consecutive launches. Take the
  base from `info share` every time and add the RVA — the document's
  `0x1397eb9b8` is `RVA 0x17eb9b8` against the preferred base `0x138000000`.
* **One command per invocation.** `--command "a; b"` is a syntax error, not two
  commands.
* **Attaching is safe.** `--command` attaches, runs, and quits without killing
  the client; this was checked against a throwaway process rather than assumed.
  `bt all`, on the other hand, dies with `Exception c0000005` partway down the
  thread list, so back-trace threads individually.

`sample(1)` remains useless against the client's own threads — the x86-64 side
runs under Rosetta and every stack unwinds to repeated
`__wine_syscall_dispatcher (in ntdll.so)`. It is *not* useless against the
**wineserver**, which is a native binary and symbolises properly. That is how
the spin below was localised:

```
791 thread_poll_event  (in wineserver) + 87
  289 call_req_handler + 276
  199 read_request + 156
  103 call_req_handler + 129
   41 req_get_directory_entries  (in wineserver) + 291
     40 set_reply_data_size + 37
       31 mem_alloc + 14
```

### What the reads say

```
g_jobmgr            = *(void**)(base + 0x17eb9b8)
jobmgr->0x1090      = 0xa          <- the sentinel 10, exactly as inferred
```

`0xa` on three separate launches, so the gate is closed for the life of every
one of them.

The `CThread` the gate starts sits at `jobmgr+0x1098`, and it names itself:

```
+0x00  0x6fffe71a9bd0        vtable
+0x08  0x378                 m_hThread
+0x10  0xffffffff00000294    thread id 0x294 in the low half
+0x18  "MachineI" "DInfoThr" "ead"
```

`MachineIDInfoThread`, and tid `0x294` appears in `info threads` under that
name. **Steam gates every connection attempt on computing a machine ID.** The
whole sign-in path is waiting on that, which is why every network-layer test in
this document passed: they were measuring the wrong layer.

### The thread is not blocked — it is spinning

Six back-traces over 45 seconds all showed the same two frames:

```
=>0 0x006fffffd768d4 in ntdll (+0x568d4)      <- NtQueryDirectoryObject+0x14
  1 0x006fffff742183 GetLogicalDrives+0x103
```

Both attributions were checked against export tables rather than trusted.
`ntdll` RVA `0x568c0` is `NtQueryDirectoryObject`, so `+0x568d4` is inside its
syscall thunk. `kernelbase` has `GetLogicalDrives` at RVA `0x72080` and the next
export at `0x721c0`, so `+0x103` falls inside that function.

A stack that never moves reads as a deadlock. It is the opposite:

```
steam.exe    0.3 %
wineserver  51.3 %   (3:06 of CPU time)
```

`WINEDEBUG=+server` says what the server is doing with that core — 5.8 million
matching lines in the first minute, 8.1 GB of trace before it was stopped:

```
0180: get_directory_entries( handle=0608, index=00000000, max_count=00000001 )
0180: get_directory_entries() = 0 { total_len=170, count=00000001, entries={{
      name=L"HID#VID_845E&PID_0001#0&0000&0&0&0#{378de44c-56ef-11d1-bc8c-00a0c91405dd}",
      type=L"SymbolicLink"}} }
```

36.7 million requests in about a minute, from exactly two threads — `0180`, and
`0298`, which `info threads` identifies as `MachineIDInfoThread`. **`index` is
`00000000` in every one of them.** The enumeration restarts from the beginning,
forever, and the wineserver — which is single-threaded — burns a core answering.

So the client is not waiting on the network, and not waiting on a lock. It is
re-asking for the first entry of `\DosDevices` several hundred thousand times a
second.

### What the object directory actually holds

A 60-line PE that opens `\DosDevices` and walks it with `NtQueryDirectoryObject`
(source under `docs/` is not kept; it is thirty lines of `NtOpenDirectoryObject`
plus a loop) reports the enumeration as **healthy** when given a real buffer —
the cursor advances `0 → 1 → 2 …` and lists the whole directory. Two things
about that listing matter:

```
iter  0: name_len=146  HID#VID_845E&PID_0001#…#{378de44c-56ef-11d1-bc8c-00a0c91405dd}
iter 33: name_len=4    C:
```

The first entry is 146 bytes long, and `C:` is thirty-three entries behind it.
Re-running the same walk with a 40-byte buffer — the size a caller expecting
names like `"C:"` would pick — fails on the **first** call:

```
--- buffer = 40 bytes ---
  iter 0: status 0xc0000023 (enumeration ended)     <- STATUS_BUFFER_TOO_SMALL
```

A caller that treats that as "the directory is empty" sees a machine with no
drives at all, and something that needs a drive would retry. That is the shape
of the observed request pattern.

### Ruled out

* **The dangling `D:`.** The prefix maps `d: -> /Volumes/Game Porting Toolkit`
  and `d:: -> /dev/rdisk4s2`, both gone since the DMG was ejected. It makes no
  difference: a standalone `GetLogicalDrives` returns `0x200000c` (C, D, Z)
  instantly, with Steam stopped *and* while Steam is spinning, and per-drive
  `GetVolumeInformation` answers for all three including the dead `D:`.
* **The HID device.** The obvious reading of the trace is that the 146-byte HID
  name at index 0 is what pushes the caller over. It is not sufficient:
  launching with `WINEDLLOVERRIDES="winebus.sys=d"` removes every `HID#…` entry
  from `\DosDevices` — confirmed by re-running the walk — and the client loops
  exactly as before, with `jobmgr->0x1090` still `0xa`. Removing HID only
  changes *which* long name is first: index 0 becomes a 76-byte
  `{00000017-0000-0000-0000-4E6574446576}`, one of Wine's per-adapter network
  device links (`4E6574446576` is `"NetDev"`), and this host has 28 adapters.
* **The object directory itself, and `NtQueryDirectoryObject`.** Ruled out by
  the strongest control available: the same probe run under CrossOver 26.3,
  which signs in on this host. Its walk is *identical* — the same
  `STATUS_BUFFER_TOO_SMALL` on the first call with a 40-byte buffer, the same
  146-byte HID name at index 0, the same `NetDev` links, the cursor advancing
  the same way, `C:` a few entries either side of thirty-third. Whatever
  diverges between the two builds, it is not this call and not this directory.
* **The dangling `D:`, again.** CrossOver's Steam bottle carries the *same*
  dead mappings — `d: -> /Volumes/Game Porting Toolkit` and
  `d:: -> /dev/rdisk4s2`, both pointing at an ejected DMG — and reports `D:` in
  its drive mask (`0x300000c` against protium's `0x200000c`; the only
  difference is CrossOver's extra `Y:` mapped to the home directory). It signs
  in anyway.

Running the CrossOver client itself under `WINEDEBUG=+server`, to see whether
it makes the same requests and merely escapes the loop, was attempted and did
not work: `wine --cx-app`, `bin/wineloader` and `cxstart` all return without
starting `steam.exe`, leaving an idle `winewrapper.exe` behind. The bottle's
client appears to need CrossOver's own launcher. Probes copied into the bottle
and run with `bin/wineloader` work fine — that is how the two results above
were taken — provided `WINEMSYNC=1` is exported to match the running
wineserver, or the loader exits with `msync_init Server is running with
WINEMSYNC but this process is not`.

### Still unknown

Why the caller restarts at `index=0` instead of advancing. Two readings fit
every measurement above, and they have different fixes:

1. An outer loop that re-enumerates from scratch on each pass, never finding
   what it wants — consistent with `max_count=1` and a caller that gives up on
   the first long name.
2. An inner loop whose cursor is not carried between calls.

Telling them apart needs the frame above `GetLogicalDrives`, which `winedbg`
cannot currently produce (the unwinder faults one frame further up), or Wine's
sources for `GetLogicalDrives` and `NtQueryDirectoryObject` — which the build
recipe deletes with its scratch directory.

## Where to look next

Get the caller. `winedbg`'s unwinder faults immediately above
`GetLogicalDrives`, so the frame that matters is the one frame it will not
produce. Keeping the Wine source tree from the build (rather than deleting the
scratch directory) would also settle reading 1 versus reading 2 by inspection.

The CrossOver control has been half-taken (see *Ruled out*): its `\DosDevices`
enumeration is identical, so the divergence is not there. The other half —
does *its* `MachineIDInfoThread` complete, and does its client make the same
requests — still needs a way to start the bottle's Steam from a shell with
`WINEDEBUG` set. Every documented route returns without launching it.

The other open question is whether this is the same underlying Wine fault as
the CEF one in [`steam-rendering.md`](steam-rendering.md). Both are "a thread
or process starts, and the thing it is supposed to hand back never arrives",
and neither has been traced to a call yet. They may be one bug.

