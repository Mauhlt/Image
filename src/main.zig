/// Goals:
/// 1. Take file path - identify if file exists, if yes open file
/// 2. Identify if it is readable: (jpg, png, bmp, qoi, gif)
/// 3. Use appropriate reader to read data
/// 4. Write
const std = @import("std");
/// Readers
const readPng = @import("Readers/png.zig").readPng;
const readJpg = @import("Readers/jpg.zig").readJpg;
const readGif = @import("Readers/gif.zig").readGif;
const readBmp = @import("Readers/bmp.zig").readBmp;
const readQoi = @import("Readers/qoi.zig").readQoi;

const FileTypes = enum(u8) {
    unsupported = 0,
    qoi,
    png,
    jpg,
    tif,
    gif,
    heic,
    bmp,
};

pub fn main() !void {
    const filepath: []const u8 = "Images/BasicArt.png";

    // check that extension is supported
    const map: std.StaticStringMap(FileTypes) = .initComptime(.{
        .{ "qoi", .qoi },
        .{ "png", .png },
        .{ "jpg", .jpg },
        .{ "jpeg", .jpg },
        .{ "jpe", .jpg },
        .{ "jfif", .jpg },
        .{ "gif", .gif },
        .{ "jif", .gif },
        .{ "tif", .tif },
        .{ "tiff", .tif },
        .{ "heic", .heic },
        .{ "hif", .heic },
        .{ "paint", .paint },
        .{ "bmp", .bmp },
        .{ "dib", .bmp },
    });
    const last_period = std.mem.lastIndexOfScalar(u8, filepath, ".") orelse return error.InvalidFilePath;
    const ext = filepath[last_period + 1 .. filepath.len];
    if (!map.has(ext)) return error.InvalidFileExtension;

    // check that file exists
    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer file.close();

    // setup reader
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&read_buffer);

    // read file based on ext
    switch (ext) {
        .qoi => try readQoi(&reader.interface),
        .png => try readPng(&reader.interface),
        .jpg, .jpeg => try readJpg(&reader.interface),
        .gif, .jif => try readGif(&reader.interface),
        .bmp, .dib => try readBmp(&reader.interface),
        // .heic => try readHeic(&reader.interface),
        // .paint => try readPaint(&reader.interface),
    }
}
