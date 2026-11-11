//! PBM = portable bitmap (P1 ASCII / P4 binary), 1 bit per pixel, 1 = black -> `.g` (0 / 255).
//! Decoding accepts any netpbm variant, see netpbm.zig.
const std = @import("std");
const netpbm = @import("../netpbm.zig");
const Image = @import("../../root.zig");

pub const info = netpbm.info;
pub const decodeInto = netpbm.decodeInto;

/// Binary P4; pixels darker than mid gray become black.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return netpbm.encodePbm(img, w, gpa);
}
