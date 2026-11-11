//! BMP / DIB decoding: 1/2/4/8-bit palette (uncompressed, RLE4, RLE8), 16 and 32-bit
//! (default layouts or BI_BITFIELDS / BI_ALPHABITFIELDS with any channel masks, alpha
//! from the mask in V3+ headers), and 24-bit; bottom-up or top-down; Windows
//! BITMAPINFOHEADER..V5 or OS/2 1.x BITMAPCOREHEADER.
//! Encodes g (8-bit gray palette), 24-bit, and 32-bit BGRA (V4 header with an alpha mask).
const std = @import("std");
const Error = @import("../error.zig").Error;

const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const simd = @import("../../Colors/simd.zig");

const Header = @import("header.zig");
const Bitfields = @import("bitfields.zig").Bitfields;
const rle = @import("rle.zig");
const strideOf = @import("misc.zig").strideOf;

/// SIMD
const PIXELS_PER_CHUNK = 16;
const RGB_CHUNK_BYTES = PIXELS_PER_CHUNK * 3;
const RGB_VEC = @Vector(RGB_CHUNK_BYTES, u8);
const rgb_swap_mask: @Vector(RGB_CHUNK_BYTES, i32) = blk: {
    var m: [RGB_CHUNK_BYTES]i32 = undefined;
    for (0..PIXELS_PER_CHUNK) |p| {
        m[p * 3 + 0] = p * 3 + 2;
        m[p * 3 + 1] = p * 3 + 1;
        m[p * 3 + 2] = p * 3 + 0;
    }
    break :blk m;
};
const RGBA_CHUNK_BYTES = PIXELS_PER_CHUNK * 4;
const RGBA_VEC = @Vector(RGBA_CHUNK_BYTES, u8);
const rgba_swap_mask: @Vector(RGBA_CHUNK_BYTES, i32) = blk: {
    var m: [RGBA_CHUNK_BYTES]i32 = undefined;
    for (0..PIXELS_PER_CHUNK) |p| {
        m[p * 4 + 0] = p * 4 + 2;
        m[p * 4 + 1] = p * 4 + 1;
        m[p * 4 + 2] = p * 4 + 0;
        m[p * 4 + 3] = p * 4 + 3;
    }
    break :blk m;
};

fn writeRgbRowSwapped(w: *std.Io.Writer, src: []const u8, width: usize) !void {
    var i: usize = 0;
    while (i + PIXELS_PER_CHUNK <= width) : (i += PIXELS_PER_CHUNK) {
        const s: RGB_VEC = src[i * 3 ..][0..RGB_CHUNK_BYTES].*;
        const d: RGB_VEC = @shuffle(u8, s, undefined, rgb_swap_mask);
        try w.writeAll(&@as([RGB_CHUNK_BYTES]u8, d));
    }
    while (i < width) : (i += 1) {
        try w.writeByte(src[i * 3 + 2]);
        try w.writeByte(src[i * 3 + 1]);
        try w.writeByte(src[i * 3 + 0]);
    }
}

fn writeRgbaRowSwapped(w: *std.Io.Writer, src: []const u8, width: usize) !void {
    var i: usize = 0;
    while (i + PIXELS_PER_CHUNK <= width) : (i += PIXELS_PER_CHUNK) {
        const s: RGBA_VEC = src[i * 4 ..][0..RGBA_CHUNK_BYTES].*;
        const d: RGBA_VEC = @shuffle(u8, s, undefined, rgba_swap_mask);
        try w.writeAll(&@as([RGBA_CHUNK_BYTES]u8, d));
    }
    while (i < width) : (i += 1) {
        try w.writeByte(src[i * 4 + 2]);
        try w.writeByte(src[i * 4 + 1]);
        try w.writeByte(src[i * 4 + 0]);
        try w.writeByte(src[i * 4 + 3]);
    }
}

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data);
    const tag: PixelTag = switch (hdr.bits_per_pixel) {
        .rgb_16, .rgba_32 => if (hdr.hasAlpha()) .bgra else .bgr,
        .rgb_24 => .bgr,
        .bit_1_palette, .bit_2_palette, .bit_4_palette, .bit_8_palette => if (hdr.isGrayPalette()) .g else .bgr,
    };
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const hdr: Header = try .decode(data);
    const width: usize = hdr.width;
    const height: usize = hdr.height;
    const out_bpp = inf.tag.bytesPerPixel();
    const out_stride = width * out_bpp;

    // RLE expands to one index per pixel first: its codes may cross rows (delta)
    var written: ?[]u8 = null; // RLE: which pixels the stream set
    const rle_indices: ?[]u8 = switch (hdr.compression) {
        .rle4, .rle8 => blk: {
            const idx = try scratch.alloc(u8, width * height);
            @memset(idx, 0);
            written = try scratch.alloc(u8, width * height);
            @memset(written.?, 0);
            try rle.decode(if (hdr.compression == .rle4) .rle4 else .rle8, hdr.rleData(data), width, height, idx, written);
            break :blk idx;
        },
        else => null,
    };
    const row_indices = try scratch.alloc(u8, width);
    const fields: Bitfields = try .init(hdr.masks);
    const palette: Palette = .init(&hdr);

    for (0..height) |y| {
        const src_row = if (hdr.is_top_down) y else height - 1 - y;
        const dst = out[y * out_stride ..][0..out_stride];
        if (rle_indices) |idx| {
            try palette.writeRow(idx[src_row * width ..][0..width], dst, inf.tag);
            continue;
        }
        const src = data[hdr.data_offset + src_row * hdr.stride() ..][0..hdr.rowBytes()];
        switch (hdr.bits_per_pixel) {
            .rgb_24 => @memcpy(dst, src),
            .rgb_16 => fields.decodeRow(u16, src, dst, width, out_bpp),
            .rgba_32 => fields.decodeRow(u32, src, dst, width, out_bpp),
            .bit_1_palette, .bit_2_palette, .bit_4_palette, .bit_8_palette => {
                const depth = @intFromEnum(hdr.bits_per_pixel);
                const indices = if (depth == 8) src[0..width] else blk: {
                    unpackIndices(src, row_indices, depth);
                    break :blk row_indices;
                };
                try palette.writeRow(indices, dst, inf.tag);
            },
        }
    }
    if (written) |w| blackenSkipped(w, out, width, height, hdr.is_top_down, out_bpp);
}

/// RLE pixels the stream never set (delta, early end of line / bitmap) become
/// opaque black, matching Windows' decoder. `written` is in file row order.
fn blackenSkipped(written: []const u8, out: []u8, width: usize, height: usize, top_down: bool, bpp: usize) void {
    for (0..height) |y| {
        const src_row = if (top_down) y else height - 1 - y;
        const w = written[src_row * width ..][0..width];
        const dst = out[y * width * bpp ..][0 .. width * bpp];
        for (w, 0..) |set, x| if (set == 0) {
            const px = dst[x * bpp ..][0..bpp];
            @memset(px, 0);
            if (bpp == 4) px[3] = 255;
        };
    }
}

/// Splits packed 1/2/4/8-bit indices (most significant bits = leftmost pixel).
fn unpackIndices(src: []const u8, out: []u8, depth: u16) void {
    switch (depth) {
        inline 1, 2, 4 => |d| unpackDepth(d, src, out),
        else => @memcpy(out, src[0..out.len]),
    }
}

fn unpackDepth(comptime depth: u16, src: []const u8, out: []u8) void {
    const per_byte = 8 / depth;
    // every byte value's indices, so whole bytes unpack with one table load
    const table: [256][per_byte]u8 = comptime blk: {
        @setEvalBranchQuota(4 * 256 * per_byte);
        var t: [256][per_byte]u8 = undefined;
        for (&t, 0..) |*e, byte| for (e, 0..) |*o, k| {
            o.* = (byte >> (8 - depth * (k + 1))) & ((1 << depth) - 1);
        };
        break :blk t;
    };
    const full = out.len / per_byte;
    for (src[0..full], 0..) |byte, i| out[i * per_byte ..][0..per_byte].* = table[byte];
    const rest = out.len - full * per_byte;
    if (rest > 0) @memcpy(out[full * per_byte ..], table[src[full]][0..rest]);
}

/// The palette as 4-byte entries (BGR plus a pad byte), so a lookup is one load.
const Palette = struct {
    colors: [256][4]u8,
    len: usize,

    fn init(hdr: *const Header) Palette {
        var p: Palette = .{ .colors = @splat(@splat(0)), .len = hdr.paletteLen() };
        for (p.colors[0..p.len], 0..) |*c, i| c[0..3].* = hdr.paletteColor(i).*;
        return p;
    }

    fn writeRow(self: *const Palette, indices: []const u8, dst: []u8, tag: PixelTag) Error!void {
        if (self.len < 256 and simd.minMax(indices).max >= self.len) return Error.OutOfBounds;
        // a gray palette maps every index to (index, index, index)
        if (tag == .g) return @memcpy(dst, indices);
        simd.lookup(3, &self.colors, indices, dst);
    }
};

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    // BMP stores gray (palette), BGR or BGRA; convert anything else
    const tag: PixelTag = switch (img.pixels) {
        .g, .ga => .g,
        .rgb, .bgr, .ycbcr => .bgr,
        .rgba, .bgra, .ycbcra => .bgra,
    };
    const active = std.meta.activeTag(img.pixels);
    const swap = (active == .rgb and tag == .bgr) or (active == .rgba and tag == .bgra);
    const converted = if (active == tag or swap) null else try img.pixels.convertV(tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const src = (converted orelse img.pixels).asBytes();

    const hdr: Header = try .init(img.width, img.height, switch (tag) {
        .g => .bit_8_palette,
        .bgr => .rgb_24,
        else => .rgba_32,
    });
    try hdr.encode(w);

    const width: usize = img.width;
    const bpp = tag.bytesPerPixel();
    const row_bytes = width * bpp;
    const pad = strideOf(row_bytes) - row_bytes;
    const zeros: [4]u8 = @splat(0);
    for (0..img.height) |file_row| {
        const img_row = img.height - 1 - file_row; // bottom-up
        const row = src[img_row * row_bytes ..][0..row_bytes];
        if (!swap) {
            try w.writeAll(row);
        } else if (bpp == 3) {
            try writeRgbRowSwapped(w, row, width);
        } else {
            try writeRgbaRowSwapped(w, row, width);
        }
        try w.writeAll(zeros[0..pad]);
    }
}

// ───────────────────────────── Tests ─────────────────────────────
// Fixtures are from Jason Summers' BMP Suite; `*.wic.png` is Windows' own decode
// of the same file (see src/Data/Read/bmp/README.md).

test {
    _ = @import("bitfields.zig");
    _ = rle;
}

const test_dir = "src/Data/Read/bmp/";

fn testRead(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Image {
    return Image.read(.{ .io = io, .gpa = gpa, .filepath = path }) catch |err| {
        std.debug.print("failed reading {s}: {t}\n", .{ path, err });
        return err;
    };
}

const Diff = struct { color: u8 = 0, alpha: u8 = 0 };

/// Largest per-channel difference, after converting both to RGBA.
fn maxDiff(gpa: std.mem.Allocator, a: *const Image, b: *const Image) !Diff {
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    const pa = try a.pixels.convert(.rgba, gpa);
    defer pa.deinit(gpa);
    const pb = try b.pixels.convert(.rgba, gpa);
    defer pb.deinit(gpa);
    var d: Diff = .{};
    for (pa.asBytes(), pb.asBytes(), 0..) |x, y, i| {
        const diff: u8 = @intCast(@abs(@as(i16, x) - y));
        if (i % 4 == 3) d.alpha = @max(d.alpha, diff) else d.color = @max(d.color, diff);
    }
    return d;
}

test "bmp matches Windows' decoder" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    inline for (.{
        .{ "pal4rle.bmp", 0 },
        .{ "pal8rle.bmp", 0 },
        .{ "rletopdown.bmp", 0 }, // RLE8 stored top-down (invalid, but Windows reads it)
        .{ "pal8os2.bmp", 0 }, // OS/2 core header, 3-byte palette
        .{ "pal8topdown.bmp", 0 },
        .{ "rgb32bf.bmp", 0 }, // bitfields in an unusual channel order
        .{ "rgb32-7187.bmp", 0 }, // 7/18/7-bit channels
        .{ "rgba32-1.bmp", 0 }, // V5 header with an alpha mask
        // Windows widens 5/6-bit channels by bit replication, we round
        .{ "rgb16.bmp", 1 }, // BI_RGB X1R5G5B5
        .{ "rgb16-565.bmp", 1 },
    }) |case| {
        const ours = try testRead(io, gpa, test_dir ++ case[0]);
        defer ours.deinit(gpa);
        const wic = try testRead(io, gpa, test_dir ++ case[0] ++ ".wic.png");
        defer wic.deinit(gpa);
        const d = try maxDiff(gpa, &wic, &ours);
        std.testing.expect(d.color <= case[1] and d.alpha == 0) catch |err| {
            std.debug.print("{s}: max color diff {d}, alpha diff {d}\n", .{ case[0], d.color, d.alpha });
            return err;
        };
    }
}

test "bmp rle: skipped pixels are black, like Windows" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // both files skip pixels (delta codes / early end of line)
    inline for (.{ "pal8rletrns.bmp", "pal4rlecut.bmp" }) |name| {
        const ours = try testRead(io, gpa, test_dir ++ name);
        defer ours.deinit(gpa);
        const pa = try ours.pixels.convert(.rgb, gpa);
        defer pa.deinit(gpa);
        const wic = try testRead(io, gpa, test_dir ++ name ++ ".wic.png");
        defer wic.deinit(gpa);
        const pw = try wic.pixels.convert(.rgb, gpa);
        defer pw.deinit(gpa);
        try std.testing.expectEqualSlices(u8, pw.asBytes(), pa.asBytes());
    }
}

test "bmp alpha from bitfields" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // rgba32-1 (verified against Windows above) and these files hold the same picture
    const ref = try testRead(io, gpa, test_dir ++ "rgba32-1.bmp.wic.png");
    defer ref.deinit(gpa);

    // BI_ALPHABITFIELDS, 40-byte header followed by 4 masks, channels shuffled
    const abf = try testRead(io, gpa, test_dir ++ "rgba32abf.bmp");
    defer abf.deinit(gpa);
    try std.testing.expectEqual(PixelTag.bgra, std.meta.activeTag(abf.pixels));
    try std.testing.expectEqual(Diff{}, try maxDiff(gpa, &ref, &abf));

    // 4 bits per channel incl. alpha; Windows ignores this alpha mask, so its
    // decode only checks the colors
    const a4444 = try testRead(io, gpa, test_dir ++ "rgba16-4444.bmp");
    defer a4444.deinit(gpa);
    const wic = try testRead(io, gpa, test_dir ++ "rgba16-4444.bmp.wic.png");
    defer wic.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), (try maxDiff(gpa, &wic, &a4444)).color);
    // 4-bit alpha is within half a step (255 / 15 / 2) of the 8-bit original
    try std.testing.expect((try maxDiff(gpa, &ref, &a4444)).alpha <= 8);
}

test "bmp bad and truncated files fail cleanly" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // RLE streams that try to write outside the image: any result but a crash is fine
    inline for (.{ "badrle.bmp", "badrle4.bmp", "badrle4bis.bmp" }) |name| {
        if (Image.read(.{ .io = io, .gpa = gpa, .filepath = test_dir ++ name })) |img| img.deinit(gpa) else |_| {}
    }
    inline for (.{ "pal4rlecut.bmp", "pal8os2.bmp", "rgb16-565.bmp", "rgba32abf.bmp" }) |name| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, test_dir ++ name, gpa, .unlimited);
        defer gpa.free(data);
        var len: usize = 0;
        while (len < data.len) : (len += 97) {
            if (Image.decode(.bmp, gpa, data[0..len])) |img| img.deinit(gpa) else |_| {}
        }
    }
}

test "bmp palette index unpacking" {
    var out: [8]u8 = undefined;
    unpackIndices(&.{0b1011_0001}, &out, 1);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 1, 0, 0, 0, 1 }, &out);
    unpackIndices(&.{ 0b00_01_10_11, 0b11_00_00_00 }, out[0..5], 2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 3 }, out[0..5]);
    unpackIndices(&.{ 0xAB, 0xC0 }, out[0..3], 4);
    try std.testing.expectEqualSlices(u8, &.{ 0xA, 0xB, 0xC }, out[0..3]);
}

test "bmp encode keeps alpha" {
    const gpa = std.testing.allocator;
    // 5x3: odd width, every alpha level along with the colors
    var data: [5 * 3 * 4]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 37) % 256);
    const img: Image = .{ .width = 5, .height = 3, .fmt = .b8g8r8a8_srgb, .pixels = try .init(.bgra, gpa, &data) };
    defer img.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try encode(&img, &aw.writer, gpa);
    const out = try Image.decode(.bmp, gpa, aw.written());
    defer out.deinit(gpa);
    try std.testing.expectEqual(PixelTag.bgra, std.meta.activeTag(out.pixels));
    try std.testing.expectEqualSlices(u8, &data, out.pixels.asBytes());
}

/// The original pixel-at-a-time decoder, kept as the oracle for the table and vector rows.
fn decodeReference(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const hdr: Header = try .decode(data);
    const width: usize = hdr.width;
    const height: usize = hdr.height;
    const out_bpp = inf.tag.bytesPerPixel();
    var written: ?[]u8 = null; // RLE: which pixels the stream set
    const rle_indices: ?[]u8 = switch (hdr.compression) {
        .rle4, .rle8 => blk: {
            const idx = try scratch.alloc(u8, width * height);
            @memset(idx, 0);
            written = try scratch.alloc(u8, width * height);
            @memset(written.?, 0);
            try rle.decode(if (hdr.compression == .rle4) .rle4 else .rle8, hdr.rleData(data), width, height, idx, written);
            break :blk idx;
        },
        else => null,
    };
    const indices = try scratch.alloc(u8, width);
    const fields: Bitfields = try .init(hdr.masks);
    for (0..height) |y| {
        const src_row = if (hdr.is_top_down) y else height - 1 - y;
        const dst = out[y * width * out_bpp ..][0 .. width * out_bpp];
        const depth = @intFromEnum(hdr.bits_per_pixel);
        if (rle_indices) |idx| @memcpy(indices, idx[src_row * width ..][0..width]) else {
            const src = data[hdr.data_offset + src_row * hdr.stride() ..][0..hdr.rowBytes()];
            if (depth <= 8) {
                for (indices, 0..) |*o, x| {
                    const shift: u3 = @intCast(8 - depth * (1 + x % (8 / depth)));
                    o.* = (src[x / (8 / depth)] >> shift) & @as(u8, @intCast((@as(u16, 1) << @intCast(depth)) - 1));
                }
            } else for (0..width) |x| {
                const px: u32 = switch (depth) {
                    16 => std.mem.readInt(u16, src[x * 2 ..][0..2], .little),
                    24 => {
                        @memcpy(dst[x * 3 ..][0..3], src[x * 3 ..][0..3]);
                        continue;
                    },
                    else => std.mem.readInt(u32, src[x * 4 ..][0..4], .little),
                };
                const d = dst[x * out_bpp ..];
                d[0] = fields.b.get(px);
                d[1] = fields.g.get(px);
                d[2] = fields.r.get(px);
                if (out_bpp == 4) d[3] = fields.a.get(px);
            }
        }
        if (depth <= 8) for (indices, 0..) |idx, x| {
            if (idx >= hdr.paletteLen()) return Error.OutOfBounds;
            const e = hdr.paletteColor(idx);
            if (inf.tag == .g) dst[x] = e[0] else dst[x * 3 ..][0..3].* = e.*;
        };
    }
    if (written) |w| blackenSkipped(w, out, width, height, hdr.is_top_down, out_bpp);
}

test "bmp table/vector decoder matches the pixel-at-a-time reference" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0xB4B);
    const rand = prng.random();
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);

    const Kind = struct { bpp: u16, compression: u32, n_masks: usize = 0 };
    const kinds = [_]Kind{
        .{ .bpp = 1, .compression = 0 },
        .{ .bpp = 2, .compression = 0 },
        .{ .bpp = 4, .compression = 0 },
        .{ .bpp = 8, .compression = 0 },
        .{ .bpp = 8, .compression = 1 }, // RLE8
        .{ .bpp = 4, .compression = 2 }, // RLE4
        .{ .bpp = 16, .compression = 0 },
        .{ .bpp = 24, .compression = 0 },
        .{ .bpp = 32, .compression = 0 },
        .{ .bpp = 16, .compression = 3, .n_masks = 3 }, // BI_BITFIELDS
        .{ .bpp = 32, .compression = 3, .n_masks = 3 },
        .{ .bpp = 16, .compression = 6, .n_masks = 4 }, // BI_ALPHABITFIELDS
        .{ .bpp = 32, .compression = 6, .n_masks = 4 },
    };
    var decoded: usize = 0;
    for (0..4000) |iter| {
        const k = kinds[iter % kinds.len];
        const width = rand.intRangeAtMost(u32, 1, 70);
        const height = rand.intRangeAtMost(u32, 1, 5);
        const top_down = rand.uintLessThan(u8, 4) == 0;
        const max_colors = @as(usize, 1) << @intCast(@min(k.bpp, 8));
        const n_pal: usize = if (k.bpp > 8) 0 else if (rand.boolean()) max_colors else rand.intRangeAtMost(usize, 1, max_colors);
        const gray = rand.uintLessThan(u8, 3) == 0;

        file.clearRetainingCapacity();
        const offset = 14 + 40 + k.n_masks * 4 + n_pal * 4;
        try file.appendNTimes(gpa, 0, offset);
        file.items[0..2].* = "BM".*;
        std.mem.writeInt(u32, file.items[10..14], @intCast(offset), .little);
        std.mem.writeInt(u32, file.items[14..18], 40, .little);
        std.mem.writeInt(i32, file.items[18..22], @intCast(width), .little);
        std.mem.writeInt(i32, file.items[22..26], if (top_down) -@as(i32, @intCast(height)) else @intCast(height), .little);
        std.mem.writeInt(u16, file.items[26..28], 1, .little);
        std.mem.writeInt(u16, file.items[28..30], k.bpp, .little);
        std.mem.writeInt(u32, file.items[30..34], k.compression, .little);
        std.mem.writeInt(u32, file.items[46..50], @intCast(n_pal), .little);
        // sometimes the plain byte layout, which has a shortcut
        const byte_masks = k.bpp == 32 and rand.boolean();
        for (0..k.n_masks) |m| {
            // contiguous masks of any width that fits, sometimes absent
            const pixel_bits: u6 = @intCast(k.bpp);
            const bits = rand.uintAtMost(u6, @min(pixel_bits, 12));
            const shift = rand.uintAtMost(u6, pixel_bits - bits);
            const byte_shift = [4]u5{ 16, 8, 0, 24 }; // R, G, B, A
            const mask: u32 = if (byte_masks) @as(u32, 0xFF) << byte_shift[m] else @intCast(((@as(u64, 1) << bits) - 1) << shift);
            std.mem.writeInt(u32, file.items[54 + m * 4 ..][0..4], mask, .little);
        }
        for (0..n_pal) |i| {
            const e = file.items[54 + k.n_masks * 4 + i * 4 ..][0..4];
            e.* = if (gray) .{ @intCast(i), @intCast(i), @intCast(i), 0 } else .{ rand.int(u8), rand.int(u8), rand.int(u8), 0 };
        }
        if (k.compression == 1 or k.compression == 2) {
            // runs, literals, end of line and deltas with random indices
            for (0..rand.uintAtMost(usize, 40)) |_| switch (rand.uintLessThan(u8, 8)) {
                0 => try file.appendSlice(gpa, &.{ 0, 0 }),
                1 => try file.appendSlice(gpa, &.{ 0, 2, rand.uintLessThan(u8, 4), rand.uintLessThan(u8, 2) }),
                2, 3 => {
                    const n = rand.intRangeAtMost(u8, 3, 40);
                    try file.appendSlice(gpa, &.{ 0, n });
                    const n_bytes = if (k.compression == 1) n else (n + 1) / 2;
                    for (0..n_bytes + (n_bytes & 1)) |_| try file.append(gpa, rand.int(u8));
                },
                else => try file.appendSlice(gpa, &.{ rand.intRangeAtMost(u8, 1, 80), rand.int(u8) }),
            };
            try file.appendSlice(gpa, &.{ 0, 1 });
        } else {
            const stride = ((width * k.bpp + 7) / 8 + 3) & ~@as(u32, 3);
            for (0..stride * height) |_| try file.append(gpa, rand.int(u8));
        }
        std.mem.writeInt(u32, file.items[2..6], @intCast(file.items.len), .little);

        const inf = info(file.items) catch continue;
        const len = try inf.byteLen();
        const ours = try gpa.alloc(u8, len);
        defer gpa.free(ours);
        const theirs = try gpa.alloc(u8, len);
        defer gpa.free(theirs);
        const r1 = decodeInto(arena.allocator(), file.items, inf, ours);
        const r2 = decodeReference(arena.allocator(), file.items, inf, theirs);
        _ = arena.reset(.retain_capacity);
        if (r2) |_| {
            r1 catch |err| {
                std.debug.print("iter {}: {any}: reference decoded, new decoder failed with {t}\n", .{ iter, k, err });
                return err;
            };
            std.testing.expectEqualSlices(u8, theirs, ours) catch |err| {
                std.debug.print("iter {}: {any} {}x{} palette {}\n", .{ iter, k, width, height, n_pal });
                return err;
            };
            decoded += 1;
        } else |want| try std.testing.expectError(want, r1);
    }
    // most files must be valid, or this only compares error paths
    try std.testing.expect(decoded > 2000);
}
