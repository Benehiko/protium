# Signing the Windows Steam client in, and the one call that fails

The Windows Steam client runs under a protium-built Wine, but it will not sign
in from cached credentials. This document records what that failure actually is
— it is much narrower than "networking is broken" — and the offline-mode route
that gets a game running today regardless.

*Recorded 2026-09-05, against Wine 11.0 built from `crossover-sources-26.3.0`
with D3DMetal 4.0b2, on an M4 Mac running macOS 26.6.1. Re-measured 2026-09-07
in a prefix rebuilt from nothing, reporting Windows 11 and carrying freshly
copied credentials: [neither changed the
outcome](#windows-11-and-fresh-credentials-change-nothing), and the failure
turns out to be intermittent rather than permanent. Root cause found
2026-09-08: [a Wine bug in how its two halves pass a `BOOLEAN`, exposed by
protium's clang-built PE side](#the-caller-read-directly--and-the-bug-it-exposes),
proven by zeroing one stack slot in the running client and watching it
connect. A second, unrelated blocker was found behind it the same day —
[the build had no TLS](#the-second-blocker-no-tls-so-every-websocket-cm-connection-fails),
so every WebSocket connection manager failed — and fixing both puts a working
sign-in page in front of a live connection.*

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
is](#what-schedule-init-returned-22-actually-is). It fails on roughly seven
starts in eight rather than all of them; the one that got through was stopped
by Valve rejecting a copied token, not by anything in Wine.

It is not a networking fault at all. Every connection attempt is gated on a
thread named `MachineIDInfoThread`, which never finishes: it re-asks the
wineserver for the first entry of `\DosDevices` several hundred thousand times
a second and never advances past it. Measured on a running client — see
[Confirmed at runtime](#confirmed-at-runtime-the-thread-is-machineidinfothread).

Why it never advances is now known, and it is not Steam's doing. The thread is
inside Wine's own `GetLogicalDrives`, answering a WMI query; the cursor *is*
carried between calls, and the callee ignores it because a `BOOLEAN` the PE
side wrote as one byte is read by the unix side as 32 bits, with whatever was
on the stack above that byte. Which is also why it is a race: the die is the
stale contents of one stack slot. The evidence, the CrossOver comparison, and
the one-qword live proof are in [The caller, read
directly](#the-caller-read-directly--and-the-bug-it-exposes); the fix is
`patches/0001-…`, built into a second runtime, `wine-11.0-cx26.3-p1`.

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
  stuck. ~~This is the client's own HTTP stack over Wine's schannel, not
  CEF's.~~ **The second half of that was wrong.** It cannot have been Wine's
  schannel: every run in this document until 2026-09-08 had no TLS backend at
  all, because `libgnutls` was never installed where the loader could find it
  ([the second blocker](#the-second-blocker-no-tls-so-every-websocket-cm-connection-fails)).
  Steam bundles its own TLS and this fetch used it. The observation stands —
  the client reaches the internet and gets an answer — but it says nothing
  about Wine's TLS, and the section this bullet belongs to overstated its case
  for a fortnight because of it.
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

*Settled 2026-09-08, and both readings were wrong: see [The caller, read
directly](#the-caller-read-directly--and-the-bug-it-exposes).*

## Windows 11 and fresh credentials change nothing

*Measured 2026-09-07 in a prefix deleted and rebuilt from nothing for this
test. Wine 11.0 built from `crossover-sources-26.3.0`; D3DMetal 4.0b2
(`CFBundleShortVersionString` from
`lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist`); macOS
26.6.2, build 25G83, on an M4 Mac. Steam client 1788652215. The prefix reports
`Microsoft Windows 10.0.22000` — Windows 11 21H2 — where every earlier
measurement in this document was taken at `10.0.19045`.*

Two things had never been varied: the Windows version the prefix reports, and
the age of the cached credentials. Both were changed at once, in a prefix with
no history at all. **Neither made any difference to the fault.** In five of six
client starts the log line is still

```
LogOn() called; not connected yet, scheduling connection. Schedule init returned 22
```

followed by the same `EConnect called - scheduling connection for 50ms from
now` loop — 784 to 1142 lines per start, at the same eighteen a second.

### What was rebuilt, and how

`protium prefix remove eldenring` reported 2.1 GB (2246234082 bytes), 11509
files, 13 symlinks of which 12 led out of the prefix, and unlinked them without
following them; the 66 GB Elden Ring install in the CrossOver bottle and both
`ermod` directories were still there afterwards. `protium prefix new eldenring`
then made a prefix whose `syswow64` was populated on its own — see
[`syswow64` fills itself now](install.md#syswow64-fills-itself-now), which is a
correction to a claim this repository was making.

The Windows version was set with Wine's own tool, `winecfg /v win11`. It
changes five values, in both the 64-bit and the `Wow6432Node` view of
`Software\Microsoft\Windows NT\CurrentVersion`:

| Value | Before | After |
| --- | --- | --- |
| `CurrentBuild`, `CurrentBuildNumber` | `19045` | `22000` |
| `ProductName` | `Windows 10 Pro` | `Microsoft Windows 11` |
| `UBR` | `0x16a4` | `0x24c` |
| `CSDVersion` | absent | `""` |

and leaves `CurrentVersion` (`6.3`), `CurrentMajorVersionNumber` (10) and
`CurrentMinorVersionNumber` (0) alone. `cmd /c ver` then answers `Microsoft
Windows 10.0.22000` from both `system32` and `syswow64`.

**`winver` is not a check on this.** Wine's `winver.exe` draws "Wine 11.0 /
Running on wine-11.0" and never mentions the Windows version it is reporting to
programs, so it can neither confirm nor deny the change. `cmd /c ver` is the
one to use.

### (a) Is it still 22? Yes — but it is a race, not a wall

This document has said the loop is permanent, on the reasoning that `EConnect`'s
initialiser is guarded by `+0x1090 == 0` and so `CThread::Start` runs exactly
once per process. That reasoning is unchanged and still fits. What is new is
that the *worker* is not guaranteed to lose:

| Start | Login path | `Schedule init returned` | `EConnect` lines |
| --- | --- | --- | --- |
| 1 | CEF | **1** | 0 |
| 2 | CEF | 22 | 1788 |
| 3 | CEF | 22 | 1142 |
| 4–7 | CEF | 22 | 805, 805, 788, 784 |
| 8 | `-noreactlogin` | 22 | 1052 |

Start 1 is the first time this build has been observed getting past the gate.
It went the whole way: `CCMInterface::YieldingConnect`, `PingWebSocketCM`
against fourteen connection managers, `Connect() starting connection
(eNetQOSLevelHigh, cmp1-fra1.steamserver.net:443, WebSocket)`,
`ConnectionCompleted()`, `Logging on`. That is the CrossOver route, in this
Wine, with `Schedule init returned 1`.

It did not reproduce. Seven consecutive starts afterwards — same prefix, same
files, credentials restored from the bottle before each one so the cached-login
path was taken every time — all returned 22. So **`MachineIDInfoThread` is a
race that is almost always lost, not a thread that always hangs.** One start in
eight is not a workaround, but it does rule out a hard deadlock, and it means
anything that changes startup timing is worth trying.

`-noreactlogin` makes no difference to this. It is a different login path into
the same `LogOn()`, and start 8 returned 22 like the rest.

### (b) Does it reach `Logged On`? No — and the reason is not Wine

The one start that connected got an answer from Valve:

```
[Logging On, 4, 7] [U:1:<account>] Using JWT …, persistence: 1, issued: Fri Aug 21 21:17:50 2026, expiry: Sat Mar 20 00:17:42 2027
[Logging On, 4, 7] [U:1:<account>] RecvMsgClientLogOnResponse() : [I:0:0] 'Access Denied'
Clearing in-memory token - 15 (Access Denied): LogonFailureReceived(2)
[Logged Off, 4, 0] [U:1:<account>] ConnectionDisconnected() not auto reconnecting due to Access Denied
```

The token was inside its own validity window and the server refused it anyway.
A Steam refresh token is bound to the client that obtained it, so a copy of the
CrossOver bottle's token is not usable from a different prefix — which is a
statement about Valve's authentication, not about Wine. **Reaching `Logged On`
from this prefix needs a fresh interactive sign-in — account password and Steam
Guard — typed into the client's own login page.** Nothing in this document
blocks that any more; only the intermittent gate above stands in front of it.

The rejection has a side effect worth knowing, because it silently changes what
the next start does. The client rewrites `config/loginusers.vdf`:

| Key | Before | After the rejection |
| --- | --- | --- |
| `RememberPassword` | `1` | `0` |
| `AutoLogin` | `1` | replaced by `AllowAutoLogin` `0` |
| `MostRecent` | absent | `1` |

`AppData/Local/Steam/local.vdf` is *not* touched — the encrypted token is still
sitting there. So a second start after a rejection is not testing the same
thing as the first: auto-login is off, the client sits at
`SetLoginState: WaitingForCredentials`, and the connection attempt comes from
the interface (`UI Request: connect`) rather than from cached credentials.
Restore `loginusers.vdf` between runs or the comparison is not a comparison.

### (c) Does CEF render? Yes — once the stand-in is in the right directory

It does, and the black window seen on start 1 was protium's own bug rather than
a Wine fault.

**Steam ships two `steamwebhelper.exe`s.** `bin/cef/cef.win64` and
`bin/cef/cef.win7x64` both exist — in this prefix and in the CrossOver bottle —
and the client runs one or the other. protium's stand-in
(`docs/steam-rendering.md`) was only ever installed into `cef.win64`. On start 1
the client ran `cef.win7x64`, where Valve's own 7697048-byte binary was still
in place, and the result is exactly the documented unfixed behaviour: six
`GPU process exited unexpectedly` lines, `Disabling GPU acceleration:
Disabled/CrashCount`, and a `Sign in to Steam` window that painted solid black.

With the stand-in in both trees, `cef_log.txt` has **zero** GPU lines — the
signature this document already records for the working case — and the client's
windows paint.

**What decides which tree is used is not known, and it is not the Windows
version.** That was the first guess and it is wrong: starts 1 and 3 both ran at
`10.0.22000` and used different trees. `cef.win7x64` appeared in the prefix
during start 1, so a client mid-way through fetching it is the likelier
explanation, but that has not been pinned down. The fix does not depend on
knowing: `protium install steam` now replaces the binary in **every** CEF tree
present and skips the ones that are not there yet, because a fix that covers
one of two interchangeable copies is a fix that works until it does not.

### The credential set, and which part is the credential

Five things were copied out of the CrossOver bottle. Only one of them is a
secret:

| What | Where | What it carries |
| --- | --- | --- |
| `AppData/Local/Steam/local.vdf` | prefix user's AppData | **The credential.** `MachineUserConfigStore/Software/Valve/Steam/ConnectCache` holds the refresh token, DPAPI-encrypted. Wine's `crypt32` stamps the blob `Wine Crypt32 ok` and uses a fixed key, which is why the file is portable between prefixes at all. |
| `config/config.vdf` | Steam root | `Authentication/RememberedMachineID` — the machine-auth JWT that keeps Steam Guard quiet — and `Accounts/<name>/SteamID`. Not the login credential. |
| `config/loginusers.vdf` | Steam root | *Who* to sign in as, and the `RememberPassword` / `AutoLogin` / `WantsOfflineMode` / `SkipOfflineModeWarning` flags. No secret at all. |
| `HKCU\Software\Valve\Steam\AutoLoginUser` | prefix registry | The account name, for the legacy login path. Set with `protium run reg add`, not by copying `user.reg`. |
| `userdata/<id>/` | Steam root | Per-user settings and cloud cache. Not a credential; copied so the client's first run matches the bottle's. |

A grep for a JWT across the whole Steam tree finds it in `config.vdf` and
nowhere else, and the only other encrypted blob is `local.vdf`'s. Copying
`userdata/` or the registry alone signs nobody in.

### Offline mode needs the app cache, which is not a credential either

Offline mode failed at first in the rebuilt prefix, and not for any of the
reasons above:

```
[ None ] Start offline - 1
[ WaitingForLibraryReady ] Timed out waiting for library ready: 15.000000s - offline
[ WaitingForLibraryReady ] SetLoginState: WaitingForCredentials - Offline App Cache invalid
```

`Start offline - 1` is reached — the flags are read and honoured — and the
client then finds it has no idea what the account owns. `appcache/` (161 MB,
`appinfo.vdf` and `packageinfo.vdf`) and `depotcache/` had gone with the old
prefix. Copying both from the bottle turns that into

```
[ None ] Start offline - 1
[ WaitingForLibraryReady ] SetLoginState: Success - OK
```

So the sentence elsewhere in this document — "the account must have signed in
online at least once so that the credentials and the game's licence are cached"
— is right, and `appcache/` is where the second half of it lives. A prefix
rebuilt from scratch needs it copied in alongside the credential, or offline
mode gets as far as `Start offline - 1` and stops.

### Where that leaves the prefix

Signed in offline, and playing. `steam.exe -noreactlogin -noverifyfiles
-norepairfiles` reaches `SetLoginState: Success`, and Elden Ring launched
directly against it — `SteamAppId=1245620`, `eldenring.exe` rather than
`start_protected_game.exe`, exactly as
[Offline mode](#offline-mode-the-route-that-works) describes — draws its title
screen at `PRESS ANY BUTTON`, with D3DMetal and the shader converter logging
the same two harmless complaints as before:

```
[D3DMetal:LOG:DCE1E][EndQuery_block_invoke:1695] Unsupported: ID3D12GraphicsCommandListMTL::EndQuery - Type = 2
[metal-shaderconverter] Warning: Unsupported: culldistance
```

**Elden Ring has a 52 GB update pending, and it was not applied.** The bottle's
`appmanifest_1245620.acf` had `AutoUpdateBehavior 0` — "always keep this game
updated" — with `buildid 22984413` against `TargetBuildID 23850278`, 560 MB to
download and 52 GB to stage, and 38 MB of deltas already in
`steamapps/downloading`. Since the prefix's `steamapps` is a symlink into that
bottle, an online client would have started rewriting an install CrossOver also
uses. Before the client was allowed online, `AutoUpdateBehavior` was set to `1`
("only update this game when I launch it") and `steamapps/downloading`,
`steamapps/temp` and `steamapps/common/ELDEN RING` were made unwritable, which
was confirmed by trying to write to each one. The permissions have been put
back; **`AutoUpdateBehavior 1` has deliberately been left in place**, so
launching Elden Ring *through Steam* while online will still start that update.
The direct route above does not.

### What this rules out

* **The Windows version.** `10.0.22000` behaves exactly as `10.0.19045` did.
  Whatever `MachineIDInfoThread` is failing at, it does not consult
  `CurrentBuild` or `ProductName`.
* **Stale credentials.** The copied token was accepted as far as the server,
  which is further than a stale one gets; the loop happens before any token is
  read anyway.
* **Prefix history.** The old prefix had been made by CrossOver, alternated
  between two Wines, and carried a `cxbottle.conf`, a hand-copied `syswow64`
  and two dangling `d:` drives. None of that survives here, and the fault does.
* **The dangling `d:` mappings, again.** They were not recreated — both pointed
  at an ejected DMG — so this prefix's `\DosDevices` no longer has them, and
  the loop is unchanged. The earlier ruling-out stands, now from the other
  direction.
* **A hard deadlock.** One start in eight got through. The thread can finish.

## Where to look next (as of 2026-09-07)

*Kept as written; every item below was answered the next day, in the section
that follows.*

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


## The caller, read directly — and the bug it exposes

*Measured 2026-09-08 against the same client build 1788652215, in the same
prefix, under Wine 11.0 built from `crossover-sources-26.3.0` (sha256
`ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`) with
D3DMetal 4.0b2, on an M4 Mac running macOS 26.6.2 build 25G83 with Xcode 26.6
(Apple clang 21.0.0, `clang-2100.1.1.101`). The CrossOver control is CrossOver
26.3's own `lib/wine`. Four client starts were made, every one with
`loginusers.vdf` restored from the bottle first, and every one returned
`Schedule init returned 22`.*

Everything above this line was measured honestly and is wrong in one place:
the two "readings" in [Still unknown](#still-unknown) are both false, and the
thing they were trying to explain is not in Steam at all. The thread spins
inside Wine's own `GetLogicalDrives`, the loop's cursor *is* carried between
calls — and the callee ignores it, because a `BOOLEAN` argument that one
compiler wrote as a byte is read by another compiler as 32 bits.

### The frame above `GetLogicalDrives`, without the unwinder

`winedbg` will not unwind past `GetLogicalDrives+0x103`, but it does not have
to. protium's `kernelbase.dll` is unstripped, so `llvm-objdump
--disassemble-symbols=GetLogicalDrives` (Xcode's, nothing installed) gives the
frame layout exactly:

```
174072080  push r15; push r14; push rsi; push rdi; push rbx   ; 5 × 8 bytes
174072087  sub  rsp, 0x490
...
17407210b  mov  byte [rsp+0x20], 0        ; restart      = FALSE   <- one byte
174072110  lea  rdx, [rsp+0x90]           ; info
174072118  mov  r8d, 0x400                ; size         = 1024
17407211e  mov  r9b, 1                    ; single_entry = TRUE    <- one byte
174072121  call [NtQueryDirectoryObject]  ; first call, returns to +0xa7
...
17407216f  mov  byte [rsp+0x20], 0        ; the same store, in the loop
174072180  call r15                       ; returns to +0x103     <- the frame winedbg shows
```

So with `rsp` as `winedbg` reports it for the stopped thread (it points at the
`+0x103` return address), everything in the function is at a fixed offset:
`ctx` at `rsp+0x50`, `len` at `rsp+0x54`, the `restart` argument slot at
`rsp+0x28`, the entry buffer at `rsp+0x98`, and the function's own return
address at `rsp+0x4c0` (5 pushes plus `0x490`, plus the call). `winedbg` takes
several commands from a file — `--file Z:\path\to\cmds.txt` — so `thread <tid>`,
`info regs` and `x/168g $rsp` are one attach, not three. (`x/…g` prints
16-byte GUIDs, not qwords; `x/2d` prints two decimal dwords.)

Read that way, on the first start of the day (`MachineIDInfoThread` tid
`0x2b0`, `rsp = 0x0eb5dc18`):

| Slot | Value | Meaning |
| --- | --- | --- |
| `[rsp]` | `0x6fffff742183` | `kernelbase+0x72183` = `GetLogicalDrives+0x103`, as `bt` said |
| `[rsp+0x50]` | `1` | **`ctx` — the cursor has advanced to 1** |
| `[rsp+0x54]` | `238` | `len`: 32 + 32 + 146 + 2 + 24 + 2, the size of entry 0 |
| `[rsp+0x98]` | `Length 146, "HID#VID_845E&PID_0001#…"` | the buffer holds entry 0 |
| `[rsp+0x4c0]` | `0x6fffe5b547cf` | **`wbemprox+0x47cf` = `fill_diskpartition+0x3f`** |

The next return addresses up the stack are `wbemprox!execute_view+0x1af`,
`wbemprox!exec_query+0x61`, and then `steamclient64` (`+0xe735a7`, `+0xe74817`,
`+0xe74ba5`). `steamclient64.dll` carries the strings `SELECT * FROM
Win32_DiskDrive`, `SELECT * FROM Win32_DiskPartition`, `SELECT * FROM
Win32_PhysicalMedia`, `CMachineIDInfo::FillInMachineIDInfo()` and
`MachineIDInfoThread`. So the machine ID is computed from WMI, Wine's
`wbemprox.dll` answers the query, and its `fill_diskpartition` (`builtin.c`)
begins with `DWORD drives = GetLogicalDrives();`. That is the whole caller
chain, and Steam is at the far end of it doing something perfectly ordinary.

Twelve samples over about a minute, all with `ctx = 1`, all with the buffer
holding entry 0, all with the same `rsp`. A loop over sixty-odd entries sampled
at random does not land on the same entry twelve times.

### The trace, re-taken: the loop is inside `GetLogicalDrives`

The earlier trace was right about `index=0` and right about two threads, and
did not look at what came before. Nine seconds of `WINEDEBUG=+server` this time
(456 MB, 3,606,949 lines):

| Thread | Process | Name | `get_directory_entries` requests | `index` | reply |
| --- | --- | --- | --- | --- | --- |
| `02b0` | `0020` `steam.exe` | `MachineIDInfoThread` | 699,684 | `0` in all | `0`, `count=1`, entry 0, in all |
| `0180` | `0148` `steamwebhelper.exe` | `ThreadPoolForegroundWorker` | 713,937 | `0` in all | same |

and the shape of it, for `02b0`: one `open_directory( \DosDevices )` → handle
`039c`, then `get_directory_entries( handle=039c, index=0, max_count=1 )`
699,684 times, and **no `close_handle` and no second `open_directory`, ever**.
The other thread is the same, in Chromium. So this is not a caller re-running
`GetLogicalDrives`; it is one call that never returns — reading 2 in the old
list — except that reading 2 said the cursor was not carried, and the cursor is
sitting in `ctx` at `1`.

### Wine's source, kept this time, says what that means

`docs/wine-build.md` now keeps the tree (`$SCRATCH` is
`~/.local/share/protium/build`). `dlls/kernelbase/volume.c`:

```c
char data[1024];
ULONG ctx = 0, len;
while (!NtQueryDirectoryObject( handle, info, sizeof(data), 1, 0, &ctx, &len ))
    if (info->ObjectName.Length == 2*sizeof(WCHAR) && info->ObjectName.Buffer[1] == ':')
        bitmask |= 1 << (info->ObjectName.Buffer[0] - 'A');
```

and `dlls/ntdll/unix/sync.c`:

```c
NTSTATUS WINAPI NtQueryDirectoryObject( HANDLE handle, DIRECTORY_BASIC_INFORMATION *buffer,
                                        ULONG size, BOOLEAN single_entry, BOOLEAN restart,
                                        ULONG *context, ULONG *ret_size )
{
    ULONG index = restart ? 0 : *context;
    ...
    *context = index + used_count;
```

A 1 KB buffer holds the 146-byte HID name with room to spare, so the 40-byte
probe in *What the object directory actually holds* was measuring nothing that
happens here. With `restart = 0` and `ctx = 1`, the request must carry
`index=1`. Every request carries `index=0`. The only way to get `index=0` from
`ctx=1` is for `restart` to be **true** — and the caller wrote a zero.

It wrote one byte of zero. `mov byte [rsp+0x20], 0` sets the low byte of an
8-byte argument slot and leaves the other seven as they were, which the Windows
x86-64 ABI allows. From there:

1. **The syscall dispatcher passes the slot whole.** `dlls/ntdll/unix/signal_x86_64.c`,
   `__wine_syscall_dispatcher`: `movq (%r15),%r8   /* 5th argument */`. It
   cannot do otherwise — it has no idea which arguments are narrow.
2. **The unix side tests 32 bits of it.** `NtQueryDirectoryObject` in protium's
   `ntdll.so` begins `testl %r8d, %r8d` (at `0x4b812`). Clang, as a SysV
   callee, assumes the caller zero-extended a `char` to 32 bits, because clang
   as a SysV caller always does. GCC assumes nothing and would test the byte.
3. **The slot was dirty.** `[rsp+0x28]` read `0x000000000eb5de00` on the first
   start and `0x000000000f34de00` on the fourth: low byte `00`, the bytes above
   it a stale stack address left by whatever `MachineIDInfoThread` did before
   the query (registry and `SetupAPI` enumeration, per the trace). `%r8d` is
   therefore `0x0eb5de00`, which is true.

So every iteration asks for entry 0, is given entry 0 correctly, stores `ctx =
1` correctly, and asks for entry 0 again. `GetLogicalDrives` never returns,
`fill_diskpartition` never fills, the WMI query never answers,
`FillInMachineIDInfo()` never finishes, `jobmgr+0x1090` stays `10`, and
`EConnect` returns 22 for the life of the process. The wineserver burns a core
answering the same question 78,000 times a second per thread, which is the
51 % that was measured.

**This is why it is a race.** Nothing about it is timing; the die is the
contents of one stack slot at the moment `GetLogicalDrives` is entered. Seven
starts in eight it holds a stale pointer. One in eight it holds a zero, the
walk completes, and the client connects.

### Why CrossOver does not do this

Same source, same unix-side compiler, same 32-bit test — CrossOver's
`ntdll.so` has `testl %r8d, %r8d` at `0x4cd22`. The difference is one
instruction on the PE side:

| Build | `kernelbase.dll` compiled by | the `restart` store in `GetLogicalDrives` | `single_entry` |
| --- | --- | --- | --- |
| CrossOver 26.3 | `GCC: (GNU) 13.2.0` (string in the DLL) | `movl $0x0, 0x20(%rsp)` at `+0xbe` | `movl $0x1, %r9d` |
| protium | `clang version 23.1.0` (llvm-mingw; string in the DLL) | `movb $0x0, 0x20(%rsp)` at `+0x8b` and `+0xef` | `movb $0x1, %r9b` |

GCC writes 32 bits into the slot; the upper 32 are still stale but the callee
never looks at them. Clang writes 8. Both are legal Windows code. Only one of
them survives a clang-built unix side — and since Apple's clang is the only
compiler on a Mac, every build of Wine on macOS has a clang unix side. What
made protium special is that it is the first of these builds to use clang for
the *PE* side too: CrossOver, Homebrew and Apple's Game Porting Toolkit formula
all cross-compile the PE half with mingw-w64 GCC. This is a toolchain
combination nobody had run, and the bug is in Wine's contract between its two
halves, not in either compiler.

Upstream Wine has not changed the contract: `dlls/ntdll/unix/sync.c` on
`master` (read 2026-09-08 via the `wine-mirror/wine` copy on GitHub) declares
`NtQueryDirectoryObject` with the same two `BOOLEAN`s and no masking.

### Proof: one qword, zeroed in the running client

If the diagnosis is right, the fix at runtime is to make the slot clean. On the
fourth start (`MachineIDInfoThread` tid `0x2ac`, `rsp = 0x0f34dc18`, 9,233
`EConnect` lines already logged), from `winedbg`:

```
thread 0x2ac
x/2d 0x0f34dc40                  ->  255122944 0     (0x0f34de00: the dirty slot)
set *(long long*)0x0f34dc40 = 0
x/2d 0x0f34dc40                  ->  0 0
```

at 08:31:26. `connection_log.txt`, unedited apart from the account ID:

```
[08:31:27] CCMInterface::YieldingConnect -- calling ISteamDirectory/GetCMListForConnect/?cellid=91&qoslevel=3
[08:31:27] GetCMListForConnect -- got 16 Netfilter CMs and 105 WebSocket CMs
[08:31:29] [Connecting, 0, 11] [U:1:<account>] Connect() starting connection (eNetQOSLevelHigh, cmp1-fra1.steamserver.net:27023, WebSocket)
[08:31:29] [Connecting, 0, 11] [U:1:<account>] ConnectionCompleted() (155.133.250.4:27023, WebSocket)
```

and `steamui_login.txt`:

```
[08:31:28] [ WaitingForServerResponse ] Received logon failure response
[08:31:28] [ WaitingForServerResponse ] SetLoginState: WaitingForCredentials - Access Denied
```

One write of eight zero bytes took the client from the 22 loop to Valve's
front door in three seconds. The thread's frame was gone when re-read
(`[rsp]` now `0`), and the `Access Denied` is the copied-token refusal already
documented — the rewrite of `loginusers.vdf` that follows it happened here too,
which is why every trial restores the file first.

### What this rules out, this time

* **Everything in this document about Steam.** `EConnect`, the gate, the
  sentinel, `CThread::Start`, `MachineIDInfoThread` — all correctly measured,
  all downstream of a Wine bug. Steam is doing a WMI query.
* **The object directory, the HID device, the dangling drives, the Windows
  version, the credentials, the network.** Each was ruled out by experiment
  before; now there is a reason they were all innocent.
* **Both earlier readings.** The caller does not re-enumerate (one
  `open_directory`, no `close_handle`), and the cursor is carried (`ctx = 1`).
  The callee is told to ignore it.
* **The 40-byte-buffer story.** `GetLogicalDrives` uses 1024 bytes and never
  saw `STATUS_BUFFER_TOO_SMALL`; every reply was `0` with `count=1`.
* **The CEF half of "may be one bug".** The webhelper's
  `ThreadPoolForegroundWorker` is in the same loop, in the same function, for
  the same reason. Whether that is what the GPU-process failure in
  [`steam-rendering.md`](steam-rendering.md) was is not established, but a
  Chromium thread-pool worker pinned at 100 % from the first seconds of every
  run is now a known fact about the unpatched build.

### What it does not rule out: the rest of the class

`NtQueryDirectoryObject` is the one that was measured. The same shape — a
`BOOLEAN` in one of the six register-passed positions of a syscall — occurs in
25 other unix-side entry points in this tree, most of them an `alertable`:
`NtAcceptConnectPort`, `NtAdjustGroupsToken`, `NtAdjustPrivilegesToken`,
`NtCloseObjectAuditAlarm`, `NtCommitTransaction`, `NtContinue`,
`NtCreateMutant`, `NtDelayExecution`, `NtDuplicateToken`,
`NtInitiatePowerAction`, `NtOpenThreadToken`, `NtOpenThreadTokenEx`,
`NtQueryDefaultLocale`, `NtQueryEaFile`, `NtReleaseKeyedEvent`,
`NtRemoveIoCompletionEx`, `NtRollbackTransaction`, `NtSetDebugFilterState`,
`NtSetDefaultLocale`, `NtSetTimer`, `NtSetTimerResolution`,
`NtSignalAndWaitForSingleObject`, `NtWaitForDebugEvent`,
`NtWaitForKeyedEvent`, `NtWaitForMultipleObjects`, `NtWaitForSingleObject`.
Whether any of them bites depends on two things that vary per function: what
clang emitted for the test on the unix side (`single_entry` in the very same
function is compared as a byte, `cmpb $0x1, %r13b`, and so is safe by luck),
and whether the PE caller's register or slot happened to be dirty. None of
them has been measured. Arguments past the sixth are loaded from the stack with
`movzbl` — `NtQueryDirectoryFile`'s `single_entry` and `restart_scan` are
positions 9 and 11, and its unix side reads them with `movzbl 0x20(%rbp)` and
`movzbl 0x30(%rbp)` — so file enumeration is not exposed, which is why nothing
so basic ever broke.

A rough census of how often protium's PE side does this: `movb $imm,
0x20…0x58(%rsp)` — a byte store into an outgoing argument slot — appears 19
times in `kernelbase.dll`, 24 in `ntdll.dll`, 3 in `user32.dll`, once in
`kernel32.dll`. Not every one of those feeds a syscall, and not every syscall
tests 32 bits. It is a count of opportunities, not of bugs.

### The fix

The honest general fix is to build the PE side with GCC, as everyone else on
macOS does, and that is the direction `docs/wine-build.md` should take. What
this repository carries today is narrower and verified:
[`patches/0001-ntdll-test-only-the-byte-of-a-BOOLEAN-syscall-argument.patch`](../patches/0001-ntdll-test-only-the-byte-of-a-BOOLEAN-syscall-argument.patch)
puts both `BOOLEAN`s of `NtQueryDirectoryObject` through an empty `asm` with
an in/out constraint, which makes clang treat them as fresh 8-bit values:

```c
__asm__( "" : "+r" (single_entry), "+r" (restart) );
index = restart ? 0 : *context;
```

Checked before building anything, with the same Apple clang at `-O2`: the
function as written compiles to `testl %r8d, %r8d`; with the barrier it
compiles to `testb %r8b, %r8b`. The recipe applies the patch before
`configure`, and the result is installed beside the old runtime as
`wine-11.0-cx26.3-p1` rather than over it, so the two can be A/B'd from the
same prefix with `--runtime`.

### Verified: the patched runtime clears the gate every time

Built 2026-09-08 from the kept tree with llvm-mingw 20260826 (clang 23.1.0)
for the PE side and Apple clang 21.0.0 for the unix side, `make` exit 0,
installed as `wine-11.0-cx26.3-p1` with the same D3DMetal 4.0b2 merged in
(`protium redist` on the result reports it) and `wine.inf` byte-identical to
the first runtime's. In the installed `ntdll.so`, `NtQueryDirectoryObject`
now begins `testb %r8b, %r8b`; `kernelbase.dll` still has its four byte
stores, as it should — the PE side was not the thing to change. `protium run
--runtime wine-11.0-cx26.3-p1 cmd /c ver` answers `10.0.22000` and leaves
`.update-timestamp` alone.

Then the same trial as every other start in this document — `loginusers.vdf`
restored from the bottle, `steam.exe -noreactlogin -noverifyfiles
-norepairfiles`, online — three times on the patched runtime, against the
three starts on the unpatched one the same morning:

| Runtime | Starts | `Schedule init returned` | `EConnect … 50ms` lines | Thread above 20 % CPU |
| --- | --- | --- | --- | --- |
| `wine-11.0-cx26.3` | 3 (08:10, 08:20, 08:30) | `22`, `22`, `22` | 127+, 8,000+, 9,233 | `MachineIDInfoThread`, every time |
| `wine-11.0-cx26.3-p1` | 3 (08:54:18, 08:54:50, 08:55:15) | **`1`, `1`, `1`** | **0, 0, 0** | none |

Each of the three reached `LogOn()` within 9–18 seconds of launch,
`CCMInterface::YieldingConnect` and `GetCMListForConnect` in the same second,
and `Connect() starting connection (… WebSocket)` right after. On the third,
the first WebSocket attempt came back `ConnectFailed('Connection Failed':0)`
and the client scheduled `StartAutoReconnect() … in 12.0 seconds`, which the
trial's twelve-second window did not cover; that is the network being the
network, on the far side of the gate this document is about. Nothing on the
patched runtime ever printed `Schedule init returned 22`, and no thread was
hot.

What the patched runtime still cannot do is sign this prefix in: the copied
token is refused, as [(b)](#b-does-it-reach-logged-on-no--and-the-reason-is-not-wine)
records, so `Logged On` needs a password and Steam Guard typed into the
client. The login page renders, the gate is open, and that is the one step
left.

## The second blocker: no TLS, so every WebSocket CM connection fails

*Measured 2026-09-08, after the patched runtime opened the gate, when an
interactive sign-in was attempted and could not be completed. Same host, same
client build 1788652215, runtime `wine-11.0-cx26.3-p1`.*

Opening the gate is necessary and not sufficient. With `Schedule init returned
1` on every start, the client reaches `YieldingConnect`, asks the Steam
directory for connection managers, and then fails to reach almost all of them.
Between 09:08 and 09:16, across four client starts:

| Transport | `Connect() starting connection` | `ConnectionCompleted()` | `ConnectFailed` |
| --- | --- | --- | --- |
| WebSocket | 18 | 0 | 18 |
| UDP | 2 | 2 | 0 |

Every WebSocket attempt fails in under a second, with no address:

```
[Connecting, 0, 7] Connect() starting connection (eNetQOSLevelHigh, cmp2-fra1.steamserver.net:27019, WebSocket)
[Connecting, 0, 0] ConnectFailed('Connection Failed':0) (0.0.0.0:0, WebSocket)
```

The client picks the transport by rolling against a ratio the directory gives
it — `CM Directory list says 85% of connections should be websockets, we
rolled 19 - using WebSockets as default` — so roughly five attempts in six were
doomed, and the two that were not connected immediately over UDP. That is why
this looked intermittent rather than total.

It gets worse on the **go online** path. Pressing it drops the request to QoS
level 2, and at that level the directory answers `100% of connections should be
websockets`. So **go online** could never succeed, whatever the gate did.

### The cause: `libgnutls` is built but not loadable

`WINEDEBUG=+secur32,+winediag` on a client start says it in four lines:

```
err:winediag:process_attach Failed to load libgnutls, secure connections will not be available.
err:winediag:process_attach failed to load libgnutls, no support for pfx import/export
err:winediag:gnutls_process_attach failed to load libgnutls, no support for encryption
err:secur32:SECUR32_initSchannelSP no schannel support, expect problems
```

A Steam WebSocket CM is `wss://…:443`, which is TLS, which is schannel, which
is GnuTLS. Without it the client has no encrypted transport at all and only
plain UDP works.

The library was not missing from the build. `include/config.h` from the
2026-09-08 build has `#define SONAME_LIBGNUTLS "libgnutls.30.dylib"`, and
`~/.local/share/protium/deps/lib/libgnutls.30.dylib` is an x86-64 dylib built
by the recipe. **Compiled in is not the same as loadable.** Wine `dlopen`s it
by that bare soname at runtime, exactly as it does FreeType, and the only
directory on `DYLD_FALLBACK_LIBRARY_PATH` is the runtime's own `lib/`, which
held `libfreetype.6.dylib` and nothing else. Both runtimes were built this way,
so this is not a consequence of the patch — the original runtime had no TLS
either, and everything in this document above was measured on a client that
could not open an encrypted socket.

An earlier version of [`wine-build.md`](wine-build.md) claimed the opposite,
that a build from this recipe has schannel because `config.h` records the
soname. That claim was wrong and is corrected there. It also credited the
client's HTTPS fetch of its update manifest to this library; that fetch
happened while `secur32` was reporting no schannel support, so whatever served
it, it was not GnuTLS.

### The fix, and what it changed

The same treatment FreeType already gets — put the dylib where the loader
looks:

```sh
cp ~/.local/share/protium/deps/lib/lib{gnutls.30,nettle.8,hogweed.6,gmp.10}.dylib <runtime>/lib/
install_name_tool -id  @loader_path/libgnutls.30.dylib <runtime>/lib/libgnutls.30.dylib
install_name_tool -change <deps>/lib/libnettle.8.dylib @loader_path/libnettle.8.dylib <runtime>/lib/libgnutls.30.dylib   # and hogweed, gmp
```

GnuTLS needs nettle, hogweed and GMP, and the recipe's copies name each other
by absolute path into `deps/`, so the three are copied alongside and the
references rewritten to `@loader_path`. The runtime tree is then self-contained
and does not depend on `deps/` surviving.

The next client start, on the same prefix, with `WINEDEBUG=+winediag`:

* **Zero** `Failed to load libgnutls` lines, where every previous start had them.
* The first connection attempt of the run was a WebSocket, to port 443, and it
  completed: `ConnectionCompleted() (155.133.252.68:443, WebSocket) local
  address (192.168.178.26:…)`. Eighteen consecutive WebSocket attempts had
  failed before this.
* `SetLoginState: WaitingForCredentials`, the sign-in window open, and no
  `Failed to start auth session` — the error that appeared on every earlier
  attempt, because the page had no connection to start a session on.

### Two smaller things seen on the way

**A logon that fails leaves the client in offline mode, not at the login page.**
`Received logon failure response` → `Start offline - 1` → `SetLoginState:
Success`. Pressing **go online** from there re-enters `LogOn()` at QoS 2, which
is the WebSocket-only path above, so it fails every time. Reaching the login
form from that state means restarting the client, not pressing a button in it.

**"Sign out and restart" does not restart.** `UI Request: sign out and restart`
is the last line the client writes; `Log session ended` follows and the process
exits without coming back. It also clears the account entry from
`config/loginusers.vdf`. Not diagnosed further — the client is simply started
again by hand — but worth knowing before pressing it, because it looks like a
crash.

## Signing in online is enough to start a game update, on its own

*Measured 2026-09-08, the first time this prefix reached `Logged On`. Recorded
because the assumption that governed every online experiment in this document
turned out to be false, and it cost 21 GB of disk before it was caught.*

The rule this repository has been working to was: `AutoUpdateBehavior 1` means
"only update this game when I launch it", so a client that is online but never
used to launch the game will not start the 52 GB Elden Ring update. **That is
wrong.** The game was never launched, through Steam or otherwise, and the
update started anyway, 34 seconds after logon:

```
[09:23:14] [Logged On, 4, 7] [U:1:<account>] RecvMsgClientLogOnResponse() : processing complete
[09:23:48] AppID 1245620 scheduler update : Priority First, not played for 218188 seconds, update disabled for 0 seconds
[09:23:48] AppID 1245620 state changed : Update Required,Fully Installed,Update Queued,Files Missing,
[09:23:48] AppID 1245620 state changed : Update Required,Fully Installed,Update Queued,Files Missing,Update Running,
[09:23:49] Created download interface of type 'CDN' (2) to host alibaba.cdn.steampipe.steamcontent.com
```

`logs/content_log.txt`, and the client's own words for why: its update
**scheduler** picked the app up as `Priority First, not played for 218188
seconds`. `AutoUpdateBehavior` was `1` in `appmanifest_1245620.acf` before the
client was started and still `1` afterwards — it was never touched, and it did
not prevent this. `console_log.txt` has no launch of AppID 1245620 at all.

What it cost, in three minutes before it was noticed and the client killed:

| | Before | After |
| --- | --- | --- |
| `steamapps/downloading` | 38 MB | 37 GB |
| Free space on the data volume | 38 GB | 17 GB |
| `StateFlags` in the manifest | `38` | `1062` |
| `TargetBuildID` | `23850278` (2026-09-07) | `25080141` |

Two things limited the damage, and both are worth knowing:

* **Nothing in the installed game was touched.** `find steamapps/common/ELDEN
  RING -type f -mmin -10` returned zero files while the update was running, and
  again after the client was killed. Steam stages a delta build entirely in
  `steamapps/downloading` and only commits at the end, so killing the client
  mid-update leaves the playable install exactly as it was. No verify, no
  repair, no re-download of what is already there.
* **`BytesDownloaded` stayed at `0`** against `BytesToDownload 560261824`. Most
  of the 37 GB is the new build being assembled locally out of the old one, not
  bytes off the network — which is also why it grew that fast.

### What actually protects the install

Not `AutoUpdateBehavior`. The measures that work are the ones the 2026-09-07
session used and then reverted:

* Make `steamapps/downloading`, `steamapps/temp` and `steamapps/common/<game>`
  unwritable before the client goes online. Steam then cannot stage anything;
  it reports an error against the app and does no damage.
* Or do not give the prefix a `steamapps` that points at an install worth
  protecting. This prefix's is a symlink into the CrossOver bottle, which is
  the whole reason an update here rewrites something CrossOver also uses.

`Update Queued` survives a kill: the manifest still says `StateFlags 1062`, so
the next online, signed-in client resumes this update within a minute unless
one of the two measures above is in place first.
