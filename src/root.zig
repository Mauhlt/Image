const std = @import("std");
const Image = @import("Formats/Image.zig");
const BMP = @import("Formats/BMP.zig");
const PNG = @import("Formats/PNG.zig");
const QOI = @import("Formats/QOI.zig");
const vk = @import("Vulkan");

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Image {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const file_len = try file.length(io);

    var mm = try file.createMemoryMap(
        io,
        .{ .len = file_len, .protection = .{ .read = true } },
    );
    defer mm.destroy(io);
    try mm.read(io);
    const raw_data = mm.memory[0..file_len];

    const image_tag = try tagFromExt(path);
    return switch (image_tag) {
        .bmp => BMP.decode(gpa, raw_data),
        .qoi => QOI.decode(gpa, raw_data),
        // .png => PNG.decode(gpa, raw_data),
        else => unreachable,
    };
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
        .qoi => QOI.encode(img, io_writer),
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
    // write qoi img
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    // ground truth
    const file = "src/Data/Read/BasicArt.bmp";
    const img = try read(io, gpa, file);
    defer img.deinit(gpa);
    std.debug.print("Img: {}\n", .{img});

    const w_file = "src/Data/Write/BasicArt.qoi";
    try write(io, w_file, &img);

    const file2 = "src/Data/Write/BasicArt.qoi";
    const img2 = try read(io, gpa, file2);
    defer img2.deinit(gpa);

    const px1 = img.pixels.rgb;
    const px2 = img2.pixels.rgb;
    const len = img.extent.width * img.extent.height * img.extent.depth;
    for (0..len) |i| {
        std.testing.expect(px1[i].eql(px2[i])) catch |err| {
            std.debug.print("Pixel: {}\n", .{i});
            std.debug.print("{any}\n", .{px1[i]});
            std.debug.print("{any}\n", .{px2[i]}); // just dead wrong
            return err;
        };
    }
}
