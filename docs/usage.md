# Using protium

Everything after the [quickstart](../README.md#quickstart): Steam, running
games, and looking after prefixes.

## Steam

```sh
protium install steam
```

This downloads Valve's installer and prints its size and SHA-256. It sets
`WINEMSYNC=1` in the prefix, since without it Steam's UI fails in a way that
looks like a network fault ([why](wine-build.md#winemsync1-is-not-optional)).
It runs the installer, applies the fix that makes Steam's window paint
([details](steam-rendering.md)), and prints the launch command.

Start Steam:

```sh
protium run steam
```

protium adds the three arguments Steam needs here: `-noreactlogin`,
`-noverifyfiles` and `-norepairfiles`. Without the last two, Steam restores its
own files, removes the rendering fix, and its window goes black. After a Steam
update, or whenever the window goes black, run `protium install steam` again.
It leaves Steam alone and restores the fix.

Sign in **online, once**, so Steam caches your credentials and licences. Then
install games from Steam as usual.

## Running a game

With Steam signed in and running, start the game by the name Steam shows for
it:

```sh
protium run "elden ring"
```

protium looks the game up in Steam's records, in every Steam library in the
prefix, on any drive. It picks the game's program and skips installers,
bundled runtimes, crash reporters and Easy Anti-Cheat, which does not work
here. For Elden Ring that is `Game/eldenring.exe`. It also sets `SteamAppId`,
which a game needs to reach Steam when started directly, and starts the game
in its own directory, as Steam does. Elden Ring 2.7.1.0 refuses to start from
anywhere else: see [Where `protium run` starts a
program](working-directory.md).

The app ID works too (`protium run 1245620`), and so does the executable's
file name (`protium run eldenring.exe`). Tab completion offers all three. If
protium cannot tell which program is the game, it lists the candidates. Run
the one you want by its file name or path.

> [!NOTE]
> The title screen reports `A connection error occurred. Unable to start in
> online mode.` and the menu reads `OFFLINE`. This is expected. `CONTINUE`
> loads your save.

> [!NOTE]
> Quitting the game from its menu ends in a Wine crash report instead of a
> clean exit. The game has already stopped by then. This is a known issue; see
> [Elden Ring crashes when it quits](quit-crash.md).

If the game exits at once with `connect to global user failed`, Steam is not
signed in. See [Steam sign-in](#steam-sign-in).

## Steam sign-in

Online sign-in works on a runtime built with `patches/0001` and GnuTLS. It
reached `Logged On` on 2026-09-08. A Wine built without them fails twice: seven
starts in eight never open the connection gate, and without TLS every WebSocket
connection fails. [docs/steam-login.md](steam-login.md) traces both.

Offline mode avoids the problem, and games need nothing more. Add these lines
to your account's block in
`<prefix>/drive_c/Program Files (x86)/Steam/config/loginusers.vdf`:

```
"WantsOfflineMode"        "1"
"SkipOfflineModeWarning"  "1"
```

These flags are not enough on their own. Steam chooses offline mode on its CEF
login page, which often never renders here, and the client stays logged off.
`protium run steam` passes `-noreactlogin`, which starts Steam on the legacy
login path instead.

## Everyday use

```sh
protium install list                   # software protium can fetch
protium install steam                  # install it into the default prefix
protium install clean                  # delete downloaded installers
protium run steam                      # start Steam with the arguments it needs
protium run "elden ring"               # a Steam game, by title or app ID
protium run eldenring.exe              # any .exe in the prefix, by file name
protium run ~/Downloads/Setup.exe      # run any Windows program
protium run "C:\Program Files\…\Game.exe"

protium prefix list                    # list prefixes; * marks the default
protium prefix new skyrim              # create a prefix
protium use skyrim                     # make it the default
protium prefix stop                    # stop the Wine running in a prefix
protium prefix remove skyrim           # delete a prefix, after confirming
protium prefix migrate-user            # move an old prefix to the protium user
```

A *prefix* is one Windows installation, with its own `C:` drive, registry and
programs. Give games that need different settings a prefix each.

Each prefix keeps its settings in a `protium.conf`: frame cap, ray tracing and
Wine options. protium applies them to everything launched in that prefix.
[prefixes.md](prefixes.md) covers them. `protium install list` marks
which installers have been tested; [install.md](install.md) covers
the command.

`protium prefix remove` shows the path, the size and any symlinks leading out
of the prefix, then asks. It never follows those links. A prefix can link into
another Steam library, and only the link is removed. `--yes` (`-y`) skips the
question. protium refuses to remove a prefix while Wine runs in it, and prints
the `prefix stop` command to run first.

The Windows user inside a prefix is `protium`, with its profile at
`C:\users\protium`. Older prefixes use a `crossover` profile, which current
runtimes do not find, so Steam starts signed out. `protium prefix list` flags
these prefixes, and `protium prefix migrate-user` moves them. protium never
migrates on its own.
[Details](prefixes.md#the-windows-user-is-protium).
