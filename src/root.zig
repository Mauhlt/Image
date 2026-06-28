const std = @import("std");
const vk = @import("Vulkan");
const Pixels = @import("Colors/Pixels.zig").Pixels;

const BMP = @import("Formats/bmp/bmp.zig");
// const PNG = @import("Formats/PNG.zig");
const QOI = @import("Formats/qoi/qoi.zig");

// misc
const ImageTag = @import("misc.zig").ImageTag;
const tagFromExt = @import("misc.zig").tagFromExt;
const mapImageTagFromExt = @import("misc.zig").mapImageTagFromExt;
const readDataPositional = @import("misc.zig").readDataPositional;

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
        .qoi => try QOI.decode(args.gpa, data),
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
    _ = gpa;
    var file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const io_writer = &writer.interface;

    const image_tag = try tagFromExt(filepath);
    return switch (image_tag) {
        .bmp => BMP.encode(img, io_writer, null),
        // .qoi => QOI.encode(gpa, img, io_writer, null),
        else => unreachable,
    };
}

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
    const len = pixels1.len;
    for (0..len) |i| {
        const rgb1 = try pixels1.get(i);
        const rgb2 = try pixels2.get(i);
        try std.testing.expectEqualDeep(rgb1, rgb2);
    }
}

test "QOI" {
    // const gpa = std.testing.allocator;
    // var threaded: std.Io.Threaded = .init(gpa, .{});
    // const io = threaded.io();
    //
    // // read bmp file
    // const filepath1 = "src/Data/Read/BasicArt.bmp";
    // var img = try read(.{
    //     .io = io,
    //     .gpa = gpa,
    //     .filepath = filepath1,
    // });
    // defer img.deinit(gpa);
    //
    // // write qoi file
    // const filepath2 = "src/Data/Read/BasicArt.qoi";
    // try img.write(io, gpa, filepath2);

    // read qoi file
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
    _ = @import("Formats/test.zig");
}
