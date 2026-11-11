//! PAM = portable arbitrary map (P7): GRAYSCALE, RGB, BLACKANDWHITE and their _ALPHA
//! tuple types -> `.g` / `.ga` / `.rgb` / `.rgba`.
//! Decoding accepts any netpbm variant, see netpbm.zig.
const std = @import("std");
const netpbm = @import("../netpbm.zig");
const Image = @import("../../root.zig");

pub const info = netpbm.info;
pub const decodeInto = netpbm.decodeInto;

/// Keeps gray vs. color and alpha; BGR / YCbCr layouts are converted to RGB(A).
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return netpbm.encodePam(img, w, gpa);
}
