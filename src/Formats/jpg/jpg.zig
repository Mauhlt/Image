//! Baseline / extended-sequential / progressive Huffman JPEG (JFIF).
//! Decode: 1 (gray) or 3 (YCbCr) components, any sampling factors, restart intervals,
//!         8 or 16-bit quant tables, progressive and multi-scan files (progressive.zig).
//!         Lossless (SOF3) files go to lossless.zig (gray above 8 bits -> .g16, else 8 bits).
//!         Arithmetic coding, 12-bit DCT and CMYK are rejected.
//! Encode: baseline, 4:2:0 (default) or 4:4:4, grayscale for `.g`/`.ga` images.
//!
//! Steps (encode): YCbCr -> chroma downsample -> 8x8 DCT -> quantize -> zigzag RLE + Huffman.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");

const Header = @import("header.zig");
const BitReader = @import("bitreader.zig");
const BitWriter = @import("bitwriter.zig");
const Component = @import("component.zig");
const huffman = @import("huffman.zig");
const dct = @import("dct.zig");
const misc = @import("misc.zig");
const progressive = @import("progressive.zig");
const lossless = @import("lossless.zig");
const Upsampler = @import("upsample.zig").Upsampler;
const ycbcr = @import("ycbcr.zig");
const V = @import("upsample.zig").V;
const ZIGZAG = misc.ZIGZAG;
const ceilDiv = misc.ceilDiv;

pub const DEFAULT_QUALITY = misc.DEFAULT_QUALITY;

// ───────────────────────────── Decode ─────────────────────────────

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data, .frame);
    if (hdr.lossless) return lossless.info(data);
    const tag: @import("../../Colors/pixels.zig").PixelTag = if (hdr.n_components == 1) .g else .rgb;
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub const Plane = struct {
    data: []u8,
    stride: usize, // allocated width (multiple of 8)
    w: usize, // meaningful width  = ceil(width * h / h_max)
    h: usize, // meaningful height = ceil(height * v / v_max)

    /// The plane of a component with sampling factors `h`x`v` in a frame of `mcus_x`
    /// by `mcus_y` MCUs. Rows hold whole blocks, and the buffer has `V` bytes of slack
    /// so vector loads at the right edge of the last row stay in bounds (see Upsampler).
    pub fn alloc(scratch: std.mem.Allocator, width: usize, height: usize, mcus_x: usize, mcus_y: usize, h: u8, h_max: u8, v: u8, v_max: u8) !Plane {
        const stride = mcus_x * h * 8;
        return .{
            .data = try scratch.alloc(u8, stride * mcus_y * v * 8 + V),
            .stride = stride,
            .w = ceilDiv(width * h, h_max),
            .h = ceilDiv(height * v, v_max),
        };
    }
};

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const hdr: Header = try .decode(data, .scan);
    if (hdr.lossless) return lossless.decodeInto(scratch, data, inf, out);
    if (hdr.width != inf.width or hdr.height != inf.height) return Error.InvalidDimensions;

    const mcus_x = ceilDiv(hdr.width, 8 * @as(usize, hdr.h_max));
    const mcus_y = ceilDiv(hdr.height, 8 * @as(usize, hdr.v_max));

    var planes: [4]Plane = undefined;
    for (hdr.components[0..hdr.n_components], 0..) |c, i| {
        planes[i] = try .alloc(scratch, hdr.width, hdr.height, mcus_x, mcus_y, c.h, hdr.h_max, c.v, hdr.v_max);
    }
    defer for (planes[0..hdr.n_components]) |p| scratch.free(p.data);

    // Progressive, or sequential with components spread over several scans.
    if (hdr.progressive or hdr.n_scan != hdr.n_components) {
        try progressive.decode(scratch, data, hdr, &planes);
        return writePixels(scratch, &hdr, &planes, inf, out);
    }

    for (hdr.components[0..hdr.n_components]) |c| {
        if (hdr.qtables[c.tq] == null) return Error.MissingQuantTable;
        if (hdr.dc_tables[c.td] == null or hdr.ac_tables[c.ta] == null) return Error.MissingHuffmanTable;
    }
    var br: BitReader = .{ .data = data[hdr.scan_start..] };
    var pred: [4]i32 = @splat(0);
    var mcu_count: usize = 0;

    if (hdr.n_scan == 1) {
        // non-interleaved: one block per MCU, block grid covers only the component
        const ci = hdr.scan[0];
        const c = hdr.components[ci];
        const p = planes[ci];
        const bw = ceilDiv(p.w, 8);
        const bh = ceilDiv(p.h, 8);
        for (0..bh) |by| for (0..bw) |bx| {
            try restartIfNeeded(&hdr, &br, &pred, mcu_count);
            mcu_count += 1;
            try decodeBlock(&hdr, c, &br, &pred[ci], p.data[by * 8 * p.stride + bx * 8 ..], p.stride);
        };
    } else {
        for (0..mcus_y) |my| for (0..mcus_x) |mx| {
            try restartIfNeeded(&hdr, &br, &pred, mcu_count);
            mcu_count += 1;
            for (hdr.scan[0..hdr.n_scan]) |ci| {
                const c = hdr.components[ci];
                const p = planes[ci];
                for (0..c.v) |v| for (0..c.h) |h| {
                    const x = (mx * c.h + h) * 8;
                    const y = (my * c.v + v) * 8;
                    try decodeBlock(&hdr, c, &br, &pred[ci], p.data[y * p.stride + x ..], p.stride);
                };
            }
        };
    }

    try writePixels(scratch, &hdr, &planes, inf, out);
}

fn restartIfNeeded(hdr: *const Header, br: *BitReader, pred: *[4]i32, mcu_count: usize) !void {
    if (hdr.restart_interval == 0 or mcu_count == 0) return;
    if (mcu_count % hdr.restart_interval != 0) return;
    try br.restart();
    pred.* = @splat(0);
}

fn decodeBlock(
    hdr: *const Header,
    c: Component,
    br: *BitReader,
    pred: *i32,
    dst: []u8,
    stride: usize,
) !void {
    const qt = &hdr.qtables[c.tq].?;
    const dc = &hdr.dc_tables[c.td].?;
    const ac = &hdr.ac_tables[c.ta].?;

    var coeffs: [64]f32 = @splat(0);
    const s = try br.decodeSymbol(dc);
    if (s > 15) return Error.InvalidHuffmanCode;
    pred.* += br.receiveExtend(@intCast(s));
    coeffs[0] = @floatFromInt(pred.* * @as(i32, qt[0]));

    var k: usize = 1;
    var any_ac = false;
    while (k < 64) {
        const sym = try br.decodeAc(ac);
        if (sym.value == 0) {
            if (sym.run != 15) break; // EOB
            k += 16; // ZRL
            continue;
        }
        k += sym.run;
        if (k > 63) return Error.InvalidHuffmanCode;
        const nat = ZIGZAG[k];
        coeffs[nat] = @floatFromInt(sym.value * @as(i32, qt[nat]));
        any_ac = true;
        k += 1;
    }

    // Flat blocks (no AC) are common, and their inverse is one value.
    if (!any_ac) return storeFlat(dct.inverseDc(coeffs[0]), dst, stride);
    const samples = dct.inverse(&coeffs);
    storeBlock(&samples, dst, stride);
}

/// Level-shifts, rounds and clamps an IDCT'd block into an 8x8 area of a plane.
pub fn storeBlock(samples: *const [64]f32, dst: []u8, stride: usize) void {
    for (0..8) |y| dst[y * stride ..][0..8].* = toPixels(samples[y * 8 ..][0..8].*);
}

/// storeBlock for a block whose 64 samples all equal `sample`.
pub fn storeFlat(sample: f32, dst: []u8, stride: usize) void {
    const row = toPixels(@splat(sample));
    for (0..8) |y| dst[y * stride ..][0..8].* = row;
}

/// One row of an 8x8 block: the width is the block's, not a tuning choice.
fn toPixels(row: @Vector(8, f32)) @Vector(8, u8) {
    const v = @round(row + @as(@Vector(8, f32), @splat(128)));
    return @intFromFloat(@min(@max(v, @as(@Vector(8, f32), @splat(0))), @as(@Vector(8, f32), @splat(255))));
}

fn writePixels(scratch: std.mem.Allocator, hdr: *const Header, planes: *const [4]Plane, inf: Info, out: []u8) !void {
    const width: usize = hdr.width;
    const height: usize = hdr.height;
    if (hdr.n_components == 1) {
        if (inf.tag != .g) return Error.UnsupportedPixels;
        const p = planes[0];
        for (0..height) |y| @memcpy(out[y * width ..][0..width], p.data[y * p.stride ..][0..width]);
        return;
    }
    if (inf.tag != .rgb) return Error.UnsupportedPixels;

    var h: [3]u8 = undefined;
    var v: [3]u8 = undefined;
    for (hdr.components[0..3], &h, &v) |c, *hh, *vv| {
        hh.* = c.h;
        vv.* = c.v;
    }
    return planesToRgb(scratch, planes[0..3], h, hdr.h_max, v, hdr.v_max, width, height, out);
}

/// Upsamples the Y, Cb and Cr planes (sampling factors `h`, `v`) to `width` x `height`
/// and converts them to interleaved RGB in `out`.
fn planesToRgb(scratch: std.mem.Allocator, planes: *const [3]Plane, h: [3]u8, h_max: u8, v: [3]u8, v_max: u8, width: usize, height: usize, out: []u8) !void {
    var ups: [3]Upsampler = undefined;
    for (&ups, planes, h, v) |*u, p, hh, vv| u.* = try .init(scratch, p, width, height, hh, h_max, vv, v_max);
    for (0..height) |y| {
        ycbcr.toRgbRow(ups[0].rowAt(y), ups[1].rowAt(y), ups[2].rowAt(y), out[y * width * 3 ..][0 .. width * 3]);
    }
}

// ───────────────────────────── Encode ─────────────────────────────

pub const Subsampling = enum { s444, s420 };

pub const EncodeOptions = struct {
    /// 1 (worst) .. 100 (best)
    quality: u8 = DEFAULT_QUALITY,
    subsampling: Subsampling = .s420,
};

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return encodeOptions(img, w, gpa, .{});
}

pub fn encodeOptions(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator, opts: EncodeOptions) !void {
    const width: usize = img.width;
    const height: usize = img.height;
    if (width == 0 or height == 0 or width > 0xFFFF or height > 0xFFFF) return Error.InvalidDimensions;

    const gray = switch (img.pixels) {
        .g, .ga, .g16 => true, // 8-bit: .g16 is rounded
        else => false,
    };
    const sub: Subsampling = if (gray) .s444 else opts.subsampling;
    const mcu: usize = if (sub == .s420) 16 else 8;
    const pw = ceilDiv(width, mcu) * mcu;
    const ph = ceilDiv(height, mcu) * mcu;

    // full-res planes padded to the MCU grid by edge replication
    const n_planes: usize = if (gray) 1 else 3;
    var planes: [3][]u8 = undefined;
    for (0..n_planes) |i| planes[i] = try gpa.alloc(u8, pw * ph);
    defer for (planes[0..n_planes]) |p| gpa.free(p);
    {
        const src = if (gray) try img.pixels.convertV(.g, gpa) else try img.pixels.convertV(.ycbcr, gpa);
        defer src.deinit(gpa);
        const bytes = src.asBytes();
        for (0..ph) |y| {
            const sy = @min(y, height - 1);
            for (0..pw) |x| {
                const s = (sy * width + @min(x, width - 1)) * n_planes;
                for (0..n_planes) |i| planes[i][y * pw + x] = bytes[s + i];
            }
        }
    }
    // 2x2 box downsample of chroma in place (top-left quarter of each plane)
    var cw = pw;
    if (sub == .s420) {
        cw = pw / 2;
        for (1..3) |i| {
            const p = planes[i];
            for (0..ph / 2) |y| for (0..cw) |x| {
                const a = (2 * y) * pw + 2 * x;
                const sum = @as(u16, p[a]) + p[a + 1] + p[a + pw] + p[a + pw + 1];
                p[y * cw + x] = @intCast((sum + 2) / 4);
            };
        }
    }

    const luma_q = misc.scaleQuantTable(&misc.BASE_LUMA_QUANT, opts.quality);
    const chroma_q = misc.scaleQuantTable(&misc.BASE_CHROMA_QUANT, opts.quality);
    const enc_dc = [2][256]huffman.EncEntry{ huffman.encTable(huffman.STD_DC_LUMA), huffman.encTable(huffman.STD_DC_CHROMA) };
    const enc_ac = [2][256]huffman.EncEntry{ huffman.encTable(huffman.STD_AC_LUMA), huffman.encTable(huffman.STD_AC_CHROMA) };

    // ── headers ──
    try w.writeAll(&.{ 0xFF, 0xD8 }); // SOI
    try w.writeAll(&.{ 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 }); // APP0
    try writeDqt(w, 0, &luma_q);
    if (!gray) try writeDqt(w, 1, &chroma_q);
    // SOF0
    try w.writeAll(&.{ 0xFF, 0xC0 });
    try w.writeInt(u16, @intCast(8 + 3 * n_planes), .big);
    try w.writeByte(8);
    try w.writeInt(u16, @intCast(height), .big);
    try w.writeInt(u16, @intCast(width), .big);
    try w.writeByte(@intCast(n_planes));
    try w.writeAll(&.{ 1, if (sub == .s420) 0x22 else 0x11, 0 });
    if (!gray) try w.writeAll(&.{ 2, 0x11, 1, 3, 0x11, 1 });
    // DHT
    try writeDht(w, 0x00, huffman.STD_DC_LUMA);
    try writeDht(w, 0x10, huffman.STD_AC_LUMA);
    if (!gray) {
        try writeDht(w, 0x01, huffman.STD_DC_CHROMA);
        try writeDht(w, 0x11, huffman.STD_AC_CHROMA);
    }
    // SOS
    try w.writeAll(&.{ 0xFF, 0xDA });
    try w.writeInt(u16, @intCast(6 + 2 * n_planes), .big);
    try w.writeByte(@intCast(n_planes));
    try w.writeAll(&.{ 1, 0x00 });
    if (!gray) try w.writeAll(&.{ 2, 0x11, 3, 0x11 });
    try w.writeAll(&.{ 0, 63, 0 });

    // ── entropy-coded data ──
    var bw: BitWriter = .{ .w = w };
    var pred: [3]i32 = @splat(0);
    for (0..ph / mcu) |my| for (0..pw / mcu) |mx| {
        const n_y = mcu / 8;
        for (0..n_y) |dy| for (0..n_y) |dx| {
            try encodeBlock(&bw, planes[0], pw, (mx * n_y + dx) * 8, (my * n_y + dy) * 8, &luma_q, &pred[0], &enc_dc[0], &enc_ac[0]);
        };
        if (!gray) for (1..3) |i| {
            try encodeBlock(&bw, planes[i], cw, mx * 8, my * 8, &chroma_q, &pred[i], &enc_dc[1], &enc_ac[1]);
        };
    };
    try bw.flush();
    try w.writeAll(&.{ 0xFF, 0xD9 }); // EOI
}

fn writeDqt(w: *std.Io.Writer, id: u8, table: *const [64]u16) !void {
    try w.writeAll(&.{ 0xFF, 0xDB, 0x00, 67, id });
    for (ZIGZAG) |nat| try w.writeByte(@intCast(table[nat]));
}

fn writeDht(w: *std.Io.Writer, class_id: u8, spec: huffman.Spec) !void {
    try w.writeAll(&.{ 0xFF, 0xC4 });
    try w.writeInt(u16, @intCast(2 + 1 + 16 + spec.values.len), .big);
    try w.writeByte(class_id);
    try w.writeAll(&spec.bits);
    try w.writeAll(spec.values);
}

/// Number of bits needed for |v| (JPEG "size" category).
fn bitSize(v: i32) u5 {
    const a: u32 = @abs(v);
    return @intCast(32 - @clz(a));
}

/// Two's-complement-minus-one encoding of negative values (F.1.2.1).
fn vliBits(v: i32, size: u5) u32 {
    const raw: i32 = if (v < 0) v - 1 else v;
    return @as(u32, @bitCast(raw)) & ((@as(u32, 1) << size) - 1);
}

fn encodeBlock(
    bw: *BitWriter,
    plane: []const u8,
    stride: usize,
    bx: usize,
    by: usize,
    qt: *const [64]u16,
    pred: *i32,
    dc_table: *const [256]huffman.EncEntry,
    ac_table: *const [256]huffman.EncEntry,
) !void {
    var samples: [64]f32 = undefined;
    for (0..8) |r| for (0..8) |c| {
        samples[r * 8 + c] = @as(f32, @floatFromInt(plane[(by + r) * stride + bx + c])) - 128.0;
    };
    const coeffs = dct.forward(&samples);
    var zz: [64]i32 = undefined;
    for (&zz, ZIGZAG) |*z, nat| z.* = @intFromFloat(@round(coeffs[nat] / @as(f32, @floatFromInt(qt[nat]))));

    const diff = zz[0] - pred.*;
    pred.* = zz[0];
    const dc_size = bitSize(diff);
    const dc = dc_table[dc_size];
    try bw.putBits(dc.code, @intCast(dc.len));
    try bw.putBits(vliBits(diff, dc_size), dc_size);

    var run: u8 = 0;
    for (zz[1..]) |v| {
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run > 15) : (run -= 16) {
            const zrl = ac_table[0xF0];
            try bw.putBits(zrl.code, @intCast(zrl.len));
        }
        const size = bitSize(v);
        const e = ac_table[(run << 4) | size];
        try bw.putBits(e.code, @intCast(e.len));
        try bw.putBits(vliBits(v, size), size);
        run = 0;
    }
    if (run > 0) {
        const eob = ac_table[0x00];
        try bw.putBits(eob.code, @intCast(eob.len));
    }
}

// ───────────────────────────── Tests ─────────────────────────────

test {
    _ = @import("huffman.zig");
    _ = @import("bitreader.zig");
    _ = @import("bitwriter.zig");
    _ = @import("dct.zig");
    _ = @import("upsample.zig");
    _ = @import("ycbcr.zig");
    _ = @import("narrow.zig");
    _ = @import("lossless.zig");
}

test "zigzag is a permutation" {
    var seen: [64]bool = @splat(false);
    for (ZIGZAG) |i| {
        try std.testing.expect(!seen[i]);
        seen[i] = true;
    }
}

test "vli round trip" {
    for ([_]i32{ 1, -1, 2, -2, 3, -3, 7, -7, 8, -8, 1023, -1023 }) |v| {
        const size = bitSize(v);
        var buf: [4]u8 = undefined;
        var wr: std.Io.Writer = .fixed(&buf);
        var bw: BitWriter = .{ .w = &wr };
        try bw.putBits(vliBits(v, size), size);
        try bw.flush();
        var br: BitReader = .{ .data = wr.buffered() };
        try std.testing.expectEqual(v, br.receiveExtend(size));
    }
}

fn roundTrip(gpa: std.mem.Allocator, img: *const Image, opts: EncodeOptions) !Image {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try encodeOptions(img, &aw.writer, gpa, opts);
    return Image.decode(.jpg, gpa, aw.written());
}

test "encode/decode solid color 16x16" {
    const gpa = std.testing.allocator;
    var data: [16 * 16 * 3]u8 = undefined;
    for (0..256) |i| data[i * 3 ..][0..3].* = .{ 200, 100, 50 };
    const img: Image = .{ .width = 16, .height = 16, .fmt = .r8g8b8_srgb, .pixels = try .init(.rgb, gpa, &data) };
    defer img.deinit(gpa);
    const out = try roundTrip(gpa, &img, .{ .quality = 95 });
    defer out.deinit(gpa);
    try Image.expectSimilar(gpa, &img, &out, .rgb, 2);
}

test "encode/decode gradient 33x17 (non-MCU-aligned), both subsamplings, gray" {
    const gpa = std.testing.allocator;
    const W = 33;
    const H = 17;
    var data: [W * H * 3]u8 = undefined;
    for (0..H) |y| for (0..W) |x| {
        data[(y * W + x) * 3 ..][0..3].* = .{ @truncate(x * 7), @truncate(y * 13), @truncate((x + y) * 3) };
    };
    const img: Image = .{ .width = W, .height = H, .fmt = .r8g8b8_srgb, .pixels = try .init(.rgb, gpa, &data) };
    defer img.deinit(gpa);
    for ([_]Subsampling{ .s420, .s444 }) |sub| {
        const out = try roundTrip(gpa, &img, .{ .quality = 90, .subsampling = sub });
        defer out.deinit(gpa);
        try Image.expectSimilar(gpa, &img, &out, .rgb, 4);
    }
    const gray = try img.convert(.g, gpa);
    defer gray.deinit(gpa);
    const out = try roundTrip(gpa, &gray, .{});
    defer out.deinit(gpa);
    try std.testing.expect(out.pixels == .g);
    try Image.expectSimilar(gpa, &gray, &out, .g, 3);
}

// Pixel hashes recorded from the original scalar decoder (float matrix IDCT, per-pixel
// float upsampling and colour conversion). The vectorized decoder must stay bit-exact.
test "decode output is unchanged from the scalar decoder" {
    const gpa = std.testing.allocator;
    const Case = struct { data: []const u8, hash: u64 };
    const cases = [_]Case{
        .{ .data = @embedFile("../../Data/Read/BasicArt.jpg"), .hash = 0x4e299d90afb0efb1 },
        .{ .data = @embedFile("../../Data/Read/Gradient.jpg"), .hash = 0x11742cd3833068c4 },
        .{ .data = @embedFile("../../Data/Read/Gradient444.jpg"), .hash = 0x9da620d26fbed0e7 },
        .{ .data = @embedFile("../../Data/Read/GradientGray.jpg"), .hash = 0x25eaf70a0c5ae94e },
        .{ .data = @embedFile("../../Data/Read/GradientProgressive.jpg"), .hash = 0x11742cd3833068c4 },
        .{ .data = @embedFile("../../Data/Read/IjgBaseline.jpg"), .hash = 0x2d02aa2124e9011e },
        .{ .data = @embedFile("../../Data/Read/IjgProgressive.jpg"), .hash = 0x2d02aa2124e9011e },
    };
    for (cases, 0..) |case, i| {
        const img = try Image.decode(.jpg, gpa, case.data);
        defer img.deinit(gpa);
        const hash = std.hash.Wyhash.hash(0, img.pixels.asBytes());
        if (hash != case.hash) std.debug.print("fixture {}: 0x{x:0>16}\n", .{ i, hash });
        try std.testing.expectEqual(case.hash, hash);
    }

    // Our own encoder's output at an odd size exercises the partial-vector edges.
    const W = 37;
    const H = 23;
    var data: [W * H * 3]u8 = undefined;
    for (0..H) |y| for (0..W) |x| {
        data[(y * W + x) * 3 ..][0..3].* = .{ @truncate(x * 7 + y), @truncate(y * 13 ^ x), @truncate((x + y) * 5) };
    };
    const src: Image = .{ .width = W, .height = H, .fmt = .r8g8b8_srgb, .pixels = try .init(.rgb, gpa, &data) };
    defer src.deinit(gpa);
    const encoded = [_]u64{ 0x2d176a5c95fbbae2, 0x8f6d283ce6f3251e };
    for ([_]Subsampling{ .s420, .s444 }, encoded, 0..) |sub, expected, i| {
        const img = try roundTrip(gpa, &src, .{ .quality = 75, .subsampling = sub });
        defer img.deinit(gpa);
        const hash = std.hash.Wyhash.hash(0, img.pixels.asBytes());
        if (hash != expected) std.debug.print("encoded {}: 0x{x:0>16}\n", .{ i, hash });
        try std.testing.expectEqual(expected, hash);
    }
}

/// Widths around every vector edge: below, at and just past one vector (`V` u16 lanes
/// in the upsampler, `V` pixels in ycbcr, `2V` bytes per upsampled row), and several
/// vectors plus a tail.
const edge_widths = [_]usize{ 1, 2, 3, 7, 15, 17, 33, 65, 127, V - 1, V, V + 1, 2 * V - 1, 2 * V, 2 * V + 1, 2 * V + 3, 4 * V + 5 };

test "upsampling + color conversion at vector edges, every sampling mode, vs scalar" {
    const color = @import("../../Colors/misc.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    // luma factors (chroma is 1x1): 4:4:4, 4:2:2, 4:4:0, 4:2:0, and float-tap ratios
    const modes = [_][2]u8{ .{ 1, 1 }, .{ 2, 1 }, .{ 1, 2 }, .{ 2, 2 }, .{ 4, 1 }, .{ 3, 2 } };
    for (edge_widths) |width| for ([_]usize{ 1, 2, 3, 9, 17 }) |height| for (modes) |m| {
        const h_max, const v_max = m;
        const mcus_x = ceilDiv(width, 8 * @as(usize, h_max));
        const mcus_y = ceilDiv(height, 8 * @as(usize, v_max));
        const h = [3]u8{ h_max, 1, 1 };
        const v = [3]u8{ v_max, 1, 1 };
        var planes: [3]Plane = undefined;
        for (&planes, h, v) |*p, hh, vv| {
            // exactly the decoder's allocation, so Debug bounds checks catch any over-read
            p.* = try .alloc(scratch, width, height, mcus_x, mcus_y, hh, h_max, vv, v_max);
            random.bytes(p.data);
        }
        const out = try scratch.alloc(u8, width * height * 3);
        try planesToRgb(scratch, &planes, h, h_max, v, v_max, width, height, out);

        for (0..height) |y| for (0..width) |x| {
            var s: [3]u8 = undefined;
            for (&s, planes, h, v) |*e, p, hh, vv| e.* = scalarSample(p, x, y, hh, h_max, vv, v_max);
            const want = [3]u8{ color.red(s[0], s[2]), color.green(s[0], s[1], s[2]), color.blue(s[0], s[1]) };
            const got = out[(y * width + x) * 3 ..][0..3];
            if (!std.mem.eql(u8, &want, got)) {
                std.debug.print("width {} height {} mode {any} at ({}, {})\n", .{ width, height, m, x, y });
                return error.TestExpectedEqual;
            }
        };
        _ = arena.reset(.retain_capacity);
    };
}

/// Bilinear (libjpeg "fancy") sample of plane `p` at full-resolution pixel (x, y), in f32.
fn scalarSample(p: Plane, x: usize, y: usize, h: u8, h_max: u8, v: u8, v_max: u8) u8 {
    const x0, const x1, const wx = scalarTap(x, p.w, h, h_max);
    const y0, const y1, const wy = scalarTap(y, p.h, v, v_max);
    const a0 = std.math.lerp(planeAt(p, x0, y0), planeAt(p, x1, y0), wx);
    const a1 = std.math.lerp(planeAt(p, x0, y1), planeAt(p, x1, y1), wx);
    return @intFromFloat(@round(std.math.lerp(a0, a1, wy)));
}

fn scalarTap(i: usize, n_in: usize, f: u8, max: u8) struct { usize, usize, f32 } {
    if (f == max) return .{ i, i, 0 };
    const ratio = @as(f32, @floatFromInt(f)) / @as(f32, @floatFromInt(max));
    const last: f32 = @floatFromInt(n_in - 1);
    const pos = @min(@max((@as(f32, @floatFromInt(i)) + 0.5) * ratio - 0.5, 0), last);
    const p0 = @floor(pos);
    return .{ @intFromFloat(p0), @intFromFloat(@min(p0 + 1, last)), pos - p0 };
}

fn planeAt(p: Plane, x: usize, y: usize) f32 {
    return @floatFromInt(p.data[y * p.stride + x]);
}

test "encode/decode round trip at vector-edge widths" {
    const gpa = std.testing.allocator;
    for (edge_widths) |W| for ([_]usize{ 1, 9 }) |H| {
        const data = try gpa.alloc(u8, W * H * 3);
        defer gpa.free(data);
        for (0..H) |y| for (0..W) |x| {
            data[(y * W + x) * 3 ..][0..3].* = .{ @truncate(x * 3 + 40), @truncate(y * 11 + 60), @truncate((x + y) * 2 + 80) };
        };
        const img: Image = .{ .width = @intCast(W), .height = @intCast(H), .fmt = .r8g8b8_srgb, .pixels = try .init(.rgb, gpa, data) };
        defer img.deinit(gpa);
        for ([_]Subsampling{ .s420, .s444 }) |sub| {
            const out = try roundTrip(gpa, &img, .{ .quality = 95, .subsampling = sub });
            defer out.deinit(gpa);
            try std.testing.expectEqual(img.width, out.width);
            try Image.expectSimilar(gpa, &img, &out, .rgb, 12);
        }
    };
}

test "decode rejects bad data" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(Error.UnexpectedSignature, Image.decode(.jpg, gpa, &.{ 0x00, 0xD8, 0xFF, 0xD9 }));
    try std.testing.expectError(Error.UnexpectedSignature, Image.decode(.jpg, gpa, &.{0xFF}));
}
