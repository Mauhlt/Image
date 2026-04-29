const std = @import("std");
const Format = @import("Vulkan").Format;
// Colors
const GRAY = @import("color.zig").GRAY;
const RGB = @import("color.zig").RGB;
const RGBA = @import("color.zig").RGBA;
const Pixels = @import("color.zig").Pixels;

width: u32,
height: u32,
pixels: Pixels,
format: Format,

/// always creates new memory
pub fn copy(img: *const @This(), gpa: std.mem.Allocator) !void { // !@This() {
    var pixels: Pixels = undefined;
    switch (img.pixels) {
        .gray => |old_gray| {
            var new_gray: std.ArrayList(GRAY) = try .initCapacity(gpa, old_gray.items.len);
            errdefer new_gray.deinit(gpa);
            new_gray.appendSliceAssumeCapacity(old_gray.items);
            pixels = .{ .gray = new_gray };
        },
        .rgb => |old_rgb| {
            var new_rgb: std.MultiArrayList(RGBA) = try .initCapacity(gpa, old_rgb.items.len);
            errdefer new_rgb.deinit(gpa);
            const slice = new_rgb.slice();
            std.debug.print("Slice: {}\n", .{slice});
        },
        .rgba => |old_rgba| {
            var new_rgba: std.MultiArrayList(RGBA) = try .initCapacity(gpa, old_rgba.items.len);
            errdefer new_rgba.deinit(gpa);
            const slice = new_rgba.slice();
            std.debug.print("Slice: {}\n", .{slice});
        },
    }
    // return .{
    //     .width = img.width,
    //     .height = img.height,
    //     .pixels = 1, // pixels
    //     .format = img.format,
    // };
}

pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
    self.*.pixels.deinit(gpa);
}
