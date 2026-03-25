const std = @import("std");
const RGBA = @import("Formats/RGBA.zig");
const Image = @import("Formats/Image.zig");
const BMP = @import("Formats/BMP.zig");
const PNG = @import("Formats/PNG.zig");
// const QOI = @import("Formats/QOI.zig");
const vk = @import("Vulkan");

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void { // !Image {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const data = try readDataPositional(io, gpa, file);
    gpa.free(data);
    // const n_iters = 1;
    // const time1 = try timer(io, gpa, n_iters, readDataPositional, file);
    // std.debug.print("{}\n", .{time1});
    // const time2 = try timer(io, gpa, n_iters, readDataMmap, file);
    // std.debug.print("{}\n{}\n", .{ time1, time2 });
}

fn timer(
    io: std.Io,
    gpa: std.mem.Allocator,
    n_iters: u64,
    my_fn: anytype,
    file: std.Io.File,
) !u64 {
    const clock: std.Io.Clock = .awake;
    var time_taken: u64 = 0;
    for (0..n_iters) |_| {
        const timestamp = clock.now(io);
        const start = timestamp.toMilliseconds();
        const data = try my_fn(io, gpa, file);
        defer gpa.free(data);
        const end = timestamp.toMilliseconds();
        time_taken += (end - start);
    }
    return time_taken / n_iters;
}

const WorkResult = struct {
    err: ?anyerror = null,
};

const Work = struct {
    io: std.Io,
    file: std.Io.File,
    start: u64,
    len: u64,
    result: *WorkResult,
};

fn readDataPositional(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
) ![]u8 {
    const len = try file.length(io);
    const data = try gpa.alloc(u8, len);
    errdefer gpa.free(data);

    const n = (std.Thread.getCpuCount() catch 2) - 1;
    const threads = try gpa.alloc(std.Thread, n);
    defer gpa.free(threads);

    const chunk_size = if (n > 1) (len / n) - @mod(len / n, 64) else len;

    const results = try gpa.alloc(WorkResult, n);
    defer gpa.free(results);
    @memset(results, .{});

    const work_items = try gpa.alloc(Work, n);
    defer gpa.free(work_items);
    for (0..n) |i| {
        work_items[i] = .{
            .file = file,
            .io = io,
            .byte_start = j,
            .byte_len = data_per_thread,
            .result = 0,
        };
    }

    var j: usize = 0;
    for (0..n - 1) |i| {
        threads[i] = try std.Thread.spawn(
            .{},
            file.readPositionalAll,
            .{ io, data[j..][0..data_per_thread], j },
        );
        j += data_per_thread;
    }
    threads[n - 1] = try std.Thread.spawn(
        .{},
        file.readPositionalAll,
        .{ io, data[j..data.len], j },
    );

    for (0..n) |i| threads[i].join();

    return data;
}

fn readDataMmap(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const file_len = try file.length();
    var mmap = try file.createMemoryMap(io, .{ .len = file_len });
    defer mmap.destroy(io);
    try mmap.read(io);
    return gpa.dupe(u8, mmap.memory[0..file_len]);
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

test "BMP" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();
    const file = "src/Data/Read/BasicArt.bmp";
    try read(io, gpa, file);
}

test "QOI" {
    // const gpa = std.testing.allocator;
    // var threaded: std.Io.Threaded = .init(gpa, .{});
    // const io = threaded.io();
    //
    // // ground truth
    // const file = "src/Data/Read/BasicArt.bmp";
    // const img = try read(io, gpa, file);
    // defer img.deinit(gpa);
    // try std.testing.expectEqual(img.width, 1536);
    // try std.testing.expectEqual(img.height, 864);
    // try std.testing.expectEqual(img.pixels.len, 1_327_104);
    // try std.testing.expectEqual(img.format, .b8g8r8_srgb);
    // const expected_pixel: RGBA = .{ .r = 255, .g = 201, .b = 13, .a = 255 };
    // try std.testing.expectEqual(img.pixels[0].r, expected_pixel.r);
    // try std.testing.expectEqual(img.pixels[0].g, expected_pixel.g);
    // try std.testing.expectEqual(img.pixels[0].b, expected_pixel.b);
    // try std.testing.expectEqual(img.pixels[img.pixels.len - 1].r, expected_pixel.r);
    // try std.testing.expectEqual(img.pixels[img.pixels.len - 1].g, expected_pixel.g);
    // try std.testing.expectEqual(img.pixels[img.pixels.len - 1].b, expected_pixel.b);
}
