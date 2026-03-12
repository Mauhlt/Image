const std = @import("std");
const vk = @import("Vulkan");
/// Color Structs
pub const RGB = struct { r: u8, g: u8, b: u8 };
pub const RGBA = struct { r: u8, g: u8, b: u8, a: u8 };
pub const BitType = union(enum) {
    rgb: [*]RGB,
    rgba: [*]RGBA,
};
/// Image Formats
const BMP = @import("bmp.zig");
const PNG = @import("png.zig");
const ImageFormat = union(enum) {
    bmp: BMP,
    // gif: @import("gif.zig"),
    // heic: @import("heic.zig"),
    // jpg: @import("jpg.zig"),
    // paint: @import("paint.zig"),
    // png: @import("png.zig"),
    // ppm: @import("ppm.zig"),
    // qoi: @import("qoi.zig"),
    // tif: @import("tif.zig"),
    // tga: @import("tga.zig"),
    // webp: @import("webp.zig"),
};
const ImageFormatEnum = std.meta.Tag(ImageFormat);
const MapImageExtToImageFormatEnum: std.StaticStringMap(ImageFormatEnum) = .initComptime(.{
    // .{ "jpeg", .jpg },
    // .{ "jpe", .jpg },
    // .{ "jfif", .jpg },
    // .{ "jif", .gif },
    // .{ "tiff", .tif },
    // .{ "hif", .heic },
    // .{ "dib", .bmp },
});
/// Fields
extent: vk.Extent3D = .{
    .width = 0,
    .height = 0,
    .depth = 1,
},
pixels: BitType,
pixel_format: vk.Format,
// Methods:
/// Frees pixel data
pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
    const len = self.extent.width * self.extent.height * self.extent.depth;
    switch (self.pixels) {
        inline else => |data| gpa.free(data[0..len]),
    }
}
