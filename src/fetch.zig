//! Fetching an installer over HTTPS, and saying exactly what arrived.
//!
//! protium redistributes nothing, so `install` downloads the vendor's own file
//! at the moment you ask for it. That file is a moving target — Valve replace
//! `SteamSetup.exe` whenever they like — so there is no digest to pin it
//! against, and pretending otherwise would be worse than not trying: a pinned
//! hash that fails every few months teaches people to pass `--force`.
//!
//! What can be done honestly is to *record* what arrived. Every download
//! prints its length and its SHA-256, so the thing you installed has a name
//! you can quote afterwards, which is the same standard `docs/` is held to.
//!
//! The download is Zig's own HTTP client over Zig's own TLS, verified against
//! the system's root certificates. Nothing is vendored and nothing is shelled
//! out to.

const std = @import("std");
const Io = std.Io;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Report = struct {
    bytes: u64,
    digest: [Sha256.digest_length]u8,
    /// The file was already in the download directory and was not fetched
    /// again. Reported, because it changes what the digest is evidence of.
    reused: bool,

    /// The digest as the 64 lower-case hex characters everyone else prints.
    pub fn hex(r: Report, buf: *[Sha256.digest_length * 2]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x}", .{&r.digest}) catch unreachable;
    }
};

pub const Error = error{
    /// The server answered, but not with the file.
    HttpStatus,
    /// The URL was not one protium is willing to fetch.
    InsecureUrl,
};

/// Fetch `url` into `dest`, unless `dest` is already there and `refresh` is
/// false. Returns what arrived.
///
/// The download goes to `dest` + `.part` and is renamed once the body has been
/// written, so an interrupted fetch cannot leave a truncated installer behind
/// that the next run would happily execute.
pub fn download(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    dest: []const u8,
    refresh: bool,
) !Report {
    if (!std.mem.startsWith(u8, url, "https://")) return Error.InsecureUrl;

    const cwd = Io.Dir.cwd();
    const present = blk: {
        cwd.access(io, dest, .{}) catch break :blk false;
        break :blk true;
    };
    if (present and !refresh) {
        return .{ .bytes = try sizeOf(io, dest), .digest = try digestOf(io, dest), .reused = true };
    }

    const partial = try std.fmt.allocPrint(gpa, "{s}.part", .{dest});
    defer gpa.free(partial);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    {
        var file = try cwd.createFile(io, partial, .{});
        defer file.close(io);

        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writerStreaming(io, &buf);

        const res = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer.interface,
            // Every vendor here answers with a redirect to a CDN, and
            // Microsoft's `aka.ms` takes two hops before it does.
            .redirect_behavior = @enumFromInt(10),
        }) catch |err| {
            cwd.deleteFile(io, partial) catch {};
            return err;
        };
        writer.interface.flush() catch |err| {
            cwd.deleteFile(io, partial) catch {};
            return err;
        };
        if (res.status != .ok) {
            cwd.deleteFile(io, partial) catch {};
            return Error.HttpStatus;
        }
    }

    try cwd.rename(partial, cwd, dest, io);
    return .{ .bytes = try sizeOf(io, dest), .digest = try digestOf(io, dest), .reused = false };
}

fn sizeOf(io: Io, path: []const u8) !u64 {
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return st.size;
}

/// The SHA-256 of a file, read in chunks rather than into memory: an installer
/// that fetches the rest of itself is small, but Epic's is not, and a
/// catalogue entry added later might be larger still.
fn digestOf(io: Io, path: []const u8) ![Sha256.digest_length]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hasher = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var vec: [1][]u8 = .{&buf};
    while (true) {
        const n = file.readStreaming(io, &vec) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.finalResult();
}

/// A byte count as a person would read it. Deliberately not `1.0 KB`: the
/// point of printing a size is to notice when a 2 MB installer arrives as a
/// 4 KB error page, and a rounded number hides exactly that.
pub fn size(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB" };
    var n: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (n >= 1024 and unit + 1 < units.len) : (unit += 1) n /= 1024;
    if (unit == 0) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s} ({d} bytes)", .{ n, units[unit], bytes }) catch "?";
}

const testing = std.testing;

test "a size is readable without losing the number it stands for" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0 bytes", size(&buf, 0));
    try testing.expectEqualStrings("512 bytes", size(&buf, 512));
    try testing.expectEqualStrings("1023 bytes", size(&buf, 1023));
    // Past a kilobyte the exact count is kept alongside, because a 4 KB
    // "installer" is an error page and the round number would not say so.
    try testing.expectEqualStrings("1.0 KB (1024 bytes)", size(&buf, 1024));
    try testing.expectEqualStrings("2.4 MB (2500000 bytes)", size(&buf, 2_500_000));
    try testing.expectEqualStrings("1.0 GB (1073741824 bytes)", size(&buf, 1 << 30));
    // Nothing above gigabytes: an installer that large is a mistake worth
    // reading as a very large number of gigabytes.
    try testing.expectEqualStrings("1024.0 GB (1099511627776 bytes)", size(&buf, 1 << 40));
}

test "a digest prints as the sixty-four characters everyone else prints" {
    // The SHA-256 of no input at all, which is a fixed and checkable value.
    var hasher = Sha256.init(.{});
    const report: Report = .{ .bytes = 0, .digest = hasher.finalResult(), .reused = false };
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        report.hex(&buf),
    );
}

test "a URL that is not HTTPS is refused before anything is opened" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // No `Io` is needed: the check happens before the first syscall, which is
    // the point of it happening here rather than in the HTTP client.
    try testing.expectError(Error.InsecureUrl, download(
        arena_state.allocator(),
        undefined,
        "http://example.com/x.exe",
        "/nowhere/x.exe",
        false,
    ));
}
