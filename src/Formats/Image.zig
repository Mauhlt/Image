const std = @import("std");
const vk = @import("Vulkan");
const RGBA = @import("RGBA.zig");

width: u32,
height: u32,
pixels: []RGBA,
format: vk.Format,

pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
    gpa.free(self.pixels);
}

pub fn depth(self: *const @This()) u32 {
    const len = self.width * self.height;
    std.debug.assert(@mod(self.pixels.len, len) == 0);
    return @as(u32, @truncate(self.pixels.len)) / len;
}

// TODO: convert data order and format
