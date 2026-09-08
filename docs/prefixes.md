# Prefixes, and the shell context that finds them

A *prefix* is a Windows installation: its own `C:` drive, its own registry, its
own installed programs. Wine finds one through the `WINEPREFIX` environment
variable, and a Wine launched without it silently uses `~/.wine`.

protium's answer is to put that variable — and the five others a launch needs —
into your shell, once, so that everything started from that shell agrees about
where it is running. That is what "the prefix is a context" means here: you do
not pass it to anything, and nothing has to be taught about it.

## The layout

Everything protium manages lives under one directory:

```
<root>/runtimes/<name>/     a Wine install: bin/wine, lib/wine/...
<root>/prefixes/<name>/     a WINEPREFIX, with its protium.conf inside it
<root>/defaults             which runtime and which prefix to use
```

`<root>` is the first of these that is set:

| | |
| --- | --- |
| `$PROTIUM_HOME` | an explicit choice — an external disk, say |
| `$XDG_DATA_HOME/protium` | if that variable is set |
| `$HOME/.local/share/protium` | otherwise |

**Not `~/Library/Application Support`.** Wine's install rules do not quote
paths, so `make install` into a directory whose name contains a space fails
part-way through, after copying several hundred files. `protium prefix new`
refuses to run under a root containing a space for the same reason. See
[`wine-build.md`](wine-build.md).

## Which prefix, and which Wine

Both are resolved the same way, and the first answer wins:

1. `--prefix <name>` / `--runtime <name>` on the command line;
2. `$PROTIUM_PREFIX` / `$PROTIUM_RUNTIME` in the environment;
3. the `prefix=` / `runtime=` line in `<root>/defaults`, written by
   `protium use`;
4. the only one installed, if there is exactly one.

Rule 4 is what makes the ordinary case need no configuration at all: one Wine
and one prefix are found without being named. When there is more than one and
nothing has chosen between them, protium says so and stops rather than picking.
Guessing would be a silent decision about which graphics stack a game runs
against, and the two would not look different until something rendered wrongly.

```
$ protium use skyrim              # make a prefix the default
$ protium use --runtime wine-11.0-cx26.3
$ protium prefix list             # `*` marks the default
```

## The shell hook

protium cannot set a variable in the shell that ran it — no process can. So
`protium env` prints the environment as shell code, and the shell evaluates it:

| Shell | Line to add | Where |
| --- | --- | --- |
| fish | `protium env --shell fish \| source` | `~/.config/fish/config.fish` |
| zsh | `eval "$(protium env --shell zsh)"` | `~/.zshrc` |
| bash | `eval "$(protium env --shell bash)"` | `~/.bash_profile` |

`protium shell-init` prints the right one for your shell. Running that same
line by hand applies it to the terminal you are already in.

Two properties make this safe to add before the rest of the install is
finished, and safe to leave there permanently:

* **It succeeds when there is nothing to set.** With no runtime or no prefix,
  `protium env` prints a `#` comment and exits 0. A half-finished install does
  not put an error in front of you on every new terminal.
* **It is idempotent.** `PATH` and `DYLD_FALLBACK_LIBRARY_PATH` are rebuilt
  with protium's own entry removed before it is prepended, so evaluating the
  hook twice — a shell inside a shell — leaves them the same length.

Changing the default with `protium use` affects new terminals. To move the one
you are in, run the hook line again.

## What protium sets, and why

| Variable | Why it is needed |
| --- | --- |
| `WINEPREFIX` | the prefix itself; without it Wine uses `~/.wine` |
| `WINELOADER` | absolute path to `bin/wine`. Wine re-execs its loader by this name, including when handing a 32-bit process to the 32-bit loader |
| `WINESERVER` | so `wineserver -k` reaches *this* runtime's server |
| `DYLD_FALLBACK_LIBRARY_PATH` | the runtime's `lib`, so FreeType is found — see below |
| `PATH` | the runtime's `bin` first, so plain `wine` is this Wine |
| `PROTIUM_RUNTIME`, `PROTIUM_PREFIX` | the chosen names, so `protium status` can report what a shell is actually pointed at |

### Why `DYLD_FALLBACK_LIBRARY_PATH`, and nothing more in it

Wine records FreeType by its bare soname, `libfreetype.6.dylib`, and `dlopen`s
it at run time. Without the runtime's own `lib` on dyld's fallback search path,
every launch comes up with no font rasteriser and any Win32 window — a game's
launcher, an installer — renders blank.

protium puts the runtime's `lib` on that list and adds nothing else. The
temptation is to also append `/usr/local/lib:/usr/lib` on the theory that
setting the variable replaces a default. It does not, on any Mac new enough to
run this:

```
$ man dyld
DYLD_FALLBACK_LIBRARY_PATH
       This is a colon separated list of directories that contain
       libraries.  If a dylib is not found at its install path, dyld
       uses this as a list of directories to search for the dylib.

       For new binaries (Fall 2023 or later) there is no default.  For
       older binaries, there is a default fallback search path of:
       /usr/local/lib:/usr/lib.
```

There is nothing to preserve, and adding those directories would create a
search path macOS would not otherwise have used — inside an x86-64 process,
where `/usr/local/lib` is where an Intel Homebrew puts its dylibs.

### System Integrity Protection strips `DYLD_*`, but not for your Wine

Every `DYLD_*` variable is removed from the environment of a process whose
binary is protected — Apple's own signed platform binaries, `/bin/sh` among
them. This is worth knowing before it costs an hour, because it means a shell
one-liner cannot be used to test whether the variable is being passed:

```
$ DYLD_FALLBACK_LIBRARY_PATH=/tmp/marker /bin/sh -c 'echo "[$DYLD_FALLBACK_LIBRARY_PATH]"'
[]
$ DYLD_FALLBACK_LIBRARY_PATH=/tmp/marker ./an-unsigned-binary-built-here
[/tmp/marker]
```

A Wine you built is the second case, so it receives the variable normally. A
`protium run` whose child is a system binary is the first case, and the
variable will appear to have vanished.

## Per-prefix settings: `protium.conf`

Each prefix holds its own `protium.conf`, and every line in it is added to the
environment of anything launched in that prefix. `protium prefix new` writes a
commented starter file.

```
# <root>/prefixes/skyrim/protium.conf
D3DM_MAX_FPS=60
WINEDLLOVERRIDES="d3d12=n"
```

* `KEY=VALUE`, one per line. `#` starts a comment; blank lines are ignored.
* One matching pair of surrounding quotes is stripped, so
  `WINEDLLOVERRIDES="d3d12=n"` means what it looks like it means.
* The file is **read by protium, never sourced by a shell**. There is nothing
  in it that can run, and `export FOO=1` is a syntax error rather than a
  setting — the `export` makes it an invalid variable name.
* A line protium cannot use is reported with its line number, not skipped. A
  setting silently ignored is a game launched with the wrong frame cap and no
  way to find out.
* The variables protium manages — the six in the table above — cannot be set
  here. The file travels inside the prefix, and one that redefined
  `WINEPREFIX` would send a copied prefix's applications somewhere else.

The settings D3DMetal itself reads are listed in
[`d3dmetal.md`](d3dmetal.md). Because the file lives inside the prefix,
copying or moving a prefix carries its settings with it.

## A prefix protium made has no 32-bit side

`protium prefix new` runs Wine's own `wineboot`, and on this build that stops
before it fills `drive_c/windows/syswow64`. The directory is created and left
empty, so no 32-bit Windows program starts in the prefix — the loader reports
`could not load kernel32.dll, status c0000135`.

This is not a limitation of the Wine, whose 32-bit module tree is complete: it
is a step of prefix creation that does not finish. 64-bit programs, which is
most modern games, are unaffected. The measurements, and the one 32-bit
installer it currently blocks, are in
[`install.md`](install.md#a-32-bit-installer-cannot-run-in-a-prefix-protium-made).

## Launching without the shell hook

`protium run` applies the same environment to one command and nothing else:

```
$ protium run ~/Games/Setup.exe
$ protium run --prefix skyrim winecfg
```

It reports the program's own exit status as its own, so it can be used inside
a script. This is also the way to run something in a prefix that is not the
default without disturbing the shell you are in.


## Stopping a prefix

A prefix that is running holds a Wine session open: one `wineserver`, and
every process it is serving. Closing the program's window does not always
close the session, and a wedged session can outlive everything that started
it.

```
$ protium prefix stop
$ protium prefix stop eldenring
$ protium prefix stop eldenring --force
```

Without `--force` this asks politely first, by running the prefix's own
`wineserver -k`, and gives it five seconds. That is the normal case and it is
the one that lets Wine flush the registry on the way out.

The five seconds matter. `wineserver -k` is itself a Wine process, so it has
to be served by the very wineserver it is asking to leave. When that server
has stopped answering, `-k` does not fail — it joins the queue and waits
forever, which is why it cannot be the whole of a teardown. Past the deadline,
`protium prefix stop` signals instead: the wineserver first, because its
clients are blocked in calls to it and some exit on their own once it is gone,
then anything still running. `--force` skips straight to that.

It reports what it did, and it checks before claiming the prefix is stopped.

### How it finds the right processes

Not by name. Wine makes one directory per prefix under `/tmp`, named from the
prefix directory's device and inode — the prefix at
`~/.local/share/protium/prefixes/eldenring` has device 16777232 and inode
22138619, and Wine's directory for it is
`/tmp/.wine-501/server-1000010-151cefb`. Inside it is a `lock` file, and the
wineserver holds a write lock on that file for as long as it runs. Asking the
kernel who owns that lock names the wineserver exactly, which matters when
several prefixes are running at once.

The processes it was serving are found by their environment: every one of them
carries `WINEPREFIX`, and macOS will hand back a process's environment for the
asking. A process whose environment cannot be read is left out rather than
guessed at, because the list is about to be signalled.

## Removing a prefix

```
$ protium prefix remove skyrim
$ protium prefix remove skyrim --force     # in a script: skip the question
```

It prints what is about to go, and then asks:

```
$ protium prefix remove eldenring
This deletes the prefix eldenring:

  /Users/me/.local/share/protium/prefixes/eldenring
  4.1 GB (4402341888 bytes)
  38104 files in 4127 directories
  6 symlinks, unlinked but never followed

1 of those links out of the prefix eldenring. What they point at is left
exactly as it is — only the link goes:

  …/eldenring/drive_c/Program Files (x86)/Steam/steamapps -> /Users/me/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Steam/steamapps

Delete the prefix eldenring? [y/N]
```

`--force` skips that question and nothing else. It is spelled the same way as
everywhere else in the CLI, and like `protium install --force` it does not
widen what the command is willing to do — it only stops it asking.

### A symlink is unlinked, never followed

This is the rule the command rests on, and it is why the removal is protium's
own walk rather than an `rm -rf`.

A prefix can hold a link that points out of it, and that is not hypothetical.
The line above is a real one:

```
$ ls -l "~/.local/share/protium/prefixes/eldenring/drive_c/Program Files (x86)/Steam/steamapps"
lrwxr-xr-x  steamapps -> /Users/me/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Steam/steamapps
```

It is how one 66 GB game install is shared between a protium prefix and a
CrossOver bottle instead of being downloaded twice. Walking through it would
delete software protium did not put there, cannot put back, and would take
most of an evening to fetch again — and it would do so while having reported
the prefix's size as something far smaller than what was actually about to go.

So every entry is examined with a stat that does not follow links:

* a **directory** is emptied and then removed;
* **everything else, a symlink included**, is unlinked where it stands. The
  link goes; whatever it points at is not opened, not measured and not
  touched.

The same rule governs the size: a symlink counts as its own few bytes, never
as the size of its target. A prefix holding a link to 66 GB measures as the
prefix.

Links that lead out of the prefix are listed by name before the question, up
to eight of them, so "only the link goes" is something you can check rather
than a promise you have to take. Whether a link leads out is worked out from
the paths alone, without opening anything — which can name one link too many
if its path runs through another symlink, and never one too few.

### What it refuses

| | |
| --- | --- |
| A name that is not a plain identifier | the same `layout.checkName` rule that decided whether the prefix could be created: letters, digits, `-`, `_` and `.`. `..`, `a/b` and `$(…)` are refused there, and the resulting path is then checked to be a direct child of `<root>/prefixes` rather than trusted to be one |
| A prefix with Wine running in it | a live `wineserver` holds the prefix open, and deleting underneath it leaves a half-removed tree with a process still writing into it |
| A tree nested more than 128 directories deep | the walk recurses, and this bounds it. It is found by measuring, before anything is deleted, so such a tree is refused whole rather than left half-removed |

A running prefix is **refused, not stopped**. The two are separate commands on
purpose: stopping means signalling processes, and one command that both
signals and deletes is one whose failure modes cannot be reasoned about from
its name. `protium prefix remove` names the line to run instead, and `--force`
does not change this:

```
$ protium prefix remove eldenring
The prefix eldenring is running: a wineserver as pid 41233, serving 6 processes.

Stop it first:

  protium prefix stop eldenring

Nothing was deleted.
```

It looks for both halves, exactly as `protium prefix stop` does — the
wineserver by the lock it holds, and the processes it was serving by their
`WINEPREFIX` — so a session whose wineserver has already died is still seen.

### The default, afterwards

`<root>/defaults` records a *name*, not a path, so a default left pointing at
a prefix that no longer exists does not dangle in any way protium can notice
later: every command that resolves it fails with "no prefix named X" and
points at something you deliberately deleted. Removing the default prefix
therefore clears the `prefix=` key:

```
It was the default prefix, so `prefix` is now unset in /Users/me/.local/share/protium/defaults.
skyrim is the only prefix left, so it is the default.
```

With one prefix remaining that is the end of it — rule 4 above picks it up
with nothing recorded. With several, `protium use <name>` chooses the next.

The `runtime=` key is untouched: a runtime is not a prefix, and removing one
prefix says nothing about which Wine to use.

## Removing the downloads

`protium install` keeps the installers it fetched in `<root>/downloads`,
beside the prefixes rather than inside one, because the same `SteamSetup.exe`
serves every prefix.

```
$ protium install clean
$ protium install clean --force
```

The whole directory goes, rather than named entries in it. It holds the
publishers' own files under the names the catalogue gives them and nothing
that cannot be fetched again — the next `protium install` recreates it and
downloads what it needs. It is described and confirmed exactly like a prefix
removal, and it uses the same walk, so anything linked into it is unlinked
rather than followed.

## Do not point two different Wines at one prefix

Wine decides whether a prefix needs updating by comparing
`$WINEPREFIX/.update-timestamp` against the `wine.inf` of the Wine that is
starting. Two builds ship different `wine.inf` files, so pointing a protium
Wine and, say, CrossOver's at the same prefix makes *each* launch run a full
`wineboot --init` on the way in. That is slow, it rewrites the registry
underneath whatever state you were studying, and it is not always survivable:
`rundll32.exe setupapi,InstallHinfSection DefaultInstall` has been seen wedged
in a Cocoa run loop at 0% CPU for six minutes, after erroring out on
`wineusb.inf`.

Give each Wine its own prefix. Where a shared one is genuinely required — a
control comparison against another Wine on identical files is the honest case —
write the word `disable` into `.update-timestamp` to stop the churn, and
remember to undo it when the Wine is rebuilt, because the prefix will no longer
pick up changes on its own.

[`steam-login.md`](steam-login.md) is the comparison this came out of.

## The Windows user is `protium`

A prefix made by a protium runtime has its profile at `C:\users\protium`, and
`%USERNAME%` reports `protium`:

```
$ protium run cmd /c echo %USERNAME%
protium
$ protium run cmd /c echo %USERPROFILE%
C:\users\protium
```

That name comes from
[`patches/0002`](../patches/0002-advapi32-shell32-report-the-Windows-user-as-protium.patch).
Wine as CodeWeavers ship it answers `crossover`, from a patch of theirs
commented `CrossOver Hack 12735`, and a prefix protium built from nothing
therefore had its profile at `C:\users\crossover` — a name that is not
protium's to use, and that says CrossOver is involved when it is not.

The hardcoded name is in three places in `crossover-sources-26.3.0`, and the
third is the one that decides the directory:

| File | What it fixes |
| --- | --- |
| `dlls/advapi32/advapi.c:54,55` | `GetUserNameA` |
| `dlls/advapi32/advapi.c:79,80` | `GetUserNameW` |
| `dlls/shell32/shellpath.c:2636` | the `%USERPROFILE%` expansion, and so the profile directory |

**The profile directory does not follow from `GetUserName`, and it does not
follow from your Unix account either.** `CSIDL_PROFILE` is a `CSIDL_Type_User`
folder with no parent, so `_SHGetDefaultValue` returns the literal
`"%USERPROFILE%"`, and `_SHExpandEnvironmentStrings` expands that by appending
its *own* hardcoded name to the `ProfilesDirectory` prefix — it never asks
advapi32. `wineboot` reaches this through `SHGetFolderPathW( CSIDL_PROFILE )`
and writes the answer into `USERPROFILE`, `HOMEPATH` and `HOMEDRIVE`; it writes
`USERNAME` from `GetUserNameW` separately
(`programs/wineboot/wineboot.c:889,896`). Patching advapi32 alone would rename
the reported user and leave the directory where it was. That third site is
spelled as a character array rather than a string literal, which is why
grepping the tree for `crossover` does not find it:

```c
/* CrossOver Hack 12735 */
static const WCHAR userName[] = {'c','r','o','s','s','o','v','e','r',0};
```

### An older prefix has to be migrated, and protium will not do it for you

A prefix created before `patches/0002` keeps its profile at
`drive_c/users/crossover`. A runtime built with the patch looks under
`drive_c/users/protium`, does not find it, and creates an empty profile beside
the populated one. Nothing errors. The visible symptom is that **Steam is
signed out**, because its credentials and its CEF cache live at
`AppData/Local/Steam` inside the profile that was left behind — see
[`steam-login.md`](steam-login.md) for what re-signing in costs in this prefix.

`protium prefix list` says so when it sees one:

```
$ protium prefix list
protium prefixes

  * eldenring
      profile is `crossover`: a runtime with patches/0002 looks under `protium` — run `protium prefix migrate-user`
    p2test
```

and the migration is a command you run:

```
$ protium prefix migrate-user eldenring
In the prefix eldenring:
  rename  drive_c/users/crossover -> drive_c/users/protium
  rewrite user.reg
  rewrite userdef.reg
  rewrite system.reg

Steam's sign-in and its CEF cache live under drive_c/users/crossover/AppData/Local/Steam,
and move with the profile.

Migrate this prefix? [y/N]
```

**protium does not migrate a prefix on its own, and `run` does not refuse to
launch one.** Two reasons, and they are different:

* Migrating renames a directory holding somebody's game installs and rewrites
  three registry files. That is not something to do as a side effect of a
  launch that was asked for. The same rule already governs everything else
  here: `status` names the next step rather than taking it.
* `run` cannot tell whether the runtime it is about to use carries
  `patches/0002` — the state lives in the prefix, the patch lives in the Wine.
  A prefix on the old name is *correct* for any runtime built without 0002 —
  `wine-11.0-cx26.3-p1` was one — and only wrong for one built with it, so
  refusing would break a working setup to prevent a problem that setup does
  not have. `prefix list` reports the state and leaves the judgement where the
  information is.

The command refuses more than it does:

| State | What happens |
| --- | --- |
| profile is already `protium` | says so, exits 0 — safe to run twice |
| both profiles exist | **refused.** The `protium` one is the empty profile a patched Wine made; merging two `AppData` trees is a judgement about your saved games, so it is left to you |
| neither exists | refused — the prefix was never booted |
| the prefix is running | refused. `wineserver` holds the registry in memory and writes it back out when the last process leaves, so a rewrite done underneath it is lost on shutdown. Stop it with `protium prefix stop` first |

Every registry file is read and transformed in memory before anything on disk
moves, so a file that cannot be read stops the migration while the prefix is
still wholly the old one; only the writes follow the rename.

The rewrite matches two token shapes rather than the bare name — the escaped
path segment `\\users\\crossover`, and the value `"USERNAME"="crossover"` — so
a game installed in a directory called `crossover` is left alone. In the Elden
Ring prefix that is 33 occurrences in `user.reg`, 26 in `userdef.reg` and 3 in
`system.reg`: the Shell Folders set, the `Volatile Environment` block, and
`ProfileImagePath` with two copies of `Common Favorites`. The rules are in
`src/profile.zig` and tested there.

### `CX_REPORT_REAL_USERNAME` is not a way back

CrossOver's advapi32 hack yields to that variable and returns the Unix account
instead; the shell32 site does not read it at all. Setting it therefore moves
`%USERNAME%` and leaves the profile directory where it is. That divergence is
inherited rather than introduced — CrossOver has it already — and protium never
sets the variable. `patches/0002` keeps the name hardcoded on purpose: the
prefix layout is then the same on every machine regardless of the Unix account,
which is the property CodeWeavers were after and the one protium wants too.
