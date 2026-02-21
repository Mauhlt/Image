/// Goals:
/// 1. Take file path - identify if file exists, if yes open file
/// 2. Identify if it is readable: (jpg, png, bmp, qoi, gif)
/// 3. Use appropriate reader to read data
/// 4. Write
const std = @import("std");
const testing = std.testing;
// Readers
const readPng = @import("Readers/png.zig").readPng;
const readPPM = @import("Readers/ppm.zig").readPPM;
// const readJpg = @import("Readers/jpg.zig").readJpg;
// const readGif = @import("Readers/gif.zig").readGif;
// const readBmp = @import("Readers/bmp.zig").readBmp;
// const readQoi = @import("Readers/qoi.zig").readQoi;

/// Types of Projections:
/// 1. perspective projection
/// 2. orthographic/rectilinear projection
/// 3. fisheye projection
/// - equisolid projection
/// - stereo projection
/// 4. cylindrical projection
/// 5. spherical projection
/// 6. equirectangular projection
/// 7. omnimax projection
/// 8. pinhole camera projection
/// 9. panini projection
/// https://www.youtube.com/watch?v=LE9kxUQ-l14
const FileTypes = enum(u8) {
    unsupported = 0,
    qoi,
    png,
    jpg,
    tif,
    gif,
    heic,
    bmp,
    paint,
};

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

pub fn main() !void {
    var alloc_buffer: [1 * 1024 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&alloc_buffer);

    const filepath: []const u8 = "src/Data/BasicArt.png";
    if (filepath.len == 0) return error.InvalidFilepath;

    const last_period = std.mem.lastIndexOfScalar(u8, filepath, '.') orelse
        return error.InvalidFilePath;
    const ext_str = filepath[last_period + 1 .. filepath.len];
    const ext = map.get(ext_str) orelse
        return error.InvalidFileExtension;

    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&read_buffer);

    // const image: Image = switch (ext) {
    const img = switch (ext) {
        // .qoi => try readQoi(&reader.interface),
        .png => try readPng(fba.allocator(), &reader.interface),
        // .png => try readPng(fba.allocator(), &reader.interface),
        // .jpg, .jpeg => try readJpg(&reader.interface),
        // .gif, .jif => try readGif(&reader.interface),
        // .bmp, .dib => try readBmp(&reader.interface),
        // .heic => try readHeic(&reader.interface),
        // .paint => try readPaint(&reader.interface),
        else => unreachable,
    };

    const ppm_f = try std.fs.cwd().openFile("parsed_png.ppm", .{});
    defer ppm_f.close();

    var writer_buf: [4096]u8 = undefined;
    var writer = ppm_f.writer(&writer_buf);
    const w = &writer.interface;

    // ppm = P6, width height, max value, newline
    try w.print(
        \\P6 
        \\{d} {d}
        \\255
        \\
    , .{ img.width, img.height });

    std.debug.assert(img.bit_depth == 8);
    for (0..img.height) |h| {
        for (0..img.width) |w| {}
    }
}

test {
    _ = ai_qoi;
    _ = ai_png;
    _ = ai_bmp;
    // _ = ai_jpg;
}

test "Extract Extension" {
    const filepaths = [_][]const u8{
        "HelloWorld.png",
        "Goodbye.jpeg",
        "GoodRiddance.jpg.tiff",
        "Nobody'sHome.bmp",
        "GoodLoving..bmp",
        "DoneLoving.qoi",
        "Nowhere.jpg",
        "Done.jpe",
        "Started.jfif",
        "Extractable.gif",
        "Unextractable.jif",
        "BirthdayAtTiffanys.tif",
        "FuneralAtTiffs.tiff",
        "SillyDogPhotos.heic",
        "CuteCatPics.hif",
        "CannonBall.paint",
        "WhatIsADib.dib",
        "LinkZelda.zldb",
    };
    const expected_extensions = [_]FileTypes{ .png, .jpg, .tif, .bmp, .bmp, .qoi, .jpg, .jpg, .jpg, .gif, .gif, .tif, .tif, .heic, .heic, .paint, .bmp, .unsupported };
    for (filepaths, expected_extensions) |filepath, expected_extension| {
        if (filepath.len == 0) return error.InvalidFilePath;
        const last_period = std.mem.lastIndexOfScalar(u8, filepath, '.') orelse return error.InvalidFilePath;
        // std.debug.print("Ext Str: {s}\n", .{filepath[last_period + 1 ..]});
        const ext_str = filepath[last_period + 1 .. filepath.len];
        const ext = map.get(ext_str) orelse .unsupported;
        // std.debug.print("Ext: {t}\n", .{ext});
        try testing.expect(ext == expected_extension);
    }
}
