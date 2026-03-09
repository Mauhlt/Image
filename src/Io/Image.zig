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

const ImageFileType = union(enum) {
    bmp: @import("bmp.zig"),
    gif: @import("gif.zig"),
    heic: @import("heic.zig"),
    jpg: @import("jpg.zig"),
    paint: @import("paint.zig"),
    png: @import("png.zig"),
    ppm: @import("ppm.zig"),
    qoi: @import("qoi.zig"),
    tif: @import("tif.zig"),
    tga: @import("tga.zig"),
    webp: @import("webp.zig"),
};

/// 1. identifies file type with tagged union
/// 2. switches on tagged union to call correct reader
/// 3. all files return an image
pub fn read(
    io: std.Io,
    gpa: std.mem.Allocator,
    filepath: []const u8,
) !@This() {
    var file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
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

const MapImageExtToFileType: std.StaticStringMap(ImageFileType) = .initComptime(.{
    // .{ "jpeg", .jpg },
    // .{ "jpe", .jpg },
    // .{ "jfif", .jpg },
    // .{ "jif", .gif },
    // .{ "tiff", .tif },
    // .{ "hif", .heic },
    // .{ "dib", .bmp },
});

fn fromExt(filepath: []const u8) !ImageFileType {
    if (filepath.len == 0) return error.InvalidFilepath;
    const ext = std.fs.path.extension(filepath);
    const ext_enum = std.meta.stringToEnum(ImageFileType, ext[1..ext.len]) orelse
        MapImageExtToFileType.get(ext[1..ext.len]) orelse
        error.UnsupportedImageFileExt;
    return @unionInit(ImageFileType, @tagName(ext_enum), undefined);
}
