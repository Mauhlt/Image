const std = @import("std");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");

/// Assumes srgb, width, height, pixels
width: u32,
height: u32,
pixels: union(BitType) {
    rgb: [*]RGB,
    rgba: [*]RGBA,
},

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
    bmp: @import("bmp.zig"),
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

/// 1. identifies file type with tagged union
/// 2. switches on tagged union to call correct reader
/// 3. all files return an image
pub fn read(
    io: std.Io,
    gpa: std.mem.Allocator,
    filepath: []const u8,
) !@This() {
    const file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const io_reader: *std.Io.Reader = &reader.interface;

    const image_file_type = try fromExt(filepath);
    return switch (image_file_type) {
        inline else => |*img| img.read(io_reader, gpa),
    };
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
//         inline else => |*img| img.read(io_writer, allo, self),
//     }
// }

const BitType = enum(u8) {
    rgb,
    rgba,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const MapImageExtToFileType: std.StaticStringMap(ImageFileEnum) = .initComptime(.{
    // .{ "jpeg", .jpg },
    // .{ "jpe", .jpg },
    // .{ "jfif", .jpg },
    // .{ "jif", .gif },
    // .{ "tiff", .tif },
    // .{ "hif", .heic },
    // .{ "dib", .bmp },
});

/// Instantiates union based on filepath extension
fn fromExt(filepath: []const u8) !ImageFile {
    if (filepath.len == 0) return error.InvalidFilepath;
    const ext = std.fs.path.extension(filepath)[1..];
    const ext_enum = std.meta.stringToEnum(ImageFileEnum, ext) orelse
        MapImageExtToFileType.get(ext) orelse
        error.UnsupportedImageFileExt;
    return @unionInit(ImageFile, @tagName(ext_enum), undefined);
}
