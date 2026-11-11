//! PPM = portable pixmap (P3 ascii / P6 binary), RGB -> `.rgb`
const std = @import("std");
const netpbm = @import("../netpbm.zig");
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const Error = @import("../error.zig").Error;

/// Also accepts graymaps (P2 / P5) since `.pnm` maps here.
pub fn info(data: []const u8) !Info {
    return netpbm.info(data);
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    _ = scratch;
    return netpbm.decodeInto(data, inf, out);
}

/// Binary P6; other layouts are converted to RGB.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return netpbm.encode(img, w, gpa, .rgb);
}
