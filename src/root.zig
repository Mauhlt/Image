const std = @import("std");
const vk = @import("Vulkan");
const Pixels = @import("Colors/Pixels.zig").Pixels;

const BMP = @import("Formats/bmp/bmp.zig");
const JPG = @import("Formats/jpg/jpg.zig");
const PGM = @import("Formats/pgm/pgm.zig");
const PNG = @import("Formats/png/png.zig");
const PPM = @import("Formats/ppm/ppm.zig");
const QOI = @import("Formats/qoi/qoi.zig");

// misc
const ImageTag = @import("misc.zig").ImageTag;
const tagFromExt = @import("misc.zig").tagFromExt;
const mapImageTagFromExt = @import("misc.zig").mapImageTagFromExt;
const readData = @import("misc.zig").readData;

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

pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
    self.pixels.deinit(gpa);
}

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    try w.print("\nImage:\n", .{});
    try w.print("Width: {}\n", .{self.width});
    try w.print("Height: {}\n", .{self.height});
    switch (self.pixels) {
        inline else => |data| try w.print("# of Pixels: {}\n", .{data.len}),
    }
    try w.print("Format: {t}\n", .{self.fmt});
}

pub fn printPixels(self: *const @This()) !void {
    switch (self.pixels) {
        inline else => |data| {
            for (data) |datum| std.debug.print("{}\n", .{datum});
        }
    }
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

    const data = try readData(args.io, args.gpa, file);
    defer args.gpa.free(data);

    const ext_str = std.fs.path.extension(args.filepath)[1..];
    const ext = std.meta.stringToEnum(ImageTag, ext_str) orelse
        mapImageTagFromExt.get(ext_str) orelse {
        if (@import("builtin").mode == .debug) {
            std.debug.print("Invalid Extension: {s}\n", .{ext_str});
        }
        return error.InvalidFileExtension;
    };
    std.debug.print("{s}\n", .{@tagName(ext)});

    return switch (ext) {
        .bmp => BMP.decode(args.gpa, data),
        .jpg => JPG.decode(args.gpa, data),
        .png => PNG.decode(args.gpa, data),
        .pgm => PGM.decode(args.gpa, data),
        .ppm => PPM.decode(args.gpa, data),
        .qoi => QOI.decode(args.gpa, data),
        else => {
            std.debug.print("{s}\n", .{@tagName(ext)});
            return error.Unsupported;
        },
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
        .bmp => BMP.encode(img, io_writer),
        .jpg => JPG.encode(img, io_writer, gpa),
        .png => PNG.encode(img, io_writer, gpa),
        .pgm => PGM.encode(img, io_writer),
        .ppm => PPM.encode(img, io_writer),
        .qoi => QOI.encode(img, io_writer),
        else => unreachable,
    };
}

fn extractFilename(name: []const u8) ![]const u8 {
    const ind = std.mem.indexOfScalar(u8, name, '.') orelse return error.InvalidName;
    return name[0..ind];
}

fn checkImgsMatch(img1: *const @This(), img2: *const @This()) !void {
    const tag1 = std.meta.activeTag(img1.pixels);
    const tag2 = std.meta.activeTag(img2.pixels);
    std.debug.assert(tag1 == tag2);
    const len = img1.pixels.bgrs.len;
    for (0..len) |i| {
        const bgr1 = img1.pixels.bgrs[i];
        const bgr2 = img2.pixels.bgrs[i];
        try std.testing.expectEqualDeep(bgr1, bgr2);
    }
}

test "Images" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    const read_filepaths = [_][]const u8{
        "src/Data/Read/BasicArt.bmp",
        "src/Data/Read/BasicArt.jpg",
        // "src/Data/Read/BasicArt.pgm",
        "src/Data/Read/BasicArt.png",
        "src/Data/Read/BasicArt.ppm",
        "src/Data/Read/BasicArt.qoi",
    };
    const write_filepaths = [_][]const u8{
        "src/Data/Write/BasicArt.bmp",
        "src/Data/Write/BasicArt.jpg",
        // "src/Data/Write/BasicArt.pgm",
        "src/Data/Write/BasicArt.png",
        "src/Data/Write/BasicArt.ppm",
        "src/Data/Write/BasicArt.qoi",
    };
    const len = read_filepaths.len;
    for (0..len) |i| {
        const read_filepath = read_filepaths[i];
        const write_filepath = write_filepaths[i];

        var img1 = try read(.{
            .gpa = gpa,
            .io = io,
            .filepath = read_filepath,
            .path_type = .cwd,
        });
        defer img1.deinit(gpa);
        if (@import("builtin").mode == .debug) std.debug.print("{f}", .{img1});

        try img1.write(io, gpa, write_filepath);

        var img2 = try read(.{
            .io = io,
            .gpa = gpa,
            .filepath = write_filepath,
            .path_type = .cwd,
        });
        defer img2.deinit(gpa);

        try checkImgsMatch(&img1, &img2);
    }
}

test "QOI" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    // 6 Total
    const datas = [_][]const u8{
        &.{[_]u8{
            255, 255, 10, // rgb
            255, 255, 10, //
            255, 255, 10, // run (1)
            253, 253, 8, // diff
            17, 10, 17, // luma
            255, 255, 10, // index
            30, 30, 30, // rgb
        }},
        &.{[_]u8{
            255, 255, 10, 0, // rgba
            255, 255, 10, 0, //
            255, 255, 10, 0, // run 1
            253, 253, 8, 0, // diff
            17, 10, 17, 0, // luma
            255, 255, 10, 0, // index
            30, 30, 30, 0, // rgb
            170, 170, 170, 170, // rgba
        }},
    };
    const pixel_tags = [_]Pixels.PixelTag{ .rgbs, .rgbas };
    const read_filepaths = [_][]const u8{
        "src/Data/Read/BasicDecodeRGB.qoi",
        "src/Data/Read/BasicDecodeRGBA.qoi",
    };
    const write_filepaths = [_][]const u8{
        "src/Data/Write/BasicDecodeRGB.qoi",
        "src/Data/Write/BasicDecodeRGBA.qoi",
    };
    for (0..2) |i| {
        const pxs = try .init(pixel_tags[i], gpa, &datas[i]);
        defer pxs.deinit(gpa);
        const img1 = read(.{
            .io = io,
            .filepath = read_filepaths[i],
            .gpa = gpa,
        });
        defer img1.deinit(gpa);
        if (@import("builtin").mode == .debug) std.debug.print("{f}\n", .{img1});
        try img1.write(io, gpa, write_filepaths[i]);
        const img2 = try read(.{ .io = io, .gpa = gpa, .filepath = write_filepaths[i] });
        defer img2.deinit(gpa);
        if (@import("builtin").mode == .debug) std.debug.print("{f}\n", .{img1});
        try checkImgsMatch(&img1, &img2);
    }
}

test "Everything" {
    _ = @import("Colors/test.zig");
}
