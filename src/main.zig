/// Goals:
/// 1. Create a reader to read any img file type
/// 2. Create an image interface:
///     - contains width, height, image data, and bit size
/// 3. Create a writer that can write any
/// Reader:
///     - parse input arguments
///     - validate filepath
///     - read data
///     - convert data to image structure
/// Writer:
///     - parse input arguments
///     - validate filepath
///     - convert image structure to data
///     - write data
/// Interface:
///     - abstract fn calls to standard fns
///     - use intrusive interface
///     - Image
/// Command Line Arguments:
///   executable:
///     - image -r "filepath" - reads file at filepath
///     - image -w "filepath" - writes file at filepath
///     - image -c "filepath" "new filepath" - converts file from one image to another
///     - image -c "filepath" "ext" - converts image at filepath to new format and saves it in same directory
///   module:
///     - const Image = import("Image");
///     - Image.read("");
///     - Image.write("");
///     - Image.convert("filepath", "new_filepath");
const std = @import("std");
const testing = std.testing;
// Readers
// const BMP = @import("Parsers/BMP.zig");
// const JPG = @import("Parsers/JPG.zig");
// const QOI = @import("Parsers/QOI.zig");
// const TGA = @import("Parsers/TGA.zig");
// const DDS = @import("Parsers/DDS.zig");
// const SVG = @import("Parsers/SVG.zig");
// const WEBP = @import("Parsers/WEBP.zig");
const PNG = @import("Parsers/png.zig");
const PPM = @import("Parsers/ppm.zig");

const FileTypes = enum(u8) {
    unsupported = 0,
    qoi,
    png,
    ppm,
    jpg,
    tif,
    gif,
    heic,
    bmp,
    paint,
};

// check that extension is supported
const map: std.StaticStringMap(FileTypes) = .initComptime(.{
    .{ "jpeg", .jpg },
    .{ "jpe", .jpg },
    .{ "jfif", .jpg },
    .{ "jif", .gif },
    .{ "tiff", .tif },
    .{ "hif", .heic },
    .{ "dib", .bmp },
});

pub fn main(init: std.process.Init) !void {
    // allocate buffer
    var alloc_buffer: [1 * 1024 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&alloc_buffer);
    // choose file
    const filepath: []const u8 = "src/Data/BasicArt.png";
    if (filepath.len == 0) return error.InvalidFilepath;
    // identify file type
    const last_period = std.mem.lastIndexOfScalar(u8, filepath, '.') orelse
        return error.InvalidFilePath;
    const ext_str = filepath[last_period + 1 .. filepath.len];
    const ext = std.meta.stringToEnum(FileTypes, ext_str) orelse
        map.get(ext_str) orelse
        return error.UnsupportedFileExt;
    // open file
    const io = init.io;
    var file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
    defer file.close();
    // generate reader
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    // read correct image
    const img = switch (ext) {
        // .qoi => try readQoi(&reader.interface),
        .png => try PNG.read(fba.allocator(), &reader.interface),
        .ppm => try PPM.read(fba.allocator(), &reader.interface),
        // .jpg => try readJpg(&reader.interface),
        // .gif => try readGif(&reader.interface),
        // .bmp => try readBmp(&reader.interface),
        // .heic => try readHeic(&reader.interface),
        // .paint => try readPaint(&reader.interface),
        else => unreachable,
    };
    std.debug.print("{any}", .{img});

    // const ppm_f = try std.fs.cwd().openFile("parsed_png.ppm", .{});
    // defer ppm_f.close();
    //
    // var writer_buf: [4096]u8 = undefined;
    // var writer = ppm_f.writer(&writer_buf);
    // const w = &writer.interface;
    //
    // // ppm = P6, width height, max value, newline
    // try w.print(
    //     \\P6
    //     \\{d} {d}
    //     \\255
    //     \\
    // , .{ img.width, img.height });
    //
    // std.debug.assert(img.bit_depth == 8);
    // for (0..img.height) |h| {
    //     for (0..img.width) |w| {}
    // }
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
        "Duh.ppm",
    };
    const expected_extensions = [_]FileTypes{ .png, .jpg, .tif, .bmp, .bmp, .qoi, .jpg, .jpg, .jpg, .gif, .gif, .tif, .tif, .heic, .heic, .paint, .bmp, .unsupported, .ppm };
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
