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
