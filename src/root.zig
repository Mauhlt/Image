//! Image = decoded pixels + dimensions + the Vulkan format to upload them as.
//!
//! Every supported format lives in `Formats/<fmt>/<fmt>.zig` and exposes the same 3 fns:
//!     info(data: []const u8) !Info                                  -- parse header only
//!     decodeInto(scratch, data, info: Info, out: []u8) !void        -- decode into caller memory
//!     encode(img: *const Image, w: *std.Io.Writer, gpa) !void
//! `decode` / `read` below are thin wrappers that allocate the output for you.
//! For loading many files at once see `Batch` (one allocation for all pixels).
const std = @import("std");
const vk = @import("Vulkan");
const misc = @import("misc.zig");

pub const Pixels = @import("Colors/pixels.zig").Pixels;
pub const PixelTag = @import("Colors/pixels.zig").PixelTag;
pub const Info = @import("info.zig");
pub const Batch = @import("batch.zig");
/// GPU textures: mipmaps, arrays, cube maps, BCn - see texture.zig
pub const Texture = @import("texture.zig");
pub const ImageTag = misc.ImageTag;
pub const tagFromExt = misc.tagFromExt;

pub const BMP = @import("Formats/bmp/bmp.zig");
pub const JPG = @import("Formats/jpg/jpg.zig");
pub const PGM = @import("Formats/pgm/pgm.zig");
pub const PNG = @import("Formats/png/png.zig");
pub const PPM = @import("Formats/ppm/ppm.zig");
pub const QOI = @import("Formats/qoi/qoi.zig");
pub const TGA = @import("Formats/tga/tga.zig");
pub const WEBP = @import("Formats/webp/webp.zig");

const Image = @This();

width: u32,
height: u32,
pixels: Pixels,
fmt: vk.Format,

/// Codec module for a format, or null if unsupported.
pub fn Codec(comptime tag: ImageTag) ?type {
    return switch (tag) {
        .bmp => BMP,
        .jpg => JPG,
        .pgm => PGM,
        .png => PNG,
        .ppm => PPM,
        .qoi => QOI,
        .tga => TGA,
        .webp => WEBP,
        .gif, .heic, .paint, .tif => null,
    };
}

pub fn isSupported(tag: ImageTag) bool {
    return switch (tag) {
        inline else => |t| Codec(t) != null,
    };
}

pub fn info(tag: ImageTag, data: []const u8) !Info {
    switch (tag) {
        inline else => |t| {
            const C = Codec(t) orelse return error.Unsupported;
            return C.info(data);
        },
    }
}

/// Decodes into `out` (length must be `inf.byteLen()`), laid out as `inf.tag` pixels.
/// `scratch` holds temporaries only and is NOT freed piecewise: pass an arena
/// (reset it between images to reuse its memory - see `Batch`).
pub fn decodeInto(
    tag: ImageTag,
    scratch: std.mem.Allocator,
    data: []const u8,
    inf: Info,
    out: []u8,
) !void {
    if (out.len != try inf.byteLen()) return error.InvalidBufferLen;
    switch (tag) {
        inline else => |t| {
            const C = Codec(t) orelse return error.Unsupported;
            return C.decodeInto(scratch, data, inf, out);
        },
    }
}

pub fn decode(tag: ImageTag, gpa: std.mem.Allocator, data: []const u8) !Image {
    const inf = try info(tag, data);
    const bytes = try gpa.alloc(u8, try inf.byteLen());
    errdefer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try decodeInto(tag, arena.allocator(), data, inf, bytes);
    return .{
        .width = inf.width,
        .height = inf.height,
        .pixels = .fromBytes(inf.tag, bytes),
        .fmt = inf.fmt,
    };
}

pub fn encode(img: *const Image, tag: ImageTag, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    switch (tag) {
        inline else => |t| {
            const C = Codec(t) orelse return error.Unsupported;
            try C.encode(img, w, gpa);
            try w.flush();
        },
    }
}

pub fn copy(img: *const Image, gpa: std.mem.Allocator) !Image {
    return .{
        .width = img.width,
        .height = img.height,
        .pixels = try img.pixels.dupe(gpa),
        .fmt = img.fmt,
    };
}

/// Returns a new image with pixels converted to `tag`.
pub fn convert(img: *const Image, tag: PixelTag, gpa: std.mem.Allocator) !Image {
    const srgb = std.mem.endsWith(u8, @tagName(img.fmt), "srgb");
    return .{
        .width = img.width,
        .height = img.height,
        .pixels = try img.pixels.convertV(tag, gpa),
        .fmt = Info.fmtFor(tag, srgb),
    };
}

pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
    self.pixels.deinit(gpa);
}

pub fn format(self: *const Image, w: *std.Io.Writer) !void {
    try w.print("\nImage:\n", .{});
    try w.print("Width: {}\n", .{self.width});
    try w.print("Height: {}\n", .{self.height});
    try w.print("Pixels: {} ({t})\n", .{ self.pixels.count(), self.pixels });
    try w.print("Format: {t}\n", .{self.fmt});
}

pub fn printPixels(self: *const Image) void {
    switch (self.pixels) {
        inline else => |data| for (data) |datum| std.debug.print("{}\n", .{datum}),
    }
}

pub const PathType = enum(u8) {
    cwd, // path = path from cwd/terminal to file
    dir, // path = path from starting dir to file
    abs, // path = abs path from root to file
};

pub const ReadArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir = undefined,
    filepath: []const u8,
    path_type: PathType = .cwd,
};

pub fn openFile(io: std.Io, dir: std.Io.Dir, path: []const u8, path_type: PathType) !std.Io.File {
    return switch (path_type) {
        .abs => std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }),
        .cwd => std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }),
        .dir => dir.openFile(io, path, .{ .mode = .read_only }),
    };
}

/// Reads + decodes a file; format is chosen from the extension.
pub fn read(args: ReadArgs) !Image {
    const tag = try tagFromExt(args.filepath);
    if (!isSupported(tag)) return error.Unsupported;
    var file = try openFile(args.io, args.dir, args.filepath, args.path_type);
    defer file.close(args.io);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(args.gpa);
    const data = try misc.readFileInto(args.io, args.gpa, file, &buf);
    return decode(tag, args.gpa, data);
}

/// Encodes + writes a file; format is chosen from the extension.
pub fn write(img: *const Image, io: std.Io, gpa: std.mem.Allocator, filepath: []const u8) !void {
    const tag = try tagFromExt(filepath);
    if (!isSupported(tag)) return error.Unsupported;
    var file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try img.encode(tag, &writer.interface, gpa);
}

// ───────────────────────────── Tests ─────────────────────────────

test {
    _ = @import("misc.zig");
    _ = @import("batch.zig");
    _ = @import("texture.zig");
    _ = @import("Formats/netpbm.zig");
    _ = @import("Colors/test.zig");
    _ = @import("Formats/qoi/matches.zig");
    inline for (.{ BMP, JPG, PGM, PNG, PPM, QOI, TGA, WEBP }) |C| std.testing.refAllDecls(C);
}

/// Test helper: converts both images to `tag` and compares pixels.
/// `tolerance` = max mean abs error per channel (0 = exact).
pub fn expectSimilar(gpa: std.mem.Allocator, a: *const Image, b: *const Image, tag: PixelTag, tolerance: f64) !void {
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    const pa = try a.pixels.convert(tag, gpa);
    defer pa.deinit(gpa);
    const pb = try b.pixels.convert(tag, gpa);
    defer pb.deinit(gpa);
    const ba = pa.asBytes();
    const bb = pb.asBytes();
    if (tolerance == 0) return std.testing.expectEqualSlices(u8, ba, bb);
    var total: u64 = 0;
    for (ba, bb) |x, y| total += @abs(@as(i32, x) - y);
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(ba.len));
    if (mean > tolerance) {
        std.debug.print("mean abs error {d:.3} > {d:.3}\n", .{ mean, tolerance });
        return error.TestExpectedSimilar;
    }
}

fn testRead(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Image {
    return read(.{ .io = io, .gpa = gpa, .filepath = path }) catch |err| {
        std.debug.print("failed reading {s}: {t}\n", .{ path, err });
        return err;
    };
}

test "QOI - Basics" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const read_filepaths = [_][]const u8{
        "src/Data/Read/BasicDecodeRGB.qoi",
        "src/Data/Read/BasicDecodeRGBA.qoi",
    };
    const write_filepaths = [_][]const u8{
        "src/Data/Write/BasicDecodeRGB.qoi",
        "src/Data/Write/BasicDecodeRGBA.qoi",
    };
    for (read_filepaths, write_filepaths) |rpath, wpath| {
        const img1 = try testRead(io, gpa, rpath);
        defer img1.deinit(gpa);
        try img1.write(io, gpa, wpath);
        const img2 = try testRead(io, gpa, wpath);
        defer img2.deinit(gpa);
        try std.testing.expectEqual(std.meta.activeTag(img1.pixels), std.meta.activeTag(img2.pixels));
        try std.testing.expectEqualSlices(u8, img1.pixels.asBytes(), img2.pixels.asBytes());
    }
}

// Every reference file (written by an independent encoder, Pillow) must decode to the
// same pixels as the PNG of the same picture.
test "Images - decode reference files" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Case = struct { path: []const u8, tag: PixelTag, tol: f64 = 0 };
    const groups = [_]struct { ref: []const u8, cases: []const Case }{
        .{ .ref = "src/Data/Read/BasicArt.png", .cases = &.{
            // these two were exported from a slightly different source (blue off by 1)
            .{ .path = "src/Data/Read/BasicArt.bmp", .tag = .rgb, .tol = 0.5 },
            .{ .path = "src/Data/Read/BasicArt.qoi", .tag = .rgb, .tol = 0.5 },
            .{ .path = "src/Data/Read/BasicArt.ppm", .tag = .rgb },
            .{ .path = "src/Data/Read/BasicArt.pgm", .tag = .g, .tol = 0.6 }, // gray formula differs by rounding
            .{ .path = "src/Data/Read/BasicArt.tga", .tag = .rgba },
            .{ .path = "src/Data/Read/BasicArt.webp", .tag = .rgba },
            .{ .path = "src/Data/Read/BasicArt.jpg", .tag = .rgb, .tol = 3 },
        } },
        .{ .ref = "src/Data/Read/Gradient.png", .cases = &.{
            .{ .path = "src/Data/Read/Gradient.bmp", .tag = .rgb },
            .{ .path = "src/Data/Read/Gradient.ppm", .tag = .rgb },
            .{ .path = "src/Data/Read/Gradient.pgm", .tag = .g, .tol = 0.6 },
            .{ .path = "src/Data/Read/Gradient.tga", .tag = .rgba },
            .{ .path = "src/Data/Read/GradientRle.tga", .tag = .rgba },
            .{ .path = "src/Data/Read/Gradient.webp", .tag = .rgba },
        } },
        // JPEGs vs. Pillow's own decode of the same file (IDCT/upsampling differ slightly)
        .{ .ref = "src/Data/Read/GradientJpg.ref.ppm", .cases = &.{
            .{ .path = "src/Data/Read/Gradient.jpg", .tag = .rgb, .tol = 2.5 },
        } },
        .{ .ref = "src/Data/Read/Gradient444Jpg.ref.ppm", .cases = &.{
            .{ .path = "src/Data/Read/Gradient444.jpg", .tag = .rgb, .tol = 1 },
        } },
        .{ .ref = "src/Data/Read/GradientGrayJpg.ref.ppm", .cases = &.{
            .{ .path = "src/Data/Read/GradientGray.jpg", .tag = .rgb, .tol = 1 },
        } },
    };
    for (groups) |group| {
        const ref = try testRead(io, gpa, group.ref);
        defer ref.deinit(gpa);
        for (group.cases) |case| {
            const img = try testRead(io, gpa, case.path);
            defer img.deinit(gpa);
            expectSimilar(gpa, &ref, &img, case.tag, case.tol) catch |err| {
                std.debug.print("mismatch: {s}\n", .{case.path});
                return err;
            };
        }
    }
}

test "JPEG - progressive" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // IJG's testprog.jpg is a lossless (jpegtran) conversion of testorig.jpg to
    // progressive: same coefficients, so the pixels must match exactly.
    const baseline = try testRead(io, gpa, "src/Data/Read/IjgBaseline.jpg");
    defer baseline.deinit(gpa);
    const prog = try testRead(io, gpa, "src/Data/Read/IjgProgressive.jpg");
    defer prog.deinit(gpa);
    try expectSimilar(gpa, &baseline, &prog, .rgb, 0);

    // ...and both match libjpeg's own decode (testimg.ppm) up to IDCT rounding.
    const libjpeg = try testRead(io, gpa, "src/Data/Read/IjgBaselineJpg.ref.ppm");
    defer libjpeg.deinit(gpa);
    try expectSimilar(gpa, &libjpeg, &prog, .rgb, 1);

    // A second encoder's progressive file vs. Windows' decoder (WIC).
    const wic = try testRead(io, gpa, "src/Data/Read/GradientProgressiveJpg.ref.ppm");
    defer wic.deinit(gpa);
    const grad = try testRead(io, gpa, "src/Data/Read/GradientProgressive.jpg");
    defer grad.deinit(gpa);
    try expectSimilar(gpa, &wic, &grad, .rgb, 2.5);
}

// encode -> file -> decode for every writable format.
test "Images - write round trip" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Case = struct { path: []const u8, tag: PixelTag, tol: f64 = 0 };
    const cases = [_]Case{
        .{ .path = "src/Data/Write/BasicArt.bmp", .tag = .rgb },
        .{ .path = "src/Data/Write/BasicArt.png", .tag = .rgba },
        .{ .path = "src/Data/Write/BasicArt.qoi", .tag = .rgba },
        .{ .path = "src/Data/Write/BasicArt.ppm", .tag = .rgb },
        .{ .path = "src/Data/Write/BasicArt.pgm", .tag = .g },
        .{ .path = "src/Data/Write/BasicArt.tga", .tag = .rgba },
        .{ .path = "src/Data/Write/BasicArt.webp", .tag = .rgba },
        .{ .path = "src/Data/Write/BasicArt.jpg", .tag = .rgb, .tol = 2 },
        .{ .path = "src/Data/Write/Gradient.png", .tag = .rgba },
        .{ .path = "src/Data/Write/Gradient.tga", .tag = .rgba },
        .{ .path = "src/Data/Write/Gradient.webp", .tag = .rgba },
        // noisy image at q85 4:2:0; Pillow's encoder scores 7.72 on the same input
        .{ .path = "src/Data/Write/Gradient.jpg", .tag = .rgb, .tol = 8 },
    };
    for (cases) |case| {
        const src_path = if (std.mem.indexOf(u8, case.path, "Gradient") != null)
            "src/Data/Read/Gradient.png"
        else
            "src/Data/Read/BasicArt.png";
        const src = try testRead(io, gpa, src_path);
        defer src.deinit(gpa);
        const img1 = try src.convert(case.tag, gpa);
        defer img1.deinit(gpa);
        img1.write(io, gpa, case.path) catch |err| {
            std.debug.print("failed writing {s}: {t}\n", .{ case.path, err });
            return err;
        };
        const img2 = try testRead(io, gpa, case.path);
        defer img2.deinit(gpa);
        expectSimilar(gpa, &img1, &img2, case.tag, case.tol) catch |err| {
            std.debug.print("mismatch: {s}\n", .{case.path});
            return err;
        };
    }
}
