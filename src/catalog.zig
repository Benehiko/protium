//! The software `protium install` knows how to fetch, and what each piece
//! needs before it will work under a Wine you built.
//!
//! Everything here is data and pure functions: no download happens in this
//! file and no prefix is opened, so the whole catalogue is checked by the test
//! suite without a network or an installation to point it at.
//!
//! Two rules govern what may be added here, and they come straight from this
//! repository's reason for existing:
//!
//! * **A URL is the vendor's own.** protium redistributes nothing; it fetches
//!   what you would have downloaded yourself, from where you would have
//!   downloaded it. Every `url` below is HTTPS and belongs to the publisher of
//!   the software, and `install` refuses anything else.
//! * **A claim carries its evidence.** `confidence` says whether anyone has
//!   actually run the thing under a protium-built Wine, and `evidence` says
//!   what was observed and when. An entry nobody has tested is still worth
//!   listing — it saves someone finding the URL — but it is labelled, not
//!   implied to work.

const std = @import("std");
const env = @import("env.zig");
pub const webhelper = @import("webhelper.zig");

/// How much is actually known about an entry.
pub const Confidence = enum {
    /// Fetched, installed and started under a protium-built Wine. `evidence`
    /// says on what, and when.
    verified,
    /// The download is the vendor's and it resolves, but nobody has run the
    /// installer under protium. Listed so it can be tried; labelled so that
    /// listing it is not a claim.
    untested,
    /// Tried, and something specific stops it. `evidence` says what. This is
    /// worth a row of its own: "nobody has looked" and "someone looked and it
    /// does not work, for this reason" are the two states a catalogue most
    /// needs to keep apart.
    blocked,

    pub fn label(c: Confidence) []const u8 {
        return switch (c) {
            .verified => "verified",
            .untested => "untested",
            .blocked => "blocked",
        };
    }
};

/// An argument a program needs *here* that it would not need on Windows,
/// carried with the reason it is there. The reason is printed, because a flag
/// nobody can explain is a flag nobody can ever remove.
pub const Arg = struct {
    flag: []const u8,
    why: []const u8,
};

/// A `protium.conf` setting the program needs, and why.
pub const Need = struct {
    key: []const u8,
    value: []const u8,
    why: []const u8,
};

/// A file of the program's that protium replaces so the program works here.
///
/// This is the most invasive thing `install` does, so it is described rather
/// than performed silently: the replacement is printed with its reason before
/// it happens, the original is moved aside rather than deleted, and `--undo`
/// puts it back. A program that needs one of these is not `verified` on the
/// strength of the fix alone — the entry says what was replaced and why.
pub const Fix = struct {
    /// One line, printed before the change is made.
    summary: []const u8,
    /// The whole reason, in prose. Printed too.
    why: []const u8,
    /// Every copy of the file that has to be replaced.
    ///
    /// **Why this is a list.** A program may ship the same executable more
    /// than once and choose between the copies at run time, in which case
    /// replacing one of them is a fix that works until the program picks a
    /// different one. Steam does exactly this: `bin/cef` holds both
    /// `cef.win64` and `cef.win7x64`, and the client selects between them by
    /// the Windows version the prefix reports — measured on 2026-09-07, a
    /// prefix reporting 10.0.19045 runs `cef.win64` and the same prefix
    /// reporting 10.0.22000 runs `cef.win7x64` (docs/steam-login.md).
    /// Patching only the first meant the rendering fix silently stopped
    /// applying the moment the prefix was told it was Windows 11.
    ///
    /// A copy that is not on disk is skipped rather than failing: Steam
    /// downloads the second tree during its first run, so at install time
    /// only one of them usually exists.
    replaces: []const Replacement,
    /// Arguments the program must additionally be launched with for the
    /// replacement to survive — Steam repairs its own files otherwise. Null
    /// when the fix needs no help staying in place.
    needs_launch_args: bool = false,
};

/// One file a `Fix` replaces, and where that file's own copy is kept.
pub const Replacement = struct {
    /// The file replaced, as a Windows path inside the prefix.
    target: []const u8,
    /// Where the program's own copy is moved to. Beside the original, because
    /// the replacement finds it by name relative to itself.
    backup: []const u8,
};

pub const App = struct {
    /// What is typed after `protium install`.
    name: []const u8,
    /// One line, for `protium install list`.
    summary: []const u8,
    /// The vendor's own installer. HTTPS, and checked to be so by the tests.
    url: []const u8,
    /// What the download is saved as, under `<root>/downloads`.
    file: []const u8,
    /// Arguments the installer itself takes — a silent-install switch, say.
    installer_args: []const []const u8 = &.{},
    /// Where the program ends up inside the prefix, as a Windows path. Used to
    /// tell "already installed" from "not yet", and to print how to launch it.
    installed: []const u8,
    /// Arguments to launch it with here.
    launch_args: []const Arg = &.{},
    /// Settings the prefix needs before it will work.
    needs: []const Need = &.{},
    /// A file protium replaces to make the program work here, or null.
    fix: ?Fix = null,
    confidence: Confidence,
    /// What was actually observed, and when. Never a promise.
    evidence: []const u8,
    /// Anything else worth reading once, printed after a successful install.
    notes: []const u8 = "",
};

/// The stand-in `steamwebhelper.exe`, built from `src/webhelper.zig`.
pub const steam_webhelper_fix: Fix = .{
    .summary = "replace Steam's steamwebhelper.exe with one that adds --in-process-gpu",
    .why =
    \\Steam's interface is Chromium, and Chromium composites in a separate GPU
    \\process. That process starts here and nothing it composites reaches the
    \\window, so the client signs in, loads your library, and paints black.
    \\`--in-process-gpu` moves the compositor into the browser process and the
    \\window paints. The switch is Chromium's, not Steam's, and steam.exe
    \\forwards only its own six -cef-* flags, so the only way to pass it is to
    \\stand in front of the executable. protium builds the stand-in from source
    \\in this repository; it appends the switch and launches Valve's own binary,
    \\which is moved aside rather than deleted.
    ,
    .replaces = &.{
        .{
            .target = cef_win64 ++ webhelper.installed_as,
            .backup = cef_win64 ++ webhelper.real_binary,
        },
        .{
            .target = cef_win7x64 ++ webhelper.installed_as,
            .backup = cef_win7x64 ++ webhelper.real_binary,
        },
    },
    .needs_launch_args = true,
};

/// The two directories Steam keeps a `steamwebhelper.exe` in. Which one it
/// runs is decided by the Windows version the prefix reports, so both are
/// replaced — see `Fix.replaces`.
const cef_win64 = "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\";
const cef_win7x64 = "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\";

pub const apps = [_]App{
    .{
        .name = "steam",
        .summary = "Valve's Steam client",
        .url = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe",
        .file = "SteamSetup.exe",
        // Valve's installer is an NSIS one, and `/S` is NSIS's silent switch.
        // Without it the installer waits on Next, Next, Install in a window
        // that this Wine draws perfectly well — but a command that finishes on
        // its own is what makes `protium install` worth having.
        .installer_args = &.{"/S"},
        .installed = "C:\\Program Files (x86)\\Steam\\steam.exe",
        .launch_args = &.{
            .{
                .flag = "-noreactlogin",
                .why = "offline mode is chosen on the CEF login page, and that page often never renders here; the legacy login path does not depend on it",
            },
            .{
                .flag = "-noverifyfiles",
                .why = "Steam checks bin/cef against its own package on every start and puts Valve's steamwebhelper.exe back, which undoes the fix below before it can run",
            },
            .{
                .flag = "-norepairfiles",
                .why = "the same check, by its other name; both are Steam's own options and both are needed for the replacement to survive a launch",
            },
        },
        .fix = steam_webhelper_fix,
        .needs = &.{
            .{
                .key = "WINEMSYNC",
                .value = "1",
                .why = "msync is compiled in but inert unless this is set, and without it Steam cannot reach its own UI process (docs/wine-build.md)",
            },
        },
        .confidence = .verified,
        .evidence =
        \\Runs and renders. On 2026-09-07, under Wine 11.0 built from
        \\crossover-sources-26.3.0 with D3DMetal 4.0b2 on an M4 Mac running
        \\macOS 26.6.2: installs into a prefix `protium prefix new` had just
        \\made, signs in offline, and launches games. The window painted black
        \\until the fix below; with it, Steam's own cef_log.txt has no GPU
        \\lines at all, which is what the same client wrote under CrossOver
        \\when it worked.
        \\
        \\Signing in ONLINE depends on which runtime. On a Wine built without
        \\patches/0001, seven starts in eight never get past `Schedule init
        \\returned 22` in logs/connection_log.txt: Wine's own GetLogicalDrives
        \\never returns, because the clang-built PE side stores a BOOLEAN
        \\argument as one byte and the clang-built unix side reads 32 bits of
        \\it. Traced, proven by zeroing the stack slot in the running client,
        \\and patched on 2026-09-08; a runtime built with the patch
        \\(wine-11.0-cx26.3-p1) returned 1 and connected on three starts of
        \\three. The credential copied from another prefix is still refused
        \\by Valve, so a real sign-in needs the password typed in. Offline
        \\mode works on either runtime and needs the account's appcache/
        \\copied in as well as its credential (docs/steam-login.md).
        ,
        .notes =
        \\Sign in online once so credentials and licences cache, then switch to
        \\offline mode — docs/steam-login.md has both, and the flags that go in
        \\config/loginusers.vdf.
        ,
    },
    .{
        .name = "epic",
        .summary = "Epic Games Launcher",
        .url = "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi",
        .file = "EpicGamesLauncherInstaller.msi",
        .installed = "C:\\Program Files (x86)\\Epic Games\\Launcher\\Portal\\Binaries\\Win32\\EpicGamesLauncher.exe",
        .confidence = .untested,
        .evidence =
        \\The download resolves to Epic's own signed installer
        \\(EpicInstaller-20.1.4.msi, checked 2026-09-06). Nobody has run it
        \\under protium, so nothing is claimed about whether it installs,
        \\signs in, or renders.
        ,
    },
    .{
        .name = "battlenet",
        .summary = "Blizzard Battle.net",
        .url = "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe",
        .file = "Battle.net-Setup.exe",
        .installed = "C:\\Program Files (x86)\\Battle.net\\Battle.net Launcher.exe",
        .confidence = .untested,
        .evidence =
        \\The download resolves to Blizzard's own installer (1.0.66, checked
        \\2026-09-06). Nobody has run it under protium. Its installer is a
        \\downloader, so it fetches the rest itself and needs the network.
        ,
    },
};

/// The entry named, or null. Names are matched exactly: a catalogue that
/// guessed at near-misses would eventually fetch and run the wrong installer.
pub fn find(name: []const u8) ?*const App {
    for (&apps) |*a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

/// An installer that Windows Installer has to run rather than the loader.
pub fn isMsi(file: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(file, ".msi");
}

/// Everything protium will fetch is fetched over TLS from the publisher. This
/// is checked at install time as well as in the tests, so that a catalogue
/// edited without running the tests still cannot send someone to plain HTTP.
pub fn isSafeUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://");
}

/// The host path a Windows path inside a prefix corresponds to.
///
/// Wine's `C:` is the prefix's `drive_c`, and its separator is the one macOS
/// already uses, so this is the whole of the conversion. Only `C:` is handled:
/// every other drive letter in a prefix is a symlink whose target protium did
/// not choose, and guessing at one would produce a path that looks right and
/// points somewhere else.
pub fn hostPath(
    gpa: std.mem.Allocator,
    prefix_dir: []const u8,
    windows_path: []const u8,
) error{ OutOfMemory, NotOnDriveC }![]u8 {
    if (windows_path.len < 3) return error.NotOnDriveC;
    if (windows_path[1] != ':') return error.NotOnDriveC;
    if (windows_path[0] != 'c' and windows_path[0] != 'C') return error.NotOnDriveC;
    if (windows_path[2] != '\\' and windows_path[2] != '/') return error.NotOnDriveC;

    const rest = try gpa.dupe(u8, windows_path[3..]);
    for (rest) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    defer gpa.free(rest);
    return std.fs.path.join(gpa, &.{ prefix_dir, "drive_c", rest });
}

/// The settings an app needs that the prefix does not already set.
///
/// A value that is already there is left alone even when it differs: the
/// prefix's own file is the person's, and silently overwriting a deliberate
/// `WINEMSYNC=0` would be protium deciding it knows better. The difference is
/// reported instead — see `Conflict`.
pub fn missingNeeds(
    gpa: std.mem.Allocator,
    app: *const App,
    present: []const env.Setting,
) error{OutOfMemory}![]const Need {
    var out: std.ArrayList(Need) = .empty;
    for (app.needs) |need| {
        if (env.lookup(present, need.key) == null) try out.append(gpa, need);
    }
    return out.items;
}

/// A setting the prefix already has, with a value other than the one the app
/// needs. Reported rather than corrected.
pub const Conflict = struct { need: Need, found: []const u8 };

pub fn conflictingNeeds(
    gpa: std.mem.Allocator,
    app: *const App,
    present: []const env.Setting,
) error{OutOfMemory}![]const Conflict {
    var out: std.ArrayList(Conflict) = .empty;
    for (app.needs) |need| {
        const found = env.lookup(present, need.key) orelse continue;
        if (!std.mem.eql(u8, found, need.value)) {
            try out.append(gpa, .{ .need = need, .found = found });
        }
    }
    return out.items;
}

const testing = std.testing;

test "every entry is fetched over TLS from somewhere" {
    for (&apps) |*a| {
        try testing.expect(isSafeUrl(a.url));
        // A URL that is only a scheme is not a download.
        try testing.expect(a.url.len > "https://".len + 4);
    }
}

test "every entry says what it is, where it lands, and what is known about it" {
    for (&apps) |*a| {
        try testing.expect(a.name.len != 0);
        try testing.expect(a.summary.len != 0);
        try testing.expect(a.file.len != 0);
        try testing.expect(a.evidence.len != 0);
        // The claim and the evidence for it are written together, so an entry
        // cannot be promoted to `verified` without someone writing down what
        // they saw.
        try testing.expect(a.evidence.len > 40);
        try testing.expect(std.mem.startsWith(u8, a.installed, "C:\\"));
    }
}

test "a name is unique, and is something someone can type" {
    for (&apps, 0..) |*a, i| {
        for (apps[i + 1 ..]) |*b| try testing.expect(!std.mem.eql(u8, a.name, b.name));
        for (a.name) |c| switch (c) {
            'a'...'z', '0'...'9', '-' => {},
            else => return error.NameIsNotTypeable,
        };
    }
}

test "every flag and every setting carries the reason it is there" {
    for (&apps) |*a| {
        for (a.launch_args) |arg| {
            try testing.expect(arg.flag.len != 0);
            try testing.expect(arg.why.len > 20);
        }
        for (a.needs) |need| {
            try testing.expect(env.isValidKey(need.key));
            // A prefix may not be told to redirect itself, not even by the
            // catalogue.
            try testing.expect(!env.isManaged(need.key));
            try testing.expect(need.why.len > 20);
        }
    }
}

test "lookup is exact, because a near miss would run the wrong installer" {
    try testing.expectEqualStrings("steam", find("steam").?.name);
    try testing.expectEqual(@as(?*const App, null), find("Steam"));
    try testing.expectEqual(@as(?*const App, null), find("stea"));
    try testing.expectEqual(@as(?*const App, null), find(""));
}

test "an msi is recognised however it is spelled" {
    try testing.expect(isMsi("EpicGamesLauncherInstaller.msi"));
    try testing.expect(isMsi("Thing.MSI"));
    try testing.expect(!isMsi("SteamSetup.exe"));
    try testing.expect(!isMsi("msi"));
    try testing.expect(!isMsi(""));
}

test "http is refused, and so is anything that is not a URL" {
    try testing.expect(!isSafeUrl("http://example.com/x.exe"));
    try testing.expect(!isSafeUrl("file:///etc/passwd"));
    try testing.expect(!isSafeUrl("/tmp/x.exe"));
    try testing.expect(isSafeUrl("https://example.com/x.exe"));
}

test "a Windows path becomes the host path it actually is" {
    const a = testing.allocator;

    const steam = try hostPath(a, "/r/prefixes/default", "C:\\Program Files (x86)\\Steam\\steam.exe");
    defer a.free(steam);
    try testing.expectEqualStrings("/r/prefixes/default/drive_c/Program Files (x86)/Steam/steam.exe", steam);

    // Lower case and forward slashes are both things people write.
    const lower = try hostPath(a, "/r/p", "c:/windows/system32/vcruntime140.dll");
    defer a.free(lower);
    try testing.expectEqualStrings("/r/p/drive_c/windows/system32/vcruntime140.dll", lower);

    // Every other drive letter is a symlink protium did not create.
    try testing.expectError(error.NotOnDriveC, hostPath(a, "/r/p", "Z:\\home\\me"));
    try testing.expectError(error.NotOnDriveC, hostPath(a, "/r/p", "C:"));
    try testing.expectError(error.NotOnDriveC, hostPath(a, "/r/p", ""));
    try testing.expectError(error.NotOnDriveC, hostPath(a, "/r/p", "steam.exe"));
}

test "a need already met is not asked for again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const steam = find("steam").?;

    const none = try missingNeeds(a, steam, &.{});
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expectEqualStrings("WINEMSYNC", none[0].key);

    const met = try missingNeeds(a, steam, &.{.{ .key = "WINEMSYNC", .value = "1" }});
    try testing.expectEqual(@as(usize, 0), met.len);
}

test "a setting the prefix already disagrees about is reported, not overwritten" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const steam = find("steam").?;

    // Deliberately off: protium says so and leaves it, because the file is
    // the person's, not the catalogue's.
    const clash = try conflictingNeeds(a, steam, &.{.{ .key = "WINEMSYNC", .value = "0" }});
    try testing.expectEqual(@as(usize, 1), clash.len);
    try testing.expectEqualStrings("0", clash[0].found);
    try testing.expectEqualStrings("1", clash[0].need.value);

    const agreed = try conflictingNeeds(a, steam, &.{.{ .key = "WINEMSYNC", .value = "1" }});
    try testing.expectEqual(@as(usize, 0), agreed.len);

    // Not set at all is `missingNeeds`' business, not this one's.
    const absent = try conflictingNeeds(a, steam, &.{});
    try testing.expectEqual(@as(usize, 0), absent.len);
}

test "a fix names a file, a place to keep the original, and a reason" {
    for (&apps) |*a| {
        const fix = a.fix orelse continue;
        try testing.expect(fix.summary.len != 0);
        // The reason is printed before the file is touched, so it has to be
        // long enough to actually be one.
        try testing.expect(fix.why.len > 80);
        // A fix that replaces nothing is a fix that does nothing.
        try testing.expect(fix.replaces.len != 0);
        for (fix.replaces) |r| {
            try testing.expect(std.mem.startsWith(u8, r.target, "C:\\"));
            try testing.expect(std.mem.startsWith(u8, r.backup, "C:\\"));
            // Replacing a file with itself would delete it.
            try testing.expect(!std.mem.eql(u8, r.target, r.backup));
        }
    }
}

test "no two replacements in one fix name the same file" {
    // Applying a fix twice to one path would copy the stand-in over the
    // backup on the second pass, losing the program's own binary — the one
    // thing `--undo` needs.
    for (&apps) |*a| {
        const fix = a.fix orelse continue;
        for (fix.replaces, 0..) |r, i| {
            for (fix.replaces[i + 1 ..]) |other| {
                try testing.expect(!std.mem.eql(u8, r.target, other.target));
                try testing.expect(!std.mem.eql(u8, r.backup, other.backup));
                // A backup must not be another replacement's target either.
                try testing.expect(!std.mem.eql(u8, r.backup, other.target));
                try testing.expect(!std.mem.eql(u8, r.target, other.backup));
            }
        }
    }
}

test "the stand-in goes into every CEF tree Steam chooses between" {
    // Steam picks between bin/cef/cef.win64 and bin/cef/cef.win7x64 by the
    // Windows version the prefix reports (docs/steam-login.md, 2026-09-07).
    // Replacing only one leaves the client painting black in the other.
    const fix = find("steam").?.fix.?;
    var has_win64 = false;
    var has_win7x64 = false;
    for (fix.replaces) |r| {
        if (std.mem.indexOf(u8, r.target, "\\cef.win64\\") != null) has_win64 = true;
        if (std.mem.indexOf(u8, r.target, "\\cef.win7x64\\") != null) has_win7x64 = true;
    }
    try testing.expect(has_win64);
    try testing.expect(has_win7x64);
}

test "the stand-in and the catalogue agree on both file names" {
    // src/webhelper.zig finds the real binary by taking its own path and
    // swapping one name for the other. If these drift apart, the stand-in
    // launches itself for ever and Steam never starts — a failure that would
    // look nothing like a renamed constant.
    const fix = find("steam").?.fix.?;
    for (fix.replaces) |r| {
        try testing.expect(std.mem.endsWith(u8, r.target, webhelper.installed_as));
        try testing.expect(std.mem.endsWith(u8, r.backup, webhelper.real_binary));

        // …and they must live in the same directory, because that swap is the
        // only thing that relates them.
        const target_dir = r.target[0 .. r.target.len - webhelper.installed_as.len];
        const backup_dir = r.backup[0 .. r.backup.len - webhelper.real_binary.len];
        try testing.expectEqualStrings(target_dir, backup_dir);
    }
}

test "a fix that Steam would undo comes with the flags that stop it" {
    const steam = find("steam").?;
    try testing.expect(steam.fix.?.needs_launch_args);
    // Steam puts its own steamwebhelper.exe back on every start unless both
    // of these are passed, which would silently undo the fix.
    var has_verify = false;
    var has_repair = false;
    for (steam.launch_args) |arg| {
        if (std.mem.eql(u8, arg.flag, "-noverifyfiles")) has_verify = true;
        if (std.mem.eql(u8, arg.flag, "-norepairfiles")) has_repair = true;
    }
    try testing.expect(has_verify);
    try testing.expect(has_repair);
}

test "every confidence a row can carry prints as one word" {
    for (std.enums.values(Confidence)) |c| {
        try testing.expect(c.label().len != 0);
        try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, c.label(), ' '));
    }
    try testing.expectEqualStrings("verified", Confidence.verified.label());
    try testing.expectEqualStrings("untested", Confidence.untested.label());
    // The one that matters: "nobody looked" and "someone looked and it does
    // not work" must not print the same.
    try testing.expectEqualStrings("blocked", Confidence.blocked.label());
}
