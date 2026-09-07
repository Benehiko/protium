# `protium install` — fetching software, and what is actually known about it

`protium install` downloads a program's own installer from its publisher and
runs it inside a prefix. It does not host anything, mirror anything, or patch
anything: it fetches the file you would have fetched yourself, prints what
arrived, and runs it.

```sh
protium install list        # everything protium knows about
protium install steam       # fetch Valve's installer and run it
```

## The catalogue, and the three words beside each row

```
$ protium install list

  steam          verified   Valve's Steam client
  epic           untested   Epic Games Launcher
  battlenet      untested   Blizzard Battle.net
```

The label is the point of the table. This project exists because the
alternative to it is a pile of forum posts that assert things, so an entry says
which of three states it is in, and `protium install <name>` prints the
evidence before it fetches anything:

| | |
| --- | --- |
| `verified` | fetched, installed and started under a Wine built from `docs/wine-build.md`, on a date the entry records |
| `untested` | the download is the publisher's own and resolves, and **nothing more than that** |
| `blocked` | someone tried it and something specific stops it, named in the entry |

`untested` and `blocked` are deliberately different rows. "Nobody has looked"
and "someone looked and here is what happens" are not the same claim, and a
catalogue that collapses them is the thing this repository is a reaction to.

Entries are added to `src/catalog.zig`, and the test suite enforces the parts
that can be enforced: every URL is HTTPS, every install path is on `C:`, every
launch flag and every required setting carries a written reason, and every
entry carries evidence.

## What `install` does, in order

1. **Resolves the runtime and the prefix**, exactly as `protium run` does.
2. **Prints what is known** about the entry — the label above, and the
   evidence behind it — before anything is downloaded.
3. **Stops if the program is already there.** The check is the program's own
   path inside the prefix, not a marker protium wrote, so a prefix populated
   by something else is recognised. `--force` reinstalls over it.
4. **Adds the settings the program needs** to the prefix's `protium.conf`,
   with the reason written above each one as a comment. A setting already
   present with a *different* value is reported and left alone — the file is
   yours, and a prefix deliberately configured is not protium's to correct.
5. **Downloads** to `<root>/downloads/`, over TLS, verified against the
   system's root certificates. The body goes to a `.part` file and is renamed
   only once it is complete, so an interrupted fetch cannot leave a truncated
   installer that the next run would happily execute. A file already there is
   reused; `--refresh` fetches again.
6. **Prints the length and the SHA-256** of what arrived (see below).
7. **Checks the installer can actually run here** — see
   [32-bit installers](#a-32-bit-installer-cannot-run-in-a-prefix-protium-made).
8. **Runs it**, from `C:\windows\temp`, with the publisher's own silent switch
   where it has one.
9. **Checks the program is where the entry says it lands**, and says so if it
   is not. An installer can exit 0 having done nothing — a silent switch it
   did not understand does exactly that — so the exit status is not taken as
   proof.
10. **Applies the program's fix**, if it has one — see below.
11. **Prints how to launch it**, including every argument it needs *here* and
    the reason for each one.

## Reclaiming the downloads

Step 5 leaves the installers in `<root>/downloads`, and they are kept on
purpose: the same `SteamSetup.exe` serves every prefix, and a reused download
is the difference between configuring a second prefix in seconds and fetching
the file again.

When that space is wanted back:

```
$ protium install clean
$ protium install clean --force     # in a script: skip the question
```

The whole directory goes. Nothing in it is protium's — each file is the
publisher's own, fetched at the moment it was asked for — and nothing in it
cannot be fetched again, which is what makes deleting it safe to offer as a
command. The next `protium install` recreates the directory and downloads what
it needs. It prints the size and asks first, the same way
[`protium prefix remove`](prefixes.md#removing-a-prefix) does, and it uses the
same walk: a symlink inside it is unlinked, never followed.

## Fixes: when protium replaces one of a program's files

Some software will not work here without a file of its own being replaced.
Steam is the case that exists today: its window paints black because Chromium
composites in a separate GPU process, and the only way to pass the switch that
moves the compositor in-process is to stand in front of the executable.

**This is a workaround and should not outlive its cause.** The fault is in
Wine, not in Steam, and fixing it in Wine would remove this whole mechanism and
fix every CEF application at once. [`steam-rendering.md`](steam-rendering.md)
says why the current shape is wrong and what the real fix looks like.

This is the most invasive thing `install` does, so it is bounded:

* **It says what it is about to do, and why, before it does it.** The whole
  reason is printed, not a one-line summary.
* **Nothing is deleted.** The program's own file is copied beside itself —
  Steam's `steamwebhelper.exe` becomes `steamwebhelper-real.exe` — and the
  stand-in launches it.
* **`protium install <name> --undo` puts it back**, byte for byte, and removes
  the copy.
* **It is idempotent and self-repairing.** Running `install` on software that
  is already installed does not reinstall it; it checks the fix and puts it
  back if it is gone. Steam replaces the file whenever it updates itself, so
  "the window went black again" is answered by re-running the same command.
* **It never overwrites the backup with a stand-in.** A stand-in from an older
  protium is recognised and replaced in place, because overwriting the backup
  would destroy the only copy of the program's own binary.

The stand-in is not a binary checked into this repository. It is
[`src/webhelper.zig`](../src/webhelper.zig), about eighty lines, cross-compiled
to `x86_64-windows` by `build.zig` and embedded in the protium binary — Zig
cross-compiles to Windows with nothing extra installed, so the same `zig build`
produces both. protium stays one file, and the PE it writes is one you can read
the source of.

A program with a fix still has to earn `verified` on its own evidence. The fix
is described in the entry; it is not a substitute for having run the thing.

### Why there is no pinned checksum

The obvious thing to want is a hash in the catalogue that the download is
checked against. It would be wrong here. `SteamSetup.exe` is replaced by Valve
whenever they like, at the same URL; a pinned digest would fail every few
months, for a completely legitimate file, and the only thing it would teach
anyone is to reach for the override. A checksum that is routinely bypassed is
worse than none.

What can be done honestly is to record what arrived:

```
  2.3 MB (2380800 bytes)
  sha256 7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb
```

That is the same standard the rest of `docs/` is held to: not a promise about
the future, but a fact about what happened, with enough detail to quote. The
exact byte count is printed alongside the human-readable size for one reason —
a 2 MB installer that arrives as a 4 KB error page still reads as `4.0 KB`,
and it does not read as `4096 bytes` next to an expected two million.

## A 32-bit installer cannot run in a prefix protium made

*Measured 2026-09-06, against Wine 11.0 built from `crossover-sources-26.3.0`,
on an M4 Mac running macOS 26.6.1.*

This is a fault in **prefix creation**, not in Steam. Steam itself is
`verified` — it installs, signs in, renders and launches games — but only in a
prefix that already has a 32-bit side, because Valve's installer needs one.

`SteamSetup.exe` is a 32-bit PE — machine `0x014c` in its COFF header, which
`protium install` now reads before spawning anything. Running it in a prefix
made by `protium prefix new` gives:

```
wine: could not load kernel32.dll, status c0000135
```

and an exit status of 53. The cause is one empty directory:

| Prefix | `drive_c/windows/system32` | `drive_c/windows/syswow64` |
| --- | --- | --- |
| made by `protium prefix new` | 838 entries | **0 entries** |
| made by CrossOver 26.3 | 840 entries | 866 entries |

Wine loads 32-bit modules out of the runtime's own
`lib/wine/i386-windows`, but only after `LoadLibrary` finds the *fake* DLL of
that name inside the prefix. With `syswow64` empty there is no
`kernel32.dll` to find, so nothing 32-bit can start at all — not the
installer, and not `syswow64\cmd.exe` either.

**The Wine is not the problem.** Its `lib/wine/i386-windows` tree is complete —
1065 modules, `kernel32.dll` and `ntdll.dll` among them — and the WoW64 thunks
(`wow64.dll`, `wow64cpu.dll`, `wow64win.dll`) are all present in
`lib/wine/x86_64-windows`. 32-bit code runs perfectly well once the directory
is populated:

```
$ protium run "C:\windows\syswow64\cmd.exe" /c ver
Microsoft Windows 10.0.19045
```

That was in a prefix whose `syswow64` had been filled by copying it from a
prefix that had one. With it filled, `protium install steam` then ran start to
finish: fetched, installed silently, and left a working `Steam.exe`.

`wineboot -u` is what should fill it, and on this build it does not. It stops
partway with

```
err:setupapi:SetupDefaultQueueCallbackW copy error 1812 ... wineusb.inf
wine: could not load kernel32.dll, status c0000135
```

Running `wineboot -u` a second time does not fix it, and neither does removing
`wineusb.inf` — the copy error is reported either way and `syswow64` stays
empty. What in `wineboot` gives up before the WoW64 stage is not yet known;
this file records the measurement, not the explanation.

**Until it is understood**, 64-bit installers work normally, and a 32-bit one
needs a prefix whose 32-bit side came from somewhere else. `protium install`
detects the situation and says so rather than letting the installer fail with
a status code.

## Adding an entry

Entries live in `src/catalog.zig`. Two rules, both enforced by tests:

* **The URL is the publisher's own, over HTTPS.** protium redistributes
  nothing. `install` re-checks this at run time as well, because a catalogue is
  data and data gets edited without running the tests.
* **The claim carries its evidence.** Set `confidence` to what you actually
  did, and write in `evidence` what you saw and when. An entry nobody has run
  is welcome — finding the right URL is most of the work — as long as it says
  so.

Every launch argument and every required setting is stored with the reason it
is there, and the reason is printed:

```
  -noreactlogin
      offline mode is chosen on the CEF login page, and that page often
      never renders here; the legacy login path does not depend on it
```

A flag whose reason nobody wrote down is a flag nobody can ever remove, which
is how a project ends up carrying workarounds for problems that were fixed
years earlier.

## What is not in the catalogue, and why

* **GOG Galaxy.** Its documented download link answers `404` (checked
  2026-09-06). There is no stable publisher URL to point at.
* **itch.io.** Its download endpoint answers `403` to anything that is not a
  browser. Fetching it would mean pretending to be one.
* **The Visual C++ redistributables.** Wine already ships the whole of the
  2015-2022 runtime as builtin modules — `vcruntime140.dll`,
  `vcruntime140_1.dll`, `msvcp140.dll`, `concrt140.dll` and the rest are in
  `lib/wine/x86_64-windows` and appear in every prefix's `system32`. An entry
  for them could never be honestly marked `verified`, because there is no
  way to observe it having helped.
