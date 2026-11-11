//! Baseline / extended-sequential / progressive Huffman JPEG (JFIF).
//! Decode: 1 (gray) or 3 (YCbCr) components, any sampling factors, restart intervals,
//!         8 or 16-bit quant tables, progressive and multi-scan files (progressive.zig).
//!         Arithmetic coding, lossless, 12-bit and CMYK are rejected.
//! Encode: baseline, 4:2:0 (default) or 4:4:4, grayscale for `.g`/`.ga` images.
//!
//! Steps (encode): YCbCr -> chroma downsample -> 8x8 DCT -> quantize -> zigzag RLE + Huffman.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const color = @import("../../Colors/misc.zig");

const Header = @import("header.zig");
const BitReader = @import("bitreader.zig");
const BitWriter = @import("bitwriter.zig");
const Component = @import("component.zig");
const huffman = @import("huffman.zig");
const dct = @import("dct.zig");
const misc = @import("misc.zig");
const progressive = @import("progressive.zig");
const ZIGZAG = misc.ZIGZAG;
const ceilDiv = misc.ceilDiv;

pub const DEFAULT_QUALITY = misc.DEFAULT_QUALITY;

// ───────────────────────────── Decode ─────────────────────────────

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data, .frame);
    const tag: @import("../../Colors/pixels.zig").PixelTag = if (hdr.n_components == 1) .g else .rgb;
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub const Plane = struct {
    data: []u8,
    stride: usize, // allocated width (multiple of 8)
    w: usize, // meaningful width  = ceil(width * h / h_max)
    h: usize, // meaningful height = ceil(height * v / v_max)
};

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const hdr: Header = try .decode(data, .scan);
    if (hdr.width != inf.width or hdr.height != inf.height) return Error.InvalidDimensions;

    const mcus_x = ceilDiv(hdr.width, 8 * @as(usize, hdr.h_max));
    const mcus_y = ceilDiv(hdr.height, 8 * @as(usize, hdr.v_max));

    var planes: [4]Plane = undefined;
    for (hdr.components[0..hdr.n_components], 0..) |c, i| {
        const stride = mcus_x * c.h * 8;
        const rows = mcus_y * c.v * 8;
        planes[i] = .{
            .data = try scratch.alloc(u8, stride * rows),
            .stride = stride,
            .w = ceilDiv(@as(usize, hdr.width) * c.h, hdr.h_max),
            .h = ceilDiv(@as(usize, hdr.height) * c.v, hdr.v_max),
        };
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
    while (k < 64) {
        const rs = try br.decodeSymbol(ac);
        const run = rs >> 4;
        const size = rs & 0xF;
        if (size == 0) {
            if (run != 15) break; // EOB
            k += 16; // ZRL
            continue;
        }
        k += run;
        if (k > 63) return Error.InvalidHuffmanCode;
        const nat = ZIGZAG[k];
        coeffs[nat] = @floatFromInt(br.receiveExtend(@intCast(size)) * @as(i32, qt[nat]));
        k += 1;
    }

    const samples = dct.inverse(&coeffs);
    storeBlock(&samples, dst, stride);
}

/// Level-shifts, rounds and clamps an IDCT'd block into an 8x8 area of a plane.
pub fn storeBlock(samples: *const [64]f32, dst: []u8, stride: usize) void {
    for (0..8) |y| {
        const row: @Vector(8, f32) = samples[y * 8 ..][0..8].*;
        const v = @round(row + @as(@Vector(8, f32), @splat(128)));
        const clamped = @min(@max(v, @as(@Vector(8, f32), @splat(0))), @as(@Vector(8, f32), @splat(255)));
        dst[y * stride ..][0..8].* = @as(@Vector(8, u8), @intFromFloat(clamped));
    }
}

/// Bilinear sampling positions for upsampling a plane to full resolution
/// (matches libjpeg's "fancy" upsampling for 2x factors).
const Taps = struct { i0: []u32, i1: []u32, w: []f32 };

fn makeTaps(scratch: std.mem.Allocator, n_out: usize, n_in: usize, factor: u8, max: u8) !Taps {
    const t: Taps = .{
        .i0 = try scratch.alloc(u32, n_out),
        .i1 = try scratch.alloc(u32, n_out),
        .w = try scratch.alloc(f32, n_out),
    };
    const ratio = @as(f32, @floatFromInt(factor)) / @as(f32, @floatFromInt(max));
    const last: f32 = @floatFromInt(n_in - 1);
    for (0..n_out) |i| {
        const pos = @min(@max((@as(f32, @floatFromInt(i)) + 0.5) * ratio - 0.5, 0), last);
        const p0 = @floor(pos);
        t.i0[i] = @intFromFloat(p0);
        t.i1[i] = @intFromFloat(@min(p0 + 1, last));
        t.w[i] = pos - p0;
    }
    return t;
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

    // full resolution rows for each component
    var rows: [3][]u8 = undefined;
    var x_taps: [3]?Taps = @splat(null);
    var y_taps: [3]?Taps = @splat(null);
    for (0..3) |i| {
        const c = hdr.components[i];
        rows[i] = try scratch.alloc(u8, width);
        if (c.h != hdr.h_max) x_taps[i] = try makeTaps(scratch, width, planes[i].w, c.h, hdr.h_max);
        if (c.v != hdr.v_max) y_taps[i] = try makeTaps(scratch, height, planes[i].h, c.v, hdr.v_max);
    }

    for (0..height) |y| {
        for (0..3) |i| {
            const p = planes[i];
            const row = rows[i];
            if (x_taps[i] == null and y_taps[i] == null) {
                @memcpy(row, p.data[y * p.stride ..][0..width]);
                continue;
            }
            const y0, const y1, const wy = if (y_taps[i]) |t| .{ t.i0[y], t.i1[y], t.w[y] } else .{ y, y, @as(f32, 0) };
            const r0 = p.data[y0 * p.stride ..][0..p.w];
            const r1 = p.data[y1 * p.stride ..][0..p.w];
            for (0..width) |x| {
                var a0: f32 = undefined;
                var a1: f32 = undefined;
                if (x_taps[i]) |t| {
                    const wx = t.w[x];
                    a0 = std.math.lerp(@as(f32, @floatFromInt(r0[t.i0[x]])), @as(f32, @floatFromInt(r0[t.i1[x]])), wx);
                    a1 = std.math.lerp(@as(f32, @floatFromInt(r1[t.i0[x]])), @as(f32, @floatFromInt(r1[t.i1[x]])), wx);
                } else {
                    a0 = @floatFromInt(r0[x]);
                    a1 = @floatFromInt(r1[x]);
                }
                row[x] = @intFromFloat(@round(std.math.lerp(a0, a1, wy)));
            }
        }
        const dst = out[y * width * 3 ..][0 .. width * 3];
        for (0..width) |x| {
            const yy = rows[0][x];
            const cb = rows[1][x];
            const cr = rows[2][x];
            dst[x * 3 + 0] = color.red(yy, cr);
            dst[x * 3 + 1] = color.green(yy, cb, cr);
            dst[x * 3 + 2] = color.blue(yy, cb);
        }
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
        .g, .ga => true,
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

test "decode rejects bad data" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(Error.UnexpectedSignature, Image.decode(.jpg, gpa, &.{ 0x00, 0xD8, 0xFF, 0xD9 }));
    try std.testing.expectError(Error.UnexpectedSignature, Image.decode(.jpg, gpa, &.{0xFF}));
}
