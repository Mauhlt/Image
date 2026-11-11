//! PGM = portable graymap (P2 ascii / P5 binary), 1 sample per pixel -> `.g`
const std = @import("std");
const netpbm = @import("../netpbm.zig");
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const Error = @import("../error.zig").Error;

pub fn info(data: []const u8) !Info {
    const inf = try netpbm.info(data);
    if (inf.tag != .g) return Error.UnexpectedSignature;
    return inf;
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    _ = scratch;
    return netpbm.decodeInto(data, inf, out);
}

/// Binary P5; color images are converted to gray.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return netpbm.encode(img, w, gpa, .g);
}
