const std = @import("std");
const RGBA = @import("Formats/RGBA.zig");
const Image = @import("Formats/Image.zig");
const BMP = @import("Formats/BMP.zig");
const PNG = @import("Formats/PNG.zig");
// const QOI = @import("Formats/QOI.zig");
const vk = @import("Vulkan");

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Image {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const file_len = try file.length(io);
    std.debug.print("{}\n", .{file_len});

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const io_reader: *std.Io.Reader = &reader.interface;
    _ = io_reader;

    // test different ways to load the data
    const data1 = try readData(io, gpa);
    errdefer gpa.free(data1);

    const data2 = try readData(io, gpa);
    errdefer gpa.free(data2);
}

fn readData(io: std.Io, gpa: std.mem.Allocator, file: *std.fs.File) !void {
    _ = io;
    const n = 10;
    const threads = try gpa.alloc(std.Thread, n - 1);
    defer gpa.free(threads);

    for (0..n) |i| {
        threads[i] = try std.Thread.spawn(.{}, file.readPositionalAll);
    }
}

fn readData2(io: std.Io, file: *std.fs.File) !void {
    const file_len = try file.length();
    var mmap = try file.createMemoryMap(io, .{ .len = file_len });
    defer mmap.destory(io);
    mmap.read(io);
}

pub fn write(io: std.Io, path: []const u8, img: *const Image) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    const io_writer = &writer.interface;

    const image_tag = try tagFromExt(path);
    return switch (image_tag) {
        .bmp => BMP.encode(img, io_writer),
        // .qoi => QOI.encode(img, io_writer),
        else => unreachable,
    };
}

fn tagFromExt(path: []const u8) !ImageTag {
    const ext = std.Io.Dir.path.extension(path);
    return std.meta.stringToEnum(ImageTag, ext[1..ext.len]) orelse //
        mapImageTagFromExt.get(ext) orelse //
        return error.UnsupportedImageExt;
}

// const ImageTagUnion = union(enum) {
//     bmp: BMP,
//     // gif: @import("gif.zig"),
//     // heic: @import("heic.zig"),
//     // jpg: @import("jpg.zig"),
//     // paint: @import("paint.zig"),
//     // png: @import("png.zig"),
//     // ppm: @import("ppm.zig"),
//     // qoi: @import("qoi.zig"),
//     // tif: @import("tif.zig"),
//     // tga: @import("tga.zig"),
//     // webp: @import("webp.zig"),
// };
// const ImageTag = std.meta.Tag(ImageTagUnion);
const ImageTag = enum {
    bmp,
    gif,
    heic,
    jpg,
    paint,
    png,
    ppm,
    qoi,
    tif,
    tga,
    webp,
};
const mapImageTagFromExt: std.StaticStringMap(ImageTag) = .initComptime(.{
    .{ "jpeg", .jpg },
    .{ "jpe", .jpg },
    .{ "jfif", .jpg },
    .{ "jif", .gif },
    .{ "tiff", .tif },
    .{ "hif", .heic },
    .{ "dib", .bmp },
});

// test "PNG" {
//     const gpa = std.testing.allocator;
//     var threaded: std.Io.Threaded = .init(gpa, .{});
//     const io = threaded.io();
//
//     const file = "src/Data/BasicArt.png";
//     try read(io, gpa, file);
//     // try write(io, gpa, file);
// }

test "QOI" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    // ground truth
    const file = "src/Data/Read/BasicArt.bmp";
    const img = try read(io, gpa, file);
    defer img.deinit(gpa);
    try std.testing.expectEqual(img.width, 1536);
    try std.testing.expectEqual(img.height, 864);
    try std.testing.expectEqual(img.pixels.len, 1_327_104);
    try std.testing.expectEqual(img.format, .b8g8r8_srgb);
    const expected_pixel: RGBA = .{ .r = 255, .g = 201, .b = 13, .a = 255 };
    try std.testing.expectEqual(img.pixels[0].r, expected_pixel.r);
    try std.testing.expectEqual(img.pixels[0].g, expected_pixel.g);
    try std.testing.expectEqual(img.pixels[0].b, expected_pixel.b);
    try std.testing.expectEqual(img.pixels[img.pixels.len - 1].r, expected_pixel.r);
    try std.testing.expectEqual(img.pixels[img.pixels.len - 1].g, expected_pixel.g);
    try std.testing.expectEqual(img.pixels[img.pixels.len - 1].b, expected_pixel.b);
}
