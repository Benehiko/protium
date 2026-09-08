//! Which Windows user a prefix belongs to, and how a prefix made by an
//! unpatched Wine is moved onto the new name.
//!
//! A Wine built from crossover-sources-26.3.0 answers `GetUserName` with
//! "crossover" and puts the profile at `C:\users\crossover`, because CrossOver
//! Hack 12735 hardcodes that name in three places. `patches/0002` replaces it
//! with `protium`, so a prefix created before that patch and a Wine built
//! after it disagree about where the profile is: Wine looks under
//! `drive_c/users/protium`, finds nothing, and creates an empty profile beside
//! the populated one. Steam's credentials and its CEF cache live in the old
//! one, under `AppData/Local/Steam`, so the visible symptom is being signed
//! out with the sign-in cache apparently intact.
//!
//! **protium does not migrate a prefix on its own.** It detects the mismatch
//! and prints `instruction`; `protium prefix migrate-user` is what performs
//! it. Renaming a directory that holds someone's game installs and rewriting
//! three registry files is not something to do as a side effect of a launch
//! the user asked for, and the same rule already governs building a runtime:
//! `doctor` and `status` say what to run, they do not run it.
//!
//! Everything here is string and path arithmetic. `main.zig` opens the
//! directories, renames and writes; it decides nothing.

const std = @import("std");

/// The Windows user a protium-built Wine reports, from `patches/0002`.
pub const user = "protium";

/// The name a Wine without that patch reports. Prefixes created by one are
/// still on disk, which is the only reason this constant exists.
pub const legacy_user = "crossover";

/// The profile directories, relative to the prefix.
pub const dir = "drive_c/users/" ++ user;
pub const legacy_dir = "drive_c/users/" ++ legacy_user;

/// The registry files that name the profile. `user.reg` holds the Shell
/// Folders and the volatile environment, `userdef.reg` the same set for the
/// default user, and `system.reg` the `ProfileImagePath` and two copies of
/// `Common Favorites`. All three are rewritten together or not at all.
pub const registry_files = [_][]const u8{ "user.reg", "userdef.reg", "system.reg" };

/// The one line printed beside a prefix that still has the old profile.
///
/// Worded as a condition rather than a fault: a prefix on the old name is
/// correct for a runtime built without `patches/0002`, and only wrong for one
/// built with it. `prefix list` cannot tell which runtime the next launch
/// will use, so it reports the state and leaves the judgement to the reader.
pub const instruction = "profile is `" ++ legacy_user ++ "`: a runtime with patches/0002 looks under `" ++
    user ++ "` — run `protium prefix migrate-user`";

/// What a migration would have to do, given what is on disk.
pub const Plan = enum {
    /// The profile is already `protium`. Nothing to do, and saying so is not
    /// an error: the command is safe to run twice.
    done,
    /// The old profile is there and the new one is not — rename it.
    rename,
    /// Both are there. That is what an unmigrated prefix booted by a patched
    /// Wine looks like: the empty profile is the new one. Merging them means
    /// choosing between two `AppData` trees, which is a judgement about
    /// somebody's saved games, so it is refused and left to them.
    conflict,
    /// Neither is there. Not a prefix, or a prefix `wineboot` has not
    /// finished with yet.
    absent,
};

pub fn plan(has_legacy: bool, has_current: bool) Plan {
    if (has_legacy and has_current) return .conflict;
    if (has_legacy) return .rename;
    if (has_current) return .done;
    return .absent;
}

/// One line, addressed to whoever ran the command.
pub fn planProblem(p: Plan) ?[]const u8 {
    return switch (p) {
        .done, .rename => null,
        .conflict => "both `" ++ legacy_dir ++ "` and `" ++ dir ++
            "` exist; the second is the empty one a patched Wine made. Move what you " ++
            "want out of the first, delete the one you do not want, and run this again",
        .absent => "this prefix has no profile directory yet — boot it with `protium prefix new` first",
    };
}

/// Rewrite the profile name in one registry file's bytes.
///
/// A `.reg` file escapes its backslashes, so the profile path appears as
/// `C:\\users\\crossover\\Desktop` and `HOMEPATH` as `\\users\\crossover`.
/// Two token shapes cover every occurrence in a booted prefix — the path
/// segment and the `USERNAME` value — and matching those rather than the bare
/// name is what keeps a game installed in a directory called `crossover`, or
/// a `CrossOverPath` value, from being rewritten along with the profile.
///
/// A path segment only matches when what follows it ends the segment, so
/// `\\users\\crossovers` is left alone.
///
/// The transform is idempotent: run against an already-migrated file it finds
/// nothing and returns a copy.
pub fn rewriteRegistry(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const seg_from = "\\\\users\\\\" ++ legacy_user;
    const seg_to = "\\\\users\\\\" ++ user;
    const name_from = "\"USERNAME\"=\"" ++ legacy_user ++ "\"";
    const name_to = "\"USERNAME\"=\"" ++ user ++ "\"";

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(gpa, source.len);

    var i: usize = 0;
    while (i < source.len) {
        const rest = source[i..];
        if (std.mem.startsWith(u8, rest, seg_from) and endsSegment(rest[seg_from.len..])) {
            try out.appendSlice(gpa, seg_to);
            i += seg_from.len;
            continue;
        }
        if (std.mem.startsWith(u8, rest, name_from)) {
            try out.appendSlice(gpa, name_to);
            i += name_from.len;
            continue;
        }
        try out.append(gpa, source[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// What may follow a profile path segment: another escaped separator, the
/// closing quote of the value, or the end of the file.
fn endsSegment(after: []const u8) bool {
    if (after.len == 0) return true;
    if (after[0] == '"') return true;
    return std.mem.startsWith(u8, after, "\\\\");
}

const testing = std.testing;

test "the plan follows from which profile directories exist" {
    try testing.expectEqual(Plan.rename, plan(true, false));
    try testing.expectEqual(Plan.done, plan(false, true));
    try testing.expectEqual(Plan.conflict, plan(true, true));
    try testing.expectEqual(Plan.absent, plan(false, false));

    // Only the two that can go ahead have nothing to say.
    try testing.expect(planProblem(.done) == null);
    try testing.expect(planProblem(.rename) == null);
    try testing.expect(planProblem(.conflict) != null);
    try testing.expect(planProblem(.absent) != null);
}

test "the profile paths are the ones Wine uses" {
    try testing.expectEqualStrings("drive_c/users/protium", dir);
    try testing.expectEqualStrings("drive_c/users/crossover", legacy_dir);
}

test "every shape the profile takes in a booted prefix is rewritten" {
    const a = testing.allocator;
    // Taken from the eldenring prefix's user.reg, system.reg and userdef.reg:
    // a Shell Folders path, HOMEPATH's driveless form, the USERNAME value and
    // ProfileImagePath, which is the whole profile with nothing after it.
    const source =
        \\"Local AppData"="C:\\users\\crossover\\AppData\\Local"
        \\"HOMEPATH"="\\users\\crossover"
        \\"USERNAME"="crossover"
        \\"ProfileImagePath"="C:\\users\\crossover"
        \\
    ;
    const got = try rewriteRegistry(a, source);
    defer a.free(got);
    try testing.expectEqualStrings(
        \\"Local AppData"="C:\\users\\protium\\AppData\\Local"
        \\"HOMEPATH"="\\users\\protium"
        \\"USERNAME"="protium"
        \\"ProfileImagePath"="C:\\users\\protium"
        \\
    , got);
}

test "a name that only looks like the profile is left alone" {
    const a = testing.allocator;
    // A game installed in a directory called crossover, CrossOver's own path
    // value, and a longer profile name that starts with the old one. None of
    // these is the profile, and rewriting any of them would break a path that
    // points at something real.
    const source =
        \\"Path"="C:\\Program Files\\crossover\\bin"
        \\"Steam"="C:\\users\\crossovers\\AppData"
        \\"Comment"="installed by crossover"
        \\
    ;
    const got = try rewriteRegistry(a, source);
    defer a.free(got);
    try testing.expectEqualStrings(source, got);
}

test "rewriting twice changes nothing the second time" {
    const a = testing.allocator;
    const source =
        \\"USERNAME"="crossover"
        \\"Desktop"="C:\\users\\crossover\\Desktop"
        \\
    ;
    const once = try rewriteRegistry(a, source);
    defer a.free(once);
    const twice = try rewriteRegistry(a, once);
    defer a.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "a file with nothing to change comes back whole" {
    const a = testing.allocator;
    const source = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1788847893\n";
    const got = try rewriteRegistry(a, source);
    defer a.free(got);
    try testing.expectEqualStrings(source, got);
}
