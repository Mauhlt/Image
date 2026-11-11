//! PPM = portable pixmap (P3 ASCII / P6 binary), RGB -> `.rgb`.
//! Decoding accepts any netpbm variant, see netpbm.zig.
const std = @import("std");
const netpbm = @import("../netpbm.zig");
const Image = @import("../../root.zig");

pub const info = netpbm.info;
pub const decodeInto = netpbm.decodeInto;

/// Binary P6; other layouts are converted to RGB.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return netpbm.encode(img, w, gpa, .rgb);
}
