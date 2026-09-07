//! Test root.
//!
//! A Zig file whose tests should run has to be reachable from here: an import
//! that nothing references leaves that file's tests uncompiled, and the run
//! passes while testing less than it did. Watch the test *count*, not only the
//! exit status.

pub const semver = @import("semver.zig");
pub const macho = @import("macho.zig");
pub const plist = @import("plist.zig");
pub const redist = @import("redist.zig");
pub const toolchain = @import("toolchain.zig");
pub const doctor = @import("doctor.zig");
pub const layout = @import("layout.zig");
pub const env = @import("env.zig");
pub const shell = @import("shell.zig");
pub const status = @import("status.zig");
pub const catalog = @import("catalog.zig");
pub const fetch = @import("fetch.zig");
pub const pe = @import("pe.zig");
pub const teardown = @import("teardown.zig");
pub const removal = @import("removal.zig");

test {
    _ = semver;
    _ = macho;
    _ = plist;
    _ = redist;
    _ = toolchain;
    _ = doctor;
    _ = layout;
    _ = env;
    _ = shell;
    _ = status;
    _ = catalog;
    _ = fetch;
    _ = pe;
    _ = teardown;
    _ = removal;
}
