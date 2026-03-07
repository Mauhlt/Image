const std = @import("std");
const Image = @import("./Image.zig").Image2D;

pub const ImageFileType = enum {
    bmp,
    // dds,
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

pub const ImageFile = union(ImageFileType) {
    bmp: @import("./BMP.zig"),
    // dds: @import("Io/DDS.zig"),
    // gif: @import("Io/Gif.zig"),
    // heic: @import("Io/HEIC.zig"),
    // jpg: @import("Io/JPG.zig"),
    // paint: @import("Io/PAINT.zig"),
    // png: @import("Io/PNG.zig"),
    // ppm: @import("Io/PPM.zig"),
    // qoi: @import("Io/QOI.zig"),
    // tif: @import("Io/Tif.zig"),
    // tga: @import("Io/TGA.zig"),
    // webp: @import("Io/Webp.zig"),
    pub fn read(
        self: @This(),
        r: *std.Io.File.Reader,
        allo: *const std.mem.Allocator,
    ) @This() {
        return switch (self) {
            inline else => |file| file.read(r, allo),
        };
    }

    pub fn write(
        self: ImageFile,
        w: *std.Io.Writer,
        allo: *const std.mem.Allocator,
    ) void {
        switch (self) {
            inline else => |file| try file.write(w, allo),
        }
    }

    pub fn toImage(self: @This()) !Image {
        return switch (self) {
            inline else => |file| file.toImage(),
        };
    }

    pub fn copyToImage(self: @This(), allo: *const std.mem.Allocator) !Image {
        return switch (self) {
            inline else => |file| file.copyToImage(allo),
        };
    }
};

pub fn makeImageFile(image_file_type: ImageFileType) ImageFile {
    // doesnt work is needed
    return switch (image_file_type) {
        inline else => @unionInit(ImageFile, @tagName(image_file_type), .{}),
    };
}

pub const MapImageExtToFileType: std.StaticStringMap(ImageFileType) = .initComptime(.{
    // .{ "jpeg", .jpg },
    // .{ "jpe", .jpg },
    // .{ "jfif", .jpg },
    // .{ "jif", .gif },
    // .{ "tiff", .tif },
    // .{ "hif", .heic },
    // .{ "dib", .bmp },
});

pub fn extractImageFileType(filepath: []const u8) !ImageFileType {
    const last_period = std.mem.lastIndexOfScalar(u8, filepath, '.') orelse
        return error.InvalidFilePath;
    const ext_str = filepath[last_period + 1 .. filepath.len];
    const image_file_type = std.meta.stringToEnum(ImageFileType, ext_str) orelse
        MapImageExtToFileType.get(ext_str) orelse
        return error.UnsupportedImageFileExt;
    return image_file_type;
}
