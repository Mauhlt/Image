const std = @import("std");
/// Imports
const RGB = @import("Formats/RGB.zig");
const RGBA = @import("Formats/RGBA.zig");
/// Libraries
const vk = @import("Vulkan");
/// Image Formats
const BMP = @import("Formats/bmp.zig");
// Types
const ImageFileEnum = enum {
    bmp,
    // gif,
    // heic,
    // jpg,
    // paint,
    // png,
    // ppm,
    // qoi,
    // tif,
    // tga,
    // webp,
};
const ImageFile = union(ImageFileEnum) {
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
pub const BitType = union(enum) {
    rgb: [*]RGB,
    rgba: [*]RGBA,
};
const MapImageExtToImageFileEnum: std.StaticStringMap(ImageFileEnum) = .initComptime(.{
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
    .depth = 1, // default is 1
},
pixels: BitType, // instead of a union - maybe use []const u8 + format to identify type?
pixel_format: vk.Format,
/// Fns
fn fromExt(filepath: []const u8) !ImageFile {
    if (filepath.len == 0) return error.InvalidFilepath;
    const ext = std.fs.path.extension(filepath)[1..];
    return std.meta.stringToEnum(ImageFileEnum, ext) orelse
        MapImageExtToImageFileEnum.get(ext) orelse
        error.UnsupportedImageFileExt;
}

/// 1. identifies file type with tagged union
/// 2. switches on tagged union to call correct reader
/// 3. all files return an image
/// 4. is there a way to read the data in the format i want
pub fn read(
    io: std.Io,
    gpa: std.mem.Allocator,
    filepath: []const u8,
) !@This() {
    const file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
    defer file.close(io);

    const stat = try file.stat(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);

    const data = reader.interface.readAlloc(gpa, stat.size);
    defer gpa.free(data);

    const image_file_enum = try fromExt(filepath);
    return switch (image_file_enum) {
        .bmp => BMP.read(data, gpa),
        // .png => PNG.read(io_reader, gpa),
    };
}

/// Frees pixel data
pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
    const len = self.extent.width * self.extent.height * self.extent.depth;
    switch (self.pixels) {
        inline else => |data| gpa.free(data[0..len]),
    }
}

/// prints img data
pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    try w.print(
        "Image\nDims:\n\tWidth: {}\n\tHeight: {}\n\tDepth: {}\n\tFormat: {t}\n\t",
        .{ self.extent.width, self.extent.height, self.extent.depth, self.pixel_format },
    );
    const len = self.extent.width * self.extent.height * self.extent.depth;
    switch (self.pixels) {
        inline else => |data| {
            const first_pixel = data[0];
            const last_pixel = data[1];
            try w.print("1. {any}\n", .{first_pixel});
            try w.print("{}. {any}\n", .{ len, last_pixel });
        }
    }
}

// pub fn write(
//     self: *const @This(),
//     io: std.Io,
//     allo: std.mem.Allocator,
//     filepath: []const u8,
// ) !void {
//     var file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
//     defer file.close(io);
//
//     var write_buffer: [4096]u8 = undefined;
//     var writer = file.writer(io, &write_buffer);
//     const io_writer = &writer.interface;
//
//     const image_file_type = try fromExt(filepath);
//     switch (image_file_type) {
//         inline else => |*img| img.write(io_writer, allo, self),
//     }
// }

/// Swap from rgb to rgbas or vice versa
pub fn swap(self: *@This(), gpa: std.mem.Allocator) @This() {
    const len = self.extent.width * self.extent.height * self.extent.depth;
    const old_format = @tagName(self.pixel_format);
    var new_format_buf: [1024]u8 = undefined;
    // makes assumption that converting from old format to new format, i can append an a8 to list of image values
    switch (self.pixels) {
        .rgb => |rgbs| {
            const rgbas: []RGBA = try gpa.alloc(RGBA, len);
            for (0..len) |i| {
                const rgb = rgbs[i];
                rgbas[i] = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 0xFF };
            }
            gpa.free(rgbs);
            self.pixels = .{ .rgba = rgbas.ptr };
            // add a8
            const idx = std.mem.indexOf(u8, old_format, "_").?;
            std.debug.assert(idx < old_format.len);
            @memcpy(new_format_buf[0..idx], old_format[0..idx]);
            @memcpy(new_format_buf[idx .. idx + 2], "a8");
            @memcpy(new_format_buf[idx + 2 .. idx + 2 + old_format.len], old_format[idx..old_format.len]);
            self.pixel_format = std.meta.stringToEnum(vk.Format, "").?;
        },
        .rgba => |rgbas| {
            const rgbs: []RGB = try gpa.alloc(RGB, len);
            for (0..len) |i| {
                const rgba = rgbas[i];
                rgbs[i] = .{ .r = rgba.r, .g = rgba.g, .b = rgba.b };
            }
            gpa.free(rgbas);
            self.pixels = .{ .rgb = rgbs.ptr };
            // remove a8
            const idx = std.mem.indexOf(u8, old_format, "a8").?;
            std.debug.assert(idx <= old_format.len - 2);
            @memcpy(new_format_buf[0..idx], old_format[0..idx]);
            @memcpy(new_format_buf[idx .. old_format.len - 2], old_format[idx + 2 .. old_format.len]);
            self.pixel_format = std.meta.stringToEnum(vk.Format, new_format_buf[0 .. old_format.len - 2]).?;
        },
    }
}
