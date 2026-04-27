const std = @import("std");
const vk = @import("Vulkan");

// Colors
const GRAY = @import("Color.zig").GRAY;

const RGB_16 = @import("Color.zig").RGB_16;
const RGBS_16 = @import("Color.zig").RGBS_16;

const RGB_24 = @import("Color.zig").RGB_24;
const RGBS_24 = @import("Color.zig").RGBS_24;

const RGBA = @import("Color.zig").RGBA;
const RGBAS = @import("Color.zig").RGBAS;

const ColorTypes = enum {
    gray,
    rgb16,
    rgb24,
    rgba,
};
const InColorType = union(ColorTypes) { // not to be modified
    gray: []const GRAY,
    rgb16: []const RGB_16,
    rgb24: []const RGB_24,
    rgba: []const RGBA,
};
const OutColorType = union(ColorTypes) {
    gray: []GRAY,
    rgb16: RGBS_16,
    rgb24: RGBS_24,
    rgba: RGBAS,
};

width: u32,
height: u32,
pixels: OutColorType,
format: vk.Format,

/// may creates new memory
/// may copy data over
/// frees old memory
pub fn init(
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    old_pixels: InColorType,
    format: vk.Format,
) !@This() {
    var new_img: @This() = undefined;
    new_img.width = width;
    new_img.height = height;
    new_img.format = format;
    switch (old_pixels) {
        .gray => |gray| {
            new_img.pixels = .{ .gray = gray };
        },
        .rgb16 => |rgb16s| {
            var new_pixels: RGBS_16 = try .initCapacity(gpa, rgb16s.len);
            errdefer new_pixels.deinit(gpa);
            for (rgb16s) |rgb16| new_pixels.appendAssumeCapacity(rgb16);
            new_img.pixels = .{ .rgb16 = new_pixels };
            gpa.free(rgb16s);
        },
        .rgb24 => |rgb24s| {
            var new_pixels: RGBS_24 = try .initCapacity(gpa, rgb24s.len);
            errdefer new_pixels.deinit(gpa);
            for (rgb24s) |rgb24| new_pixels.appendAssumeCapacity(rgb24);
            new_img.pixels = .{ .rgb24 = new_pixels };
        },
        .rgba => |rgbas| {
            var new_pixels: RGBAS = try .initCapacity(gpa, rgbas.len);
            errdefer new_pixels.deinit(gpa);
            for (rgbas) |rgba| new_pixels.appendAssumeCapacity(gpa, rgba);
            new_img.pixels = .{ .rgba = new_pixels };
        },
    }
}

/// only copies data
pub fn copy(
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    old_pixels: InColorType,
    format: vk.Format,
) !@This() {
    var new_img: @This() = undefined;
    new_img.width = width;
    new_img.height = height;
    new_img.format = format;
    switch (old_pixels) {
        .gray => |grays| {
            const new_pixels: []GRAY = try .dupe(grays);
            errdefer gpa.free(new_pixels);
            new_img.pixels = .{ .gray = new_pixels };
        },
        .rgb16 => |rgb16s| {
            const new_len = rgb16s.len / 3;
            var new_pixels: RGBS_16 = try .initCapacity(gpa, new_len);
            errdefer new_pixels.deinit(gpa);
            for (rgb16s) |rgb16| new_pixels.appendAssumeCapacity(rgb16);
        },
        .rgb24 => |rgb24s| {
            const new_len = rgb24s.len / 3;
            var new_pixels: RGBS_24 = try .initCapacity(gpa, new_len);
            errdefer gpa.free(new_pixels);
            for (rgb24s) |rgb24| new_pixels.appendAssumeCapacity(rgb24);
        },
        .rgba => |rgbas| {
            const new_len = rgbas.len / 4;
            var new_pixels: RGBAS = try .initCapacity(gpa, new_len);
            errdefer new_pixels.deinit(gpa);
            for (rgbas) |rgba| new_pixels.appendAssumeCapacity(rgba);
        },
    }
}

pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
    switch (self.pixels) {
        .gray => |grays| gpa.free(grays),
        .rgb16 => |rgb16s| rgb16s.deinit(),
        .rgb24 => |rgb24s| rgb24s.deinit(),
        .rgba => |rgbas| rgbas.deinit(),
    }
}

pub fn depth(self: *const @This()) u32 {
    const len = self.width * self.height;
    std.debug.assert(@mod(self.pixels.len, len) == 0);
    return @as(u32, @truncate(self.pixels.len)) / len;
}
