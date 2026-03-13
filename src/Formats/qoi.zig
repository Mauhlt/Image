const std = @import("std");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");

const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub fn read(gpa: std.mem.Allocator, data: []const u8) []u8 {
    const data: []u8 = try r.readAlloc(gpa, 100);
}
