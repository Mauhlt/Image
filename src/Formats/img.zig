const std = @import("std");
const Format = @import("Vulkan").Format;
const Pixels = @import("color.zig").Pixels;

width: u32,
height: u32,
pixels: Pixels,
format: Format,

/// may create new memory
/// may copy data over
/// frees old memory
pub fn initOwned(
    width: u32,
    height: u32,
    old_pixels: Pixels,
    format: Format,
) !@This() {
    var new_img: @This() = undefined;
    new_img.width = width;
    new_img.height = height;
    new_img.format = format;
    switch (old_pixels) {
        inline else => |tag| {
            @field(new_img.pixels, @tagName(tag)) = tag;
        },
    }
}

/// only copies data
// pub fn initCopied(
//     gpa: std.mem.Allocator,
//     width: u32,
//     height: u32,
//     old_pixels: Pixels,
//     format: Format,
// ) !@This() {
//     var new_img: @This() = undefined;
//     new_img.width = width;
//     new_img.height = height;
//     new_img.format = format;
//     switch (old_pixels) {
//         .gray => |grays| {
//             const new_pixels: []GRAY = try .dupe(grays);
//             errdefer gpa.free(new_pixels);
//             new_img.pixels = .{ .gray = new_pixels };
//         },
//         .rgb16 => |rgb16s| {
//             const new_len = rgb16s.len / 3;
//             var new_pixels: RGBS_16 = try .initCapacity(gpa, new_len);
//             errdefer new_pixels.deinit(gpa);
//             for (rgb16s) |rgb16| new_pixels.appendAssumeCapacity(rgb16);
//         },
//         .rgb24 => |rgb24s| {
//             const new_len = rgb24s.len / 3;
//             var new_pixels: RGBS_24 = try .initCapacity(gpa, new_len);
//             errdefer gpa.free(new_pixels);
//             for (rgb24s) |rgb24| new_pixels.appendAssumeCapacity(rgb24);
//         },
//         .rgba => |rgbas| {
//             const new_len = rgbas.len / 4;
//             var new_pixels: RGBAS = try .initCapacity(gpa, new_len);
//             errdefer new_pixels.deinit(gpa);
//             for (rgbas) |rgba| new_pixels.appendAssumeCapacity(rgba);
//         },
//     }
// }

pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
    self.pixels.deinit(gpa);
}

pub fn depth(self: *const @This()) u32 {
    const len = self.width * self.height;
    std.debug.assert(@mod(self.pixels.len, len) == 0);
    return @as(u32, @truncate(self.pixels.len)) / len;
}
