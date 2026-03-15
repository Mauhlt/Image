const std = @import("std");
const Image = @import("Formats/Image.zig");
const BMP = @import("Formats/BMP.zig");
const PNG = @import("Formats/PNG.zig");
const vk = @import("Vulkan");

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void { // !Image {
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
        // .bmp => BMP.decode(gpa, raw_data),
        .png => PNG.decode(gpa, raw_data),
        else => unreachable,
    };
}

pub fn write(io: std.Io, gpa: std.mem.Allocator, path: []const u8, img: Image) !void {
    _ = gpa;
    _ = img;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);

    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    const io_writer = &writer.interface;
    _ = io_writer;
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

test "PNG" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    const file = "src/Data/BasicArt.png";
    try read(io, gpa, file);
}

// test "Loading Images" {
//     const gpa = std.testing.allocator;
//
//     // still slower on mt mode - why?
//     var threaded: std.Io.Threaded = .init(gpa, .{});
//     const io = threaded.io();
//
//     // const files = [_][]const u8{"src/Data/BasicArt.bmp"}; // , "src/Data/BasicArt.png" };
//     const widths = [_]u32{1536}; // , 100 };
//     const heights = [_]u32{864}; // , 100 };
//     const formats = [_]vk.Format{.b8g8r8_srgb}; // , .r8g8b8_srgb };
//     for (files, widths, heights, formats) |file, width, height, format| {
//         const img = try read(io, gpa, file);
//         defer img.deinit(gpa);
//         try std.testing.expectEqual(img.extent.width, width);
//         try std.testing.expectEqual(img.extent.height, height);
//         // try std.testing.expectEqual(img.extent.depth, 1);
//         try std.testing.expectEqual(img.pixel_format, format);
//     }
// }
