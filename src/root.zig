const std = @import("std");
const vk = @import("Vulkan");
const Pixels = @import("Colors/Pixels.zig").Pixels;

const BMP = @import("Formats/BMP.zig");
// const PNG = @import("Formats/PNG.zig");
const QOI = @import("Formats/QOI.zig");

width: u32,
height: u32,
pixels: Pixels,
fmt: vk.Format,

pub fn copy(img: *const @This(), gpa: std.mem.Allocator) !@This() {
    const pixels = blk: switch (img.pixels) {
        inline else => |data, tag| {
            const new_data = try gpa.dupe(@TypeOf(data[0]), data);
            errdefer gpa.free(new_data);
            break :blk @unionInit(Pixels, @tagName(tag), new_data);
        }
    };
    return .{
        .width = img.width,
        .height = img.height,
        .pixels = pixels,
        .fmt = img.fmt,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.pixels.deinit(gpa);
}

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    try w.print("\nImage:\n", .{});
    try w.print("Width: {}\n", .{self.width});
    try w.print("Height: {}\n", .{self.height});
    switch (self.pixels) {
        inline else => |tag| try w.print("# of Pixels: {}\n", .{tag.slice.len}),
    }
    switch (self.pixels) {
        inline else => |tag| try w.print("Pixel 1: {}\n", .{tag.slice[0]}),
    }
    try w.print("Format: {t}\n", .{self.fmt});
}

const PathType = enum(u8) {
    cwd, // path = path from cwd/terminal to file
    dir, // path = path from starting dir to file
    abs, // path = abs path from root to file
};

const ReadArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir = undefined,
    filepath: []const u8,
    path_type: PathType = .cwd,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try w.print("Dir: {}\n", .{self.dir});
        try w.print("Path: {s}\n", .{self.path});
        try w.print("Path Type: {t}\n", .{self.path_type});
    }
};

pub fn read(args: ReadArgs) !@This() {
    var file = try switch (args.path_type) {
        .abs => std.Io.Dir.openFileAbsolute(args.io, args.filepath, .{ .mode = .read_only }),
        .cwd => std.Io.Dir.cwd().openFile(args.io, args.filepath, .{ .mode = .read_only }),
        .dir => args.dir.openFile(args.io, args.filepath, .{ .mode = .read_only }),
    };
    defer file.close(args.io);

    const data = try readDataPositional(args.io, args.gpa, file);
    defer args.gpa.free(data);

    const ext_str = std.fs.path.extension(args.filepath)[1..];
    const ext = std.meta.stringToEnum(ImageTag, ext_str) orelse
        mapImageTagFromExt.get(ext_str) orelse
        return error.InvalidFileExtension;

    return switch (ext) {
        .bmp => try BMP.decode(args.gpa, data),
        // .qoi => try QOI.decode(gpa, data),
        // .grayscale => std.debug.print("Grayscale.\n", .{}),
        else => unreachable,
    };
}

pub fn write(
    img: *const @This(),
    io: std.Io,
    gpa: std.mem.Allocator,
    filepath: []const u8,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const io_writer = &writer.interface;

    const image_tag = try tagFromExt(filepath);
    return switch (image_tag) {
        .bmp => BMP.encode(img, io_writer, null),
        .qoi => QOI.encode(gpa, img, io_writer, null),
        else => unreachable,
    };
}

fn timer(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    n_iters: u64,
    my_fn: anytype,
) !u64 {
    const clock: std.Io.Clock = .awake;
    var time_taken: f64 = 0;
    const div: f64 = 1 / n_iters;
    for (0..n_iters) |_| {
        const start = clock.now(io).toMilliseconds();
        const data = try my_fn(io, gpa, path);
        defer gpa.free(data);
        const end = clock.now(io).toMilliseconds();
        time_taken += (@as(f64, @floatFromInt(@as(u64, @intCast((end - start))))) * div);
    }
    return time_taken;
}

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

fn readDataMmap(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
) ![]u8 {
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

fn tagFromExt(path: []const u8) !ImageTag {
    const ext = std.Io.Dir.path.extension(path);
    return std.meta.stringToEnum(ImageTag, ext[1..ext.len]) orelse //
        mapImageTagFromExt.get(ext) orelse //
        return error.UnsupportedImageExt;
}

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

// const ImageTagUnion = union(ImageTagUnion) {
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

    const filepath1 = "src/Data/Read/BasicArt.bmp";

    // now this works with both cwd + dir
    var img = try read(.{
        .gpa = gpa,
        .io = io,
        .filepath = filepath1,
        .path_type = .cwd,
    });
    defer img.deinit(gpa);
    // std.debug.print("{f}", .{img});

    // write file
    const filepath2 = "src/Data/Write/BasicArt.bmp";
    try img.write(io, gpa, filepath2);

    // open file 2
    var img2 = try read(.{
        .io = io,
        .gpa = gpa,
        .filepath = filepath2,
        .path_type = .cwd,
    });
    defer img2.deinit(gpa);
    // std.debug.print("{f}", .{img2});

    // check that both files match
    const tag = std.meta.activeTag(img.pixels);
    std.debug.assert(tag == std.meta.activeTag(img2.pixels));
    const pixels1 = img.pixels.rgb;
    const pixels2 = img2.pixels.rgb;
    const len = pixels1.slice.len;
    for (0..len) |i| {
        try std.testing.expectEqualDeep(pixels1.slice[i], pixels2.slice[i]);
    }
}

test "QOI" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    // read bmp file
    const filepath1 = "src/Data/Read/BasicArt.bmp";
    var img = try read(.{
        .io = io,
        .gpa = gpa,
        .filepath = filepath1,
    });
    defer img.deinit(gpa);

    // write qoi file
    const filepath2 = "src/Data/Read/BasicArt.qoi";
    try img.write(io, gpa, filepath2);

    // // read qoi file
    // var img2 = try read(.{
    //     .io = io,
    //     .gpa = gpa,
    //     .filepath = filepath2,
    // });
    // defer img2.deinit(gpa);
    //
    // // write qoi file
    // const filepath3 = "src/Data/Write/BasicArt.qoi";
    // try img.write(io, gpa, filepath3);
    //
    // // read qoi file again
    // const filepath4 = "src/Data/Write/BasicArt.qoi";
    // var img3 = try read(.{ .io = io, .gpa = gpa, .filepath = filepath4 });
    // defer img3.deinit(gpa);
    //
    // std.debug.assert(std.meta.activeTag(img.pixels) == std.meta.activeTag(img2.pixels));
    // std.debug.assert(std.meta.activeTag(img.pixels) == std.meta.activeTag(img3.pixels));
    // const pixels1 = img.pixels.rgb.slice;
    // const pixels2 = img2.pixels.rgb.slice;
    // const pixels3 = img3.pixels.rgb.slice;
    // for (pixels1, pixels2, pixels3) |px1, px2, px3| {
    //     try std.testing.expectEqualDeep(px1, px2);
    //     try std.testing.expectEqualDeep(px1, px3);
    // }
}

test "PPM" {}

test "PNG" {}

test "TGA" {}

test "WEBP" {}

test "GIF" {}

test "Convert Image Types" {}

test "Everything" {
    _ = @import("Colors/test.zig");
}
