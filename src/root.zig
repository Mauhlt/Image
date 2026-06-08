const std = @import("std");
// Color
const Image = @import("Formats/img.zig");

// Formats
const BMP = @import("Formats/BMP.zig");
// const PNG = @import("Formats/PNG.zig");
const QOI = @import("Formats/QOI.zig");
const vk = @import("Vulkan");

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Image {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const data = try readDataPositional(io, gpa, path);
    defer gpa.free(data);

    const ext_str = std.fs.path.extension(path)[1..];
    const ext = std.meta.stringToEnum(ImageTag, ext_str) orelse
        mapImageTagFromExt.get(ext_str) orelse
        return error.InvalidFileExtension;

    const img = switch (ext) {
        .bmp => try BMP.decode(gpa, data),
        // .qoi => try QOI.decode(gpa, data),
        // .grayscale => std.debug.print("Grayscale.\n", .{}),
        else => unreachable,
    };
    return img;
}

fn timer(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    n_iters: u64,
    my_fn: anytype,
) !u64 {
    const clock: std.Io.Clock = .awake;
    var time_taken: u64 = 0;
    for (0..n_iters / 2) |_| {
        const start = clock.now(io).toMilliseconds();
        const data = try my_fn(io, gpa, path);
        defer gpa.free(data);
        const end = clock.now(io).toMilliseconds();
        time_taken += @intCast(end - start);
    }
    for (0..n_iters / 2) |_| {
        const start = clock.now(io).toMilliseconds();
        const data = try my_fn(io, gpa, path);
        defer gpa.free(data);
        const end = clock.now(io).toMilliseconds();
        time_taken += @intCast(end - start);
    }
    return time_taken;
}

fn readDataPositional(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const len = try file.length(io);
    const data = try gpa.alloc(u8, len);
    errdefer gpa.free(data);

    const n = (std.Thread.getCpuCount() catch 2) - 1;
    const threads = try gpa.alloc(std.Thread, n);
    defer gpa.free(threads);

    const chunk_size = if (n > 1) (len / n) - @mod(len / n, 64) else len;

    const work_results = try gpa.alloc(WorkResult, n);
    defer gpa.free(work_results);
    @memset(work_results, .{});

    const work_items = try gpa.alloc(Work, n);
    defer gpa.free(work_items);
    for (0..n) |i| {
        work_items[i] = .{
            .file = file,
            .io = io,
            .offset = i * chunk_size,
            .data = data[i * chunk_size ..][0..chunk_size],
            .result = &work_results[i],
        };
    }

    for (0..n - 1) |i|
        threads[i] = try std.Thread.spawn(.{}, readPositional, .{&work_items[i]});
    threads[n - 1] = try std.Thread.spawn(.{}, readPositional, .{&work_items[n - 1]});
    for (0..n) |i| threads[i].join();
    for (work_items) |w| if (w.result.err) |e| return e;

    return data;
}

const WorkResult = struct {
    err: ?anyerror = null,
};

const Work = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    data: []u8,
    result: *WorkResult,
};

fn readPositional(work: *Work) void {
    _ = work.file.readPositionalAll(work.io, work.data, work.offset) catch |err| {
        work.result.err = err;
        return;
    };
}

fn readDataMmap(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const file_len = try file.length(io);
    var mmap = try file.createMemoryMap(io, .{
        .len = file_len,
        .offset = 0,
        .protection = .{ .read = true },
    });
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
        .bmp => BMP.encode(img, io_writer, null),
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

    // open file 1
    // std.debug.print("File 1", .{});
    const file = "src/Data/Read/BasicArt.bmp";
    var img = try read(io, gpa, file);
    defer img.deinit(gpa);
    // std.debug.print("{f}", .{img});

    // write file
    try write(io, "src/Data/Write/BasicArt.bmp", &img);

    // open file 2
    // std.debug.print("\nFile 2", .{});
    const file2 = "src/Data/Write/BasicArt.bmp";
    var img2 = try read(io, gpa, file2);
    defer img2.deinit(gpa);
    // std.debug.print("{f}", .{img2});

    // check that both files match
    const tag = std.meta.activeTag(img.pixels);
    std.debug.assert(tag == std.meta.activeTag(img2.pixels));
    const pixels1 = img.pixels.rgb;
    const pixels2 = img2.pixels.rgb;
    const len = pixels1.len;
    for (0..len) |i| {
        try std.testing.expectEqualDeep(pixels1[i], pixels2[i]);
    }
}

// test "QOI" {
//     const gpa = std.testing.allocator;
//     var threaded: std.Io.Threaded = .init(gpa, .{});
//     const io = threaded.io();
//
//     // read bmp file
//     const file = "src/Data/Read/BasicArt.bmp";
//     var img = try read(io, gpa, file);
//     defer img.deinit(gpa);
//
//     // write qoi file
//     try write(io, "src/Data/Read/BasicArt.qoi", &img);
//
//     // read qoi file
//     const file2 = "src/Data/Read/BasicArt.qoi";
//     var img2 = try read(io, gpa, file2);
//     defer img2.deinit(gpa);
//
//     // write qoi file
//     try write(io, "src/Data/Write/BasicArt.qoi", &img);
//
//     // read qoi file again
//     const file3 = "src/Data/Write/BasicArt.qoi";
//     var img3 = try read(io, gpa, file3);
//     defer img3.deinit(gpa);
//
//     std.debug.assert(std.meta.activeTag(img.pixels) == std.meta.activeTag(img2.pixels));
//     std.debug.assert(std.meta.activeTag(img.pixels) == std.meta.activeTag(img3.pixels));
//     const pixels1 = img.pixels.rgb;
//     const pixels2 = img2.pixels.rgb;
//     const pixels3 = img3.pixels.rgb;
//     for (pixels1, pixels2, pixels3) |px1, px2, px3| {
//         try std.testing.expectEqualDeep(px1, px2);
//         try std.testing.expectEqualDeep(px1, px3);
//     }
// }

// test "PPM" {}

// test "PNG" {}

// test "TGA" {}

// test "WEBP" {}

// test "GIF" {}

// test "Convert Image Types" {}
