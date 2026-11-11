const std = @import("std");

pub const ImageTag = enum {
    bmp,
    gif,
    heic,
    jpg,
    paint,
    pgm,
    png,
    ppm,
    qoi,
    tif,
    tga,
    webp,
};

/// Extra spellings that map onto an `ImageTag` (looked up without the leading '.').
pub const mapImageTagFromExt: std.StaticStringMap(ImageTag) = .initComptime(.{
    .{ "jpeg", .jpg },
    .{ "jpe", .jpg },
    .{ "jfif", .jpg },
    .{ "jif", .gif },
    .{ "tiff", .tif },
    .{ "hif", .heic },
    .{ "dib", .bmp },
    .{ "pnm", .ppm },
});

/// "foo/bar.JPEG" -> .jpg
pub fn tagFromExt(path: []const u8) !ImageTag {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return error.InvalidFileExtension;
    var buf: [8]u8 = undefined;
    if (ext.len - 1 > buf.len) return error.InvalidFileExtension;
    const lower = std.ascii.lowerString(&buf, ext[1..]);
    return std.meta.stringToEnum(ImageTag, lower) orelse
        mapImageTagFromExt.get(lower) orelse
        error.InvalidFileExtension;
}

/// Reads the whole file into `buf`, growing it only when needed.
/// Reusing `buf` across many files avoids one allocation per file.
pub fn readFileInto(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
    buf: *std.ArrayList(u8),
) ![]const u8 {
    const len: usize = @intCast(try file.length(io));
    buf.clearRetainingCapacity();
    try buf.ensureTotalCapacity(gpa, len);
    buf.items.len = len;
    const n_bytes = try file.readPositionalAll(io, buf.items, 0);
    if (n_bytes != len) return error.FailedToReadFile;
    return buf.items;
}

pub fn timer(
    io: std.Io,
    n_iters: u64,
    ctx: anytype,
    comptime func: anytype,
) !f64 {
    const clock: std.Io.Clock = .awake;
    const start = clock.now(io).toNanoseconds();
    for (0..n_iters) |_| try func(ctx);
    const end = clock.now(io).toNanoseconds();
    const total: f64 = @floatFromInt(end - start);
    return total / @as(f64, @floatFromInt(n_iters)) / std.time.ns_per_ms;
}

test "tagFromExt" {
    try std.testing.expectEqual(ImageTag.jpg, try tagFromExt("a/b.JPEG"));
    try std.testing.expectEqual(ImageTag.png, try tagFromExt("x.png"));
    try std.testing.expectEqual(ImageTag.bmp, try tagFromExt("x.dib"));
    try std.testing.expectError(error.InvalidFileExtension, tagFromExt("noext"));
}
