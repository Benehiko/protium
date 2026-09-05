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

test {
    _ = semver;
    _ = macho;
    _ = plist;
    _ = redist;
    _ = toolchain;
    _ = doctor;
}
