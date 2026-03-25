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

pub fn writeRGB(self: *const @This(), w: *std.Io.Writer) !void {
    for (self.pixels) |pixel| {
        try w.writeByte(pixel.r);
        try w.writeByte(pixel.g);
        try w.writeByte(pixel.b);
    }
}

pub fn writeRGBA(self: *const @This(), w: *std.Io.Writer) !void {
    for (self.pixels) |pixel| {
        try w.writeByte(pixel.r);
        try w.writeByte(pixel.g);
        try w.writeByte(pixel.b);
        try w.writeByte(pixel.a);
    }
}

pub fn writeBGR(self: *const @This(), w: *std.Io.Writer) !void {
    for (self.pixels) |pixel| {
        try w.writeByte(pixel.b);
        try w.writeByte(pixel.g);
        try w.writeByte(pixel.r);
    }
}

pub fn writeBGRA(self: *const @This(), w: *std.Io.Writer) !void {
    for (self.pixels) |pixel| {
        try w.writeByte(pixel.b);
        try w.writeByte(pixel.g);
        try w.writeByte(pixel.r);
        try w.writeByte(pixel.a);
    }
}
