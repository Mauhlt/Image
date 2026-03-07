const std = @import("std");
const Image = @import("./Image.zig").Image2D;
// Read file -> load img -> close file

const ImageFileType = enum {
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

/// TODO: convert below to pointers to types (standardizes memory used by union - adds 1 misdirection cost)
pub const ImageFile = union(ImageFileType) {
    bmp: @import("bmp.zig"),
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
        io: std.Io,
        allo: *const std.mem.Allocator,
        filepath: []const u8,
    ) !@This() {
        var file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
        defer file.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const io_reader: *std.Io.Reader = &reader.interface;
        std.debug.print("Filepath: {s}\n", .{filepath});
        const image_file_type: ImageFileType = try fromExt(filepath);
        var image_file: ImageFile = switch (image_file_type) {
            inline else => @unionInit(ImageFile, @tagName(image_file_type), undefined),
        };
        switch (image_file) {
            inline else => |*im_file| im_file.* = try im_file.read(io_reader, allo),
        }
        return image_file;
    }

    pub fn write(
        self: ImageFile,
        io: std.Io,
        allo: *const std.mem.Allocator,
        filepath: []const u8,
    ) !void {
        var file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
        defer file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        const io_writer = &writer.interface;
        switch (self) {
            inline else => |*im_file| try im_file.write(io_writer, allo),
        }
    }

    pub fn toImage(self: @This()) !Image {
        return switch (self) {
            inline else => |*file| file.toImage(),
        };
    }

    pub fn copyToImage(self: @This(), allo: *const std.mem.Allocator) !Image {
        return switch (self) {
            inline else => |*file| file.copyToImage(allo),
        };
    }
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
    return std.meta.stringToEnum(ImageFileType, ext[1..ext.len]) orelse
        MapImageExtToFileType.get(ext[1..ext.len]) orelse
        error.UnsupportedImageFileExt;
}
