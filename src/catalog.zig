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
    confidence: Confidence,
    /// What was actually observed, and when. Never a promise.
    evidence: []const u8,
    /// Anything else worth reading once, printed after a successful install.
    notes: []const u8 = "",
};

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
                .flag = "-cef-disable-gpu",
                .why = "without it Steam's CEF GPU process dies with an access violation six times per start; this does not fix the black window (docs/steam-rendering.md)",
            },
        },
        .needs = &.{
            .{
                .key = "WINEMSYNC",
                .value = "1",
                .why = "msync is compiled in but inert unless this is set, and without it Steam cannot reach its own UI process (docs/wine-build.md)",
            },
        },
        .confidence = .blocked,
        .evidence =
        \\`steam.exe` itself is 64-bit and runs: it signs in offline and launches
        \\games under Wine 11.0 built from crossover-sources-26.3.0 with D3DMetal
        \\4.0b2, on an M4 Mac running macOS 26.6.1 (2026-09-06). Its own window
        \\paints black, which docs/steam-rendering.md records.
        \\
        \\`SteamSetup.exe` is 32-bit, and a prefix made by `protium prefix new`
        \\has an empty syswow64, so the installer cannot start there — protium
        \\checks for that and says so rather than running it. Fill that directory
        \\and the same command installs Steam silently, start to finish. This is
        \\a fault in prefix creation, not in Steam: docs/install.md has both
        \\measurements.
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
