const std = @import("std");
const vk = @import("Vulkan");
const Pixels = @import("Colors/Pixels.zig").Pixels;

/// Write data to buffer first -> decode buffer -> see if that works
const BMP = @import("Formats/bmp/bmp.zig");
// const PNG = @import("Formats/PNG.zig");
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
        .grays => |grays| {
            const len = grays.len;
            for (0..len) |i| std.debug.print("{}\n", .{grays[i]});
        },
        .rgbs => |rgbs| {
            const len = rgbs.len;
            for (0..len) |i| std.debug.print("{}\n", .{rgbs[i]});
        },
        .rgbas => |rgbas| {
            const len = rgbas.len;
            for (0..len) |i| std.debug.print("{}\n", .{rgbas[i]});
        },
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
        mapImageTagFromExt.get(ext_str) orelse
        return error.InvalidFileExtension;

    return switch (ext) {
        .bmp => try BMP.decode(args.gpa, data),
        .qoi => try QOI.decode(args.gpa, data),
        else => unreachable,
    };
}

pub fn write(
    img: *const @This(),
    io: std.Io,
    filepath: []const u8,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const io_writer = &writer.interface;

    const image_tag = try tagFromExt(filepath);
    return switch (image_tag) {
        // .bmp => BMP.encode(img, io_writer, null),
        .qoi => QOI.encode(img, io_writer),
        else => unreachable,
    };
}

// test "BMP" {
//     const gpa = std.testing.allocator;
//     var threaded: std.Io.Threaded = .init(gpa, .{});
//     const io = threaded.io();
//
//     const filepath1 = "src/Data/Read/BasicArt.bmp";
//
//     // now this works with both cwd + dir
//     var img = try read(.{
//         .gpa = gpa,
//         .io = io,
//         .filepath = filepath1,
//         .path_type = .cwd,
//     });
//     defer img.deinit(gpa);
//     // std.debug.print("{f}", .{img});
//
//     // write file
//     const filepath2 = "src/Data/Write/BasicArt.bmp";
//     try img.write(io, filepath2);
//
//     // open file 2
//     var img2 = try read(.{
//         .io = io,
//         .gpa = gpa,
//         .filepath = filepath2,
//         .path_type = .cwd,
//     });
//     defer img2.deinit(gpa);
//     // std.debug.print("{f}", .{img2});
//
//     // check that both files match
//     const tag = std.meta.activeTag(img.pixels);
//     std.debug.assert(tag == std.meta.activeTag(img2.pixels));
//     const pixels1 = img.pixels.rgb;
//     const pixels2 = img2.pixels.rgb;
//     const len = pixels1.len;
//     for (0..len) |i| {
//         const rgb1 = try pixels1.get(i);
//         const rgb2 = try pixels2.get(i);
//         try std.testing.expectEqualDeep(rgb1, rgb2);
//     }
// }

test "QOI" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();
    {
        // Tests RGB
        // Expected (6 Total): rgb, run, diff, luma, index, rgb
        const data = [_]u8{
            255, 255, 10, //
            255, 255, 10, //
            255, 255, 10, //
            253, 253, 16, //
            17, 10, 11, //
            253, 253, 30, //
            30, 30, 30, //
        };
        const rgb_pxs: Pixels = try .init(gpa, &data, .rgb, .rgbs);
        defer rgb_pxs.deinit(gpa);
        const img: @This() = .{
            .width = @truncate(rgb_pxs.rgbs.len),
            .height = 1,
            .pixels = rgb_pxs,
            .fmt = .r8g8b8_srgb,
        };
        // std.debug.print("{f}\n", .{img});
        // try img.printPixels();
        const qoi_basic_decode_rgb = "src/Data/Read/BasicDecodeRGB.qoi";
        try img.write(io, qoi_basic_decode_rgb);
        var img2 = try read(.{
            .io = io,
            .gpa = gpa,
            .filepath = qoi_basic_decode_rgb,
        });
        defer img2.deinit(gpa);
        // std.debug.print("{f}\n", .{img2});
        // try img2.printPixels();
        // std.debug.print("Pixels\n", .{});
        // for (img.pixels.rgbs, img2.pixels.rgbs) |px1, px2| {
        //     std.debug.print("{} {}\n", .{ px1, px2 });
        // }
        switch (img.pixels) {
            inline else => |pixels1, tag| {
                const pixels2 = @field(img2.pixels, @tagName(tag));
                const len = pixels1.len;
                for (0..len) |i| {
                    const px1 = pixels1[i];
                    const px2 = pixels2[i];
                    try std.testing.expectEqualDeep(px1, px2);
                }
            }
        }
    }
    {
        // Test RGBA
        // Expected (6 Total): rgba, run, diff, luma, index, rgb, rgba
        const data = [_]u8{
            255, 255, 10, 0, //
            255, 255, 10, 0, //
            255, 255, 10, 0, //
            253, 253, 16, 0, //
            17, 10, 11, 0, //
            253, 253, 30, 0, //
            30, 30, 30, 0, //
            170, 170, 170, 170, //
        };
        const rgba_pxs: Pixels = try .init(gpa, &data, .rgba, .rgbas);
        defer rgba_pxs.deinit(gpa);

        const img3: @This() = .{
            .width = @truncate(rgba_pxs.rgbas.len),
            .height = 1,
            .pixels = rgba_pxs,
            .fmt = .r8g8b8a8_srgb,
        };
        // std.debug.print("{f}\n", .{img3});
        // try img3.printPixels();

        const qoi_basic_decode_rgba = "src/Data/Read/BasicDecodeRGBA.qoi";
        try img3.write(io, qoi_basic_decode_rgba);

        var img4 = try read(.{
            .io = io,
            .gpa = gpa,
            .filepath = qoi_basic_decode_rgba,
        });
        defer img4.deinit(gpa);
        // std.debug.print("{f}\n", .{img4});
        // try img4.printPixels();

        switch (img3.pixels) {
            inline else => |pixels1, tag| {
                const pixels2 = @field(img4.pixels, @tagName(tag));
                const len = pixels1.len;
                for (0..len) |i| {
                    const px1 = pixels1[i];
                    const px2 = pixels2[i];
                    try std.testing.expectEqualDeep(px1, px2);
                }
            }
        }
    }

    // TODO: Need to fix how i read/write bmp data as it is causing issues
    // real data
    const bmp_basic_art = "src/Data/Read/BasicArt.bmp";
    const img5 = try read(.{
        .io = io,
        .gpa = gpa,
        .filepath = bmp_basic_art,
    });
    defer img5.deinit(gpa);
    std.debug.print("{f}\n", .{img5});

    // write qoi file
    const qoi_basic_art = "src/Data/Read/BasicArt.qoi";
    try img5.write(io, qoi_basic_art);

    // read qoi file
    var img6 = try read(.{
        .io = io,
        .gpa = gpa,
        .filepath = qoi_basic_art,
    });
    defer img6.deinit(gpa);
    // std.debug.print("{f}\n", .{img2});

    std.debug.assert(std.meta.activeTag(img5.pixels) == std.meta.activeTag(img6.pixels));
    const pixels1 = img5.pixels.rgbs;
    const pixels2 = img6.pixels.rgbs;
    const len = pixels1.len;
    for (0..len) |i| {
        const px1 = pixels1[i];
        const px2 = pixels2[i];
        std.testing.expectEqualDeep(px1, px2) catch |err| {
            std.debug.print("{}: {} - {}\n", .{ i, px1, px2 });
            return err;
        };
    }

    // write qoi file
    const filepath5 = "src/Data/Write/BasicArt.qoi";
    try img6.write(io, filepath5);

    // read qoi file again
    const filepath6 = "src/Data/Write/BasicArt.qoi";
    var img7 = try read(.{ .io = io, .gpa = gpa, .filepath = filepath6 });
    defer img7.deinit(gpa);

    // check acc
    std.debug.assert(std.meta.activeTag(img5.pixels) == std.meta.activeTag(img7.pixels));
    const pixels3 = img7.pixels.rgbs;
    for (0..len) |i| {
        const px1 = pixels1[i];
        const px2 = pixels3[i];
        try std.testing.expectEqualDeep(px1, px2);
    }
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
