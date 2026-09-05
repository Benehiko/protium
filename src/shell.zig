//! Rendering an environment as something a shell will evaluate.
//!
//! protium cannot set a variable in the shell that ran it — no process can —
//! so the shell has to evaluate what protium prints. That makes the quoting
//! here a correctness question rather than a cosmetic one: every value below
//! ends up as shell source, and a value carrying a quote character has to
//! survive that intact.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Dialect = enum {
    fish,
    zsh,
    bash,
    /// Some other Bourne-family shell. The syntax is the same; only the name
    /// of the startup file is unknown, and guessing it would send someone to
    /// edit a file that does not exist.
    posix,

    /// fish is the one shell here that is not Bourne-family, and the one
    /// whose assignment syntax differs.
    pub fn isFish(d: Dialect) bool {
        return d == .fish;
    }

    pub fn fromName(name: []const u8) ?Dialect {
        if (std.mem.eql(u8, name, "fish")) return .fish;
        if (std.mem.eql(u8, name, "zsh")) return .zsh;
        if (std.mem.eql(u8, name, "bash")) return .bash;
        if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "posix")) return .posix;
        return null;
    }

    /// The dialect implied by `$SHELL`. Anything unrecognised is Bourne-family
    /// rather than an error: the assignment syntax is right for every shell
    /// but fish, so the worst case is a correct hook and a vaguer instruction
    /// about where to put it.
    pub fn fromShellPath(path: ?[]const u8) Dialect {
        const p = path orelse return .posix;
        const base = std.fs.path.basename(p);
        return fromName(base) orelse .posix;
    }

    /// The line to add to a startup file so that every new shell inherits the
    /// prefix. `protium env` prints a comment and succeeds when nothing is
    /// installed yet, so this line is safe to add before the rest of the
    /// install is finished.
    pub fn hook(d: Dialect) []const u8 {
        return switch (d) {
            .fish => "protium env --shell fish | source",
            .zsh => "eval \"$(protium env --shell zsh)\"",
            .bash => "eval \"$(protium env --shell bash)\"",
            .posix => "eval \"$(protium env --shell posix)\"",
        };
    }

    /// Where that line goes, when it is known. On macOS, Terminal opens a
    /// login shell, which is why bash reads `.bash_profile` and not `.bashrc`.
    pub fn startupFile(d: Dialect) ?[]const u8 {
        return switch (d) {
            .fish => "~/.config/fish/config.fish",
            .zsh => "~/.zshrc",
            .bash => "~/.bash_profile",
            .posix => null,
        };
    }
};

/// `NAME=value`, as the dialect spells it, followed by a newline.
pub fn assign(w: *Writer, d: Dialect, name: []const u8, value: []const u8) Writer.Error!void {
    try w.writeAll(if (d.isFish()) "set -gx " else "export ");
    try w.writeAll(name);
    try w.writeAll(if (d.isFish()) " " else "=");
    try quote(w, d, value);
    try w.writeByte('\n');
}

/// A value, quoted so that the shell reproduces it byte for byte.
///
/// Both dialects single-quote, and differ only in how a single quote gets in:
/// a Bourne shell has no escape inside `'...'` at all, so the string has to be
/// closed and reopened around an escaped quote, while fish does have escapes
/// there — but then also gives `\` a meaning, so backslashes have to be
/// doubled.
pub fn quote(w: *Writer, d: Dialect, value: []const u8) Writer.Error!void {
    try w.writeByte('\'');
    for (value) |c| {
        if (d.isFish()) {
            if (c == '\\' or c == '\'') try w.writeByte('\\');
            try w.writeByte(c);
        } else if (c == '\'') {
            try w.writeAll("'\\''");
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte('\'');
}

/// A comment, which both dialects spell the same way. Used so that `protium
/// env` can explain itself inside a shell startup file without the
/// explanation being executed.
pub fn comment(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeAll("# ");
    try w.writeAll(text);
    try w.writeByte('\n');
}

const testing = std.testing;

fn render(buf: []u8, d: Dialect, name: []const u8, value: []const u8) ![]u8 {
    var w = Writer.fixed(buf);
    try assign(&w, d, name, value);
    return w.buffered();
}

test "each dialect assigns and exports the way it actually spells it" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "export WINEPREFIX='/r/prefixes/default'\n",
        try render(&buf, .zsh, "WINEPREFIX", "/r/prefixes/default"),
    );
    try testing.expectEqualStrings(
        "set -gx WINEPREFIX '/r/prefixes/default'\n",
        try render(&buf, .fish, "WINEPREFIX", "/r/prefixes/default"),
    );
    // bash and posix are the same shell family as zsh here.
    try testing.expectEqualStrings(
        "export PATH='/w/bin:/usr/bin'\n",
        try render(&buf, .bash, "PATH", "/w/bin:/usr/bin"),
    );
}

test "a value carrying a quote survives being evaluated" {
    var buf: [256]u8 = undefined;
    // A Bourne shell cannot escape inside '...', so the quote goes outside it.
    try testing.expectEqualStrings(
        "export X='it'\\''s'\n",
        try render(&buf, .posix, "X", "it's"),
    );
    // fish can escape inside, and so must also escape the escape.
    try testing.expectEqualStrings(
        "set -gx X 'it\\'s'\n",
        try render(&buf, .fish, "X", "it's"),
    );
    try testing.expectEqualStrings(
        "set -gx X 'C:\\\\Games'\n",
        try render(&buf, .fish, "X", "C:\\Games"),
    );
    // A Bourne shell leaves a backslash alone inside single quotes.
    try testing.expectEqualStrings(
        "export X='C:\\Games'\n",
        try render(&buf, .posix, "X", "C:\\Games"),
    );
}

test "a value that tries to run something is data, not code" {
    var buf: [256]u8 = undefined;
    const attack = "$(touch /tmp/pwned)`id`;rm -rf ~";
    try testing.expectEqualStrings(
        "export X='$(touch /tmp/pwned)`id`;rm -rf ~'\n",
        try render(&buf, .posix, "X", attack),
    );
    try testing.expectEqualStrings(
        "set -gx X '$(touch /tmp/pwned)`id`;rm -rf ~'\n",
        try render(&buf, .fish, "X", attack),
    );
}

test "the dialect is taken from the shell's name, and anything else is Bourne" {
    try testing.expectEqual(Dialect.fish, Dialect.fromShellPath("/opt/homebrew/bin/fish"));
    try testing.expectEqual(Dialect.zsh, Dialect.fromShellPath("/bin/zsh"));
    try testing.expectEqual(Dialect.bash, Dialect.fromShellPath("/bin/bash"));
    try testing.expectEqual(Dialect.posix, Dialect.fromShellPath("/usr/local/bin/nu"));
    try testing.expectEqual(Dialect.posix, Dialect.fromShellPath(null));
    try testing.expectEqual(@as(?Dialect, null), Dialect.fromName("powershell"));
}

test "only fish gets fish's hook, and only known shells claim a startup file" {
    try testing.expect(std.mem.indexOf(u8, Dialect.fish.hook(), "| source") != null);
    try testing.expect(std.mem.indexOf(u8, Dialect.zsh.hook(), "eval") != null);
    try testing.expectEqualStrings("~/.config/fish/config.fish", Dialect.fish.startupFile().?);
    try testing.expectEqualStrings("~/.zshrc", Dialect.zsh.startupFile().?);
    try testing.expectEqual(@as(?[]const u8, null), Dialect.posix.startupFile());
}

test "a comment is inert in both dialects" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try comment(&w, "nothing to set yet");
    try testing.expectEqualStrings("# nothing to set yet\n", w.buffered());
}
