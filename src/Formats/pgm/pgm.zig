//! PGM = portable graymap (P2 ASCII / P5 binary), 1 sample per pixel -> `.g`.
//! Decoding accepts any netpbm variant, see netpbm.zig.
const std = @import("std");
const netpbm = @import("../netpbm.zig");
const Image = @import("../../root.zig");

pub const info = netpbm.info;
pub const decodeInto = netpbm.decodeInto;

/// Binary P5; color images are converted to gray.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return netpbm.encode(img, w, gpa, .g);
}
