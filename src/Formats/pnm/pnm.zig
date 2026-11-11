//! PNM = "any of PBM / PGM / PPM"; the magic number tells which, see netpbm.zig.
const std = @import("std");
const netpbm = @import("../netpbm.zig");
const Image = @import("../../root.zig");

pub const info = netpbm.info;
pub const decodeInto = netpbm.decodeInto;

/// Binary P5 for gray images, P6 otherwise. PNM has no alpha: it is dropped (use PAM to keep it).
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const gray = switch (img.pixels) {
        .g, .ga => true,
        else => false,
    };
    return netpbm.encode(img, w, gpa, if (gray) .g else .rgb);
}
