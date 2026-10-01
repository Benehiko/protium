# Where `protium run` starts a program

**A program protium finds for you starts in the directory that holds it.** A
path you type keeps your shell's directory.

| You type | protium starts | Working directory |
| --- | --- | --- |
| `protium run "elden ring"`, `protium run 1245620` | the Steam game's program | the program's own directory |
| `protium run eldenring.exe` | the `.exe` found by name in the prefix or a Steam library | the program's own directory |
| `protium run steam` | the catalogue app | the program's own directory |
| `protium run ~/Games/Setup.exe`, `protium run 'C:\…\x.exe'` | that path, as typed | your shell's directory |
| `protium run notepad`, `cmd.exe` | Wine's own program, as typed | your shell's directory |

The code is `catalog.programDir` and the `resolved` field of `Target` in
`src/main.zig`.

## Why

Windows programs are started in their own directory by the things that
normally start them. Steam starts a game in its install directory, and
Explorer starts a program in the directory it was opened from. So a program
can find its own files by relative path and never notice that this is an
assumption. Started anywhere else, those relative paths point at nothing.

Before this, `protium run` started every program in the directory the shell
happened to be in, which under Wine is something like `Z:\Users\you`. A path
you type keeps that behaviour on purpose. Someone at a shell expects
`protium run ./tool.exe input.txt` to find `input.txt` where they are, and the
rest of the command line may depend on it.

## The case that found it: Elden Ring 2.7.1.0

*Measured 2026-10-01, on `wine-11.0-cx26.3-p2` (unchanged since its 2026-09-08
build), against a complete install of Elden Ring build `25080141`, which the
game reports as 2.7.1.0.*

Started by `protium run eldenring.exe`, the game took its own fatal path a few
seconds in:

```
wine: Unhandled page fault on write access to 0000000000000000 at address 0000000141EBB809
0x00000141ebb809 eldenring+0x1ebb809: movl $0xdeadba, 0
```

Writing a sentinel to address zero is the game deciding to die, not a fault in
Wine. The same game, prefix, runtime, save and Steam session ran normally when
started by another launcher. That launcher did two things differently, and
both were plausible:

* it called the game's own `steam_api64.dll` → `SteamAPI_Init` in a parent
  process before the game existed; and
* it started the game with its working directory set to the game's `Game\`
  directory.

A scratch probe that does each of these separately, with nothing injected and
nothing else changed, settled it. Each run went through `protium run
--prefix eldenring` with `SteamAppId=1245620` and Steam signed in:

| Run | `SteamAPI_Init` in a parent first | Working directory | Result |
| --- | --- | --- | --- |
| 1 | no | the game's `Game\` | **runs**: D3DMetal renders, TLS and WMI calls follow |
| 2 | yes | inherited from the shell | `movl $0xdeadba, 0` at start-up, as before |
| 3 | yes | the game's `Game\` | **runs** |

The working directory is the whole of it, and initialising Steam first does
not matter. This contradicts the reason the other launcher's source gives for
its ordering (that the game's restart check needs Steam initialised before
`main`), so that reason should not be repeated here without new evidence.

**Things that were suspected first and ruled out**, in case the same symptom
comes back:

* **Missing archives.** On 2026-09-08 the same abort, at `+0x1eb9999`, was
  caused by `Data0.bdt` and `Data1.bdt` being deleted by an interrupted update
  ([`steam-login.md`](steam-login.md#the-cause-two-archives-are-missing)). This
  time the manifest said `StateFlags 4`, every archive was present, and
  `downloading` was empty.
* **The runtime.** Nothing in it had changed since 2026-09-08.
* **The save.** Steam Cloud had replaced `ER0000.sl2` with a copy from another
  machine. All twelve of its slot checksums verify.
* **The Steam overlay.** It was already off for the game
  (`"EnableGameOverlay" "0"`).

### What the fix was checked against

A scratch program that prints `GetCurrentDirectory`, put at
`C:\Games\CwdTest\cwdtest.exe` in a scratch prefix, and run from `/tmp`:

| Build | `protium run cwdtest.exe` | `protium run /…/CwdTest/cwdtest.exe` (typed) |
| --- | --- | --- |
| `main` before the change | `Z:\tmp` | — |
| with the change | `C:\Games\CwdTest` | `Z:\tmp` |

Elden Ring itself, started by the fixed `protium run eldenring.exe` from `~`,
was resolved to `…/ELDEN RING/Game/eldenring.exe`, given `SteamAppId=1245620`,
and ran: D3DMetal rendered, and the game's TLS and WMI calls followed. It ended
only when quit from its menu, in the heap fault described below, not in the
start-up abort.

## Not covered by this

Quitting Elden Ring from its own menu still ends in an access violation, under
every launcher, with nothing but the game and Wine loaded:

```
wine: Unhandled page fault on read access to 000003E80000EA5E at address 00006FFFFFD486B0
```

That is the game freeing `0x3e80000ea60`, which looks like two small integers
(1000 and 60000) rather than a pointer. Wine's `RtlFreeHeap` passes it to
`unsafe_block_from_ptr` (`dlls/ntdll/heap.c`), which reads the block header at
`ptr - 8` with no guard unless the heap was created with `HEAP_VALIDATE`. The
pointer is 16-aligned, so it passes the only check made before that read, and
the read faults. A launcher sees the exit code `0xC0000005`, and `protium run`
reports `5`, its low byte. It happens after the game has stopped, and at the
title screen nothing is being saved. The investigation, what it ruled out and
what is still open, is in [Elden Ring crashes when it quits](quit-crash.md).
