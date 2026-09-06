//! A stand-in for Steam's `steamwebhelper.exe` that re-launches the real one
//! with `--in-process-gpu` appended.
//!
//! **Why this exists.** Steam's user interface is Chromium, and Chromium runs
//! its display compositor in a separate GPU process. Under a protium-built
//! Wine that process starts, and then nothing it composites reaches the
//! window: the client signs in, loads its library, and paints black. Moving
//! the compositor into the browser process — which is all `--in-process-gpu`
//! does — makes the window paint. `docs/steam-rendering.md` has the evidence,
//! including the control that pointed at it.
//!
//! **Why it has to be a stand-in.** The switch is Chromium's, not Steam's, and
//! `steam.exe` forwards exactly six `-cef-*` flags and silently drops
//! everything else. There is no configuration file, no environment variable and
//! no registry key that adds one. Replacing the executable is the only way in.
//!
//! This file is compiled by `build.zig` for `x86_64-windows` and embedded in
//! the protium binary, so protium ships one executable and still writes a real
//! PE into the prefix. Nothing is vendored: it is built from this source, by
//! the same `zig build` that builds everything else, with no toolchain beyond
//! the one already required.
//!
//! It is not in `src/root.zig`'s test block, and cannot be: it links against
//! `kernel32`, so it does not build for the host the tests run on. The part
//! worth pinning down — that the names it swaps between are the same ones the
//! catalogue installs to — is asserted in `catalog.zig` instead.

const std = @import("std");

/// The name protium installs this as, and the name it moves Valve's own
/// binary to. `catalog.zig` holds the same two strings and a test that they
/// agree; changing one here without the other leaves a stand-in that launches
/// itself for ever.
pub const installed_as = "steamwebhelper.exe";
pub const real_binary = "steamwebhelper-real.exe";

/// The whole point of the file.
pub const switch_added = " --in-process-gpu";

const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, buf: [*]u16, len: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreateProcessW(
    application: ?[*:0]const u16,
    command_line: ?[*:0]u16,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: BOOL,
    flags: DWORD,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u16,
    startup_info: *anyopaque,
    process_info: *anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(handle: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: DWORD) callconv(.winapi) noreturn;

// Statics rather than an allocator: this process exists to call one function
// and wait, and a failure to allocate would be one more way to break a launch.
var self_path: [1024]u16 = undefined;
var real_path: [1100:0]u16 = undefined;
var command_line: [32768:0]u16 = undefined;
var startup_info: [512]u8 align(16) = undefined;
var process_info: [64]u8 align(16) = undefined;

const suffix = std.unicode.utf8ToUtf16LeStringLiteral(switch_added);
const marker = std.unicode.utf8ToUtf16LeStringLiteral(installed_as);
const replacement = std.unicode.utf8ToUtf16LeStringLiteral(real_binary);

/// Exit statuses this file produces itself, so that a failure here is not
/// mistaken for one of Chromium's.
const exit_no_module_name = 90;
const exit_unexpected_name = 91;
const exit_command_line_too_long = 92;
const exit_spawn_failed = 93;

pub fn main() noreturn {
    // The real binary sits beside this one under a different name, so its
    // path is this one's with the name swapped. Deriving it rather than
    // hard-coding a path keeps the stand-in working in any prefix.
    const len = GetModuleFileNameW(null, &self_path, self_path.len);
    if (len == 0 or len >= self_path.len) ExitProcess(exit_no_module_name);

    const me = self_path[0..len];
    const at = lastIndexOf(me, marker) orelse ExitProcess(exit_unexpected_name);

    var w: usize = 0;
    for (me[0..at]) |c| {
        real_path[w] = c;
        w += 1;
    }
    for (replacement) |c| {
        real_path[w] = c;
        w += 1;
    }
    for (me[at + marker.len ..]) |c| {
        real_path[w] = c;
        w += 1;
    }
    real_path[w] = 0;

    // The command line is passed through unchanged with the switch appended,
    // rather than rebuilt from argv. Steam's arguments contain paths with
    // spaces, and re-quoting them is a way to break a launch for no gain —
    // Chromium's own parsing of that string is what has to keep working.
    const original = GetCommandLineW();
    var i: usize = 0;
    while (original[i] != 0) : (i += 1) {
        if (i + suffix.len + 1 >= command_line.len) ExitProcess(exit_command_line_too_long);
        command_line[i] = original[i];
    }
    for (suffix) |c| {
        command_line[i] = c;
        i += 1;
    }
    command_line[i] = 0;

    @memset(&startup_info, 0);
    @memset(&process_info, 0);
    std.mem.writeInt(u32, startup_info[0..4], startup_info.len, .little);

    // The image comes from `real_path` and the arguments from `command_line`,
    // so Chromium sees the argv it expects while running the binary it was
    // going to run anyway. Its own child processes re-exec that same image,
    // which is why the switch is added once and only to the browser process.
    if (CreateProcessW(
        &real_path,
        &command_line,
        null,
        null,
        1,
        0,
        null,
        null,
        &startup_info,
        &process_info,
    ) == 0) ExitProcess(exit_spawn_failed);

    // Steam watches this process, so it has to live as long as the one it
    // started and report the same status.
    const child: HANDLE = @ptrFromInt(std.mem.readInt(u64, process_info[0..8], .little));
    _ = WaitForSingleObject(child, 0xffff_ffff);
    var code: DWORD = 0;
    _ = GetExitCodeProcess(child, &code);
    ExitProcess(code);
}

/// The last occurrence of `needle`, searched from the end because a prefix
/// directory could legitimately contain the file's own name.
fn lastIndexOf(haystack: []const u16, needle: []const u16) ?usize {
    if (needle.len > haystack.len) return null;
    var i = haystack.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u16, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}
