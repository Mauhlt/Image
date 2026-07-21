const std = @import("std");

pub fn timer(
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

pub fn readData(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
) ![]const u8 {
    const len = try file.length(io);
    const data = try gpa.alloc(u8, len);
    const n_bytes = try file.readPositionalAll(io, data, 0);
    if (n_bytes != len) return error.FailedToReadFile;
    return data;
}

pub fn tagFromExt(path: []const u8) !ImageTag {
    const ext = std.Io.Dir.path.extension(path);
    return std.meta.stringToEnum(ImageTag, ext[1..ext.len]) orelse //
        mapImageTagFromExt.get(ext) orelse //
        return error.UnsupportedImageExt;
}

pub const ImageTag = enum {
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

// const ImageTagUnion = union(ImageTag) {
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

pub const mapImageTagFromExt: std.StaticStringMap(ImageTag) = .initComptime(.{
    .{ "jpeg", .jpg },
    .{ "jpe", .jpg },
    .{ "jfif", .jpg },
    .{ "jif", .gif },
    .{ "tiff", .tif },
    .{ "hif", .heic },
    .{ "dib", .bmp },
});
