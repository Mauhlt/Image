//! Shared Netpbm reader + writers. The magic number fully describes the layout, so every
//! netpbm codec (PBM, PGM, PPM, PAM, PNM) decodes any of these:
//!   P1 / P4 = PBM bitmap  (1 = black), ASCII / binary with rows padded to a byte
//!   P2 / P5 = PGM graymap (1 sample),  ASCII / binary
//!   P3 / P6 = PPM pixmap  (3 samples), ASCII / binary
//!   P7      = PAM, binary; header of `KEYWORD value` lines ending with ENDHDR
//! P1..P6 header: magic, width, height, maxval (not in PBM) separated by any whitespace;
//! '#' starts a comment that runs to the end of the line.
//! maxval may be 1..65535 (2 big-endian bytes per sample above 255); samples are rescaled to 8 bits.
const std = @import("std");
const Error = @import("error.zig").Error;
const Image = @import("../root.zig");
const Info = @import("../info.zig");
const PixelTag = @import("../Colors/pixels.zig").PixelTag;
const simd = @import("../Colors/simd.zig");
const native_endian = @import("builtin").cpu.arch.endian();

pub const Magic = enum { P1, P2, P3, P4, P5, P6, P7 };

pub const Header = struct {
    magic: Magic,
    width: u32,
    height: u32,
    /// .g, .ga, .rgb or .rgba; also tells the number of samples per pixel
    tag: PixelTag,
    /// 1 for PBM
    max_val: u16,
    /// offset of the first raster byte (binary) or first sample token (ASCII)
    data_start: usize,
};

fn skipWhitespaceAndComments(data: []const u8, pos: usize) usize {
    var i = pos;
    while (i < data.len) {
        if (data[i] == '#') {
            while (i < data.len and data[i] != '\n') i += 1;
        } else if (std.ascii.isWhitespace(data[i])) {
            i += 1;
        } else break;
    }
    return i;
}

/// Parses the next unsigned integer token starting at `pos.*`.
fn readUint(data: []const u8, pos: *usize) Error!u32 {
    var i = skipWhitespaceAndComments(data, pos.*);
    const start = i;
    var value: u64 = 0;
    while (i < data.len and std.ascii.isDigit(data[i])) : (i += 1) {
        value = value * 10 + (data[i] - '0');
        if (value > std.math.maxInt(u32)) return Error.InvalidNum;
    }
    if (i == start) return if (i >= data.len) Error.UnexpectedEndOfData else Error.InvalidToken;
    pos.* = i;
    return @intCast(value);
}

/// The raster starts after exactly one whitespace byte following the last header token
/// (more would eat binary samples that happen to look like whitespace).
/// As in libnetpbm, a comment glued to the last token counts as that byte: it ends at a newline.
fn rasterStart(data: []const u8, pos: usize) Error!usize {
    var i = pos;
    if (i < data.len and data[i] == '#') {
        i = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse return Error.UnexpectedEndOfData;
    }
    if (i >= data.len) return Error.UnexpectedEndOfData;
    if (!std.ascii.isWhitespace(data[i])) return Error.InvalidToken;
    return i + 1;
}

fn checkShape(width: u32, height: u32, max_val: u32) Error!void {
    if (width == 0 or height == 0) return Error.InvalidDimensions;
    if (max_val == 0 or max_val > 0xFFFF) return Error.InvalidMaxVal;
}

pub fn decodeHeader(data: []const u8) Error!Header {
    if (data.len < 2) return Error.UnexpectedEndOfData;
    const magic = std.meta.stringToEnum(Magic, data[0..2]) orelse return Error.UnexpectedSignature;
    if (magic == .P7) return decodePamHeader(data);
    var pos: usize = 2;
    const width = try readUint(data, &pos);
    const height = try readUint(data, &pos);
    const max_val = switch (magic) {
        .P1, .P4 => 1,
        else => try readUint(data, &pos),
    };
    try checkShape(width, height, max_val);
    return .{
        .magic = magic,
        .width = width,
        .height = height,
        .tag = switch (magic) {
            .P1, .P2, .P4, .P5 => .g,
            .P3, .P6 => .rgb,
            .P7 => unreachable,
        },
        .max_val = @intCast(max_val),
        .data_start = try rasterStart(data, pos),
    };
}

const PamKey = enum { WIDTH, HEIGHT, DEPTH, MAXVAL, TUPLTYPE, ENDHDR };

/// BLACKANDWHITE is stored as gray samples (0 = black, unlike PBM), so it decodes like GRAYSCALE.
const pam_tuple_types: std.StaticStringMap(PixelTag) = .initComptime(.{
    .{ "BLACKANDWHITE", .g },
    .{ "GRAYSCALE", .g },
    .{ "RGB", .rgb },
    .{ "BLACKANDWHITE_ALPHA", .ga },
    .{ "GRAYSCALE_ALPHA", .ga },
    .{ "RGB_ALPHA", .rgba },
});

fn decodePamHeader(data: []const u8) Error!Header {
    var width: ?u32 = null;
    var height: ?u32 = null;
    var depth: ?u32 = null;
    var max_val: ?u32 = null;
    var tuple_type: []const u8 = "";

    var pos: usize = 2; // the rest of the magic's line parses as a blank line
    while (true) {
        const eol = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse return Error.UnexpectedEndOfData;
        const line = std.mem.trim(u8, data[pos..eol], &std.ascii.whitespace);
        pos = eol + 1;
        if (line.len == 0 or line[0] == '#') continue;

        const key_end = std.mem.indexOfAny(u8, line, &std.ascii.whitespace) orelse line.len;
        const key = std.meta.stringToEnum(PamKey, line[0..key_end]) orelse return Error.InvalidHeader;
        const value = std.mem.trim(u8, line[key_end..], &std.ascii.whitespace);
        switch (key) {
            .ENDHDR => break,
            .TUPLTYPE => tuple_type = value,
            .WIDTH => width = try parsePamUint(value),
            .HEIGHT => height = try parsePamUint(value),
            .DEPTH => depth = try parsePamUint(value),
            .MAXVAL => max_val = try parsePamUint(value),
        }
    }

    const w = width orelse return Error.InvalidHeader;
    const h = height orelse return Error.InvalidHeader;
    const d = depth orelse return Error.InvalidHeader;
    const m = max_val orelse return Error.InvalidHeader;
    try checkShape(w, h, m);
    // an unknown (or missing) tuple type is still readable when the depth implies a layout
    const tag = pam_tuple_types.get(tuple_type) orelse switch (d) {
        1 => PixelTag.g,
        2 => .ga,
        3 => .rgb,
        4 => .rgba,
        else => return Error.UnsupportedDepth,
    };
    if (tag.bytesPerPixel() != d) return Error.InvalidChannels;
    return .{ .magic = .P7, .width = w, .height = h, .tag = tag, .max_val = @intCast(m), .data_start = pos };
}

fn parsePamUint(value: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, value, 10) catch Error.InvalidNum;
}

pub fn info(data: []const u8) Error!Info {
    const hdr = try decodeHeader(data);
    return .{ .width = hdr.width, .height = hdr.height, .tag = hdr.tag, .fmt = Info.fmtFor(hdr.tag, true) };
}

/// Matches the codec signature so format modules can re-export it; needs no scratch memory.
pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) Error!void {
    _ = scratch;
    const hdr = try decodeHeader(data);
    const n_samples = @as(usize, hdr.width) * hdr.height * hdr.tag.bytesPerPixel();
    if (out.len != n_samples or inf.tag != hdr.tag) return Error.InvalidDataLen;
    switch (hdr.magic) {
        .P1 => try decodeAsciiBits(data, hdr.data_start, out),
        .P4 => try decodeBinaryBits(data[hdr.data_start..], hdr.width, out),
        .P2, .P3 => try decodeAsciiSamples(data, hdr.data_start, hdr.max_val, out),
        .P5, .P6, .P7 => try decodeBinarySamples(data[hdr.data_start..], hdr.max_val, out),
    }
}

/// Moves `pos.*` to the next non-separator byte of an ASCII raster (whitespace and
/// comments are skipped), or fails at the end of the data.
inline fn nextToken(data: []const u8, pos: *usize) Error!u8 {
    while (pos.* < data.len) {
        const c = data[pos.*];
        if (c == '#') {
            pos.* = std.mem.indexOfScalarPos(u8, data, pos.*, '\n') orelse data.len;
        } else if (std.ascii.isWhitespace(c)) {
            pos.* += 1;
        } else return c;
    }
    return Error.UnexpectedEndOfData;
}

/// P1: one '0' / '1' character per pixel; whitespace between them is optional.
fn decodeAsciiBits(data: []const u8, start: usize, out: []u8) Error!void {
    var pos = start;
    for (out) |*o| {
        o.* = switch (try nextToken(data, &pos)) {
            '0' => 255,
            '1' => 0,
            else => return Error.InvalidToken,
        };
        pos += 1;
    }
}

/// P4: 8 pixels per byte, most significant bit first, each row starting on a fresh byte.
fn decodeBinaryBits(raster: []const u8, width: u32, out: []u8) Error!void {
    // every byte's 8 pixels (1 = black), so whole bytes expand with one table load
    const table: [256][8]u8 = comptime blk: {
        @setEvalBranchQuota(256 * 8 * 4);
        var t: [256][8]u8 = undefined;
        for (&t, 0..) |*e, byte| for (e, 0..) |*o, bit| {
            o.* = if ((byte >> (7 - bit)) & 1 == 1) 0 else 255;
        };
        break :blk t;
    };
    const row_bytes = (@as(usize, width) + 7) / 8;
    const n_rows = out.len / width;
    if (raster.len < row_bytes * n_rows) return Error.UnexpectedEndOfData;
    const full = width / 8;
    for (0..n_rows) |y| {
        const src = raster[y * row_bytes ..][0..row_bytes];
        const dst = out[y * width ..][0..width];
        for (src[0..full], 0..) |byte, i| dst[i * 8 ..][0..8].* = table[byte];
        if (width % 8 != 0) @memcpy(dst[full * 8 ..], table[src[full]][0 .. width % 8]);
    }
}

fn decodeAsciiSamples(data: []const u8, start: usize, max: u16, out: []u8) Error!void {
    const scaler: Scaler = .init(max);
    var pos = start;
    var n: usize = 0;
    while (n < out.len) {
        if (data.len - pos >= block_len + 8) {
            const done = if (max == 255) try decodeBlock(true, data, &pos, scaler, out, &n) else try decodeBlock(false, data, &pos, scaler, out, &n);
            if (done) continue;
        }
        // one sample the plain way: near the end, around comments or junk, long numbers
        if (!std.ascii.isDigit(try nextToken(data, &pos))) return Error.InvalidToken;
        var v: u32 = 0;
        while (pos < data.len and std.ascii.isDigit(data[pos])) : (pos += 1) {
            v = v * 10 + (data[pos] - '0');
            // also keeps `v` from overflowing on absurdly long numbers
            if (v > max) return Error.InvalidNum;
        }
        out[n] = scaler.apply(v);
        n += 1;
    }
}

const block_len = 64;

/// Decodes the numbers in the `block_len` bytes at `pos.*` when those are only digits and
/// whitespace, the bulk of a typical file. Returns false (after the numbers before it)
/// at a number of 9+ digits, and when there is none to decode; the plain path then
/// reads the next number.
///
/// Parsing one number at a time chains every step on the previous number's length.
/// Instead, vector compares find where all of the block's numbers start and end, and
/// each is parsed on its own from an 8-byte load, so the CPU overlaps their work.
/// `identity`: maxval 255, samples need no scaling.
fn decodeBlock(comptime identity: bool, data: []const u8, pos: *usize, scaler: Scaler, out: []u8, n: *usize) Error!bool {
    // the bit order of a bool-vector bitcast follows the byte order
    if (native_endian != .little) return false;
    const V = @Vector(block_len, u8);
    const base = pos.*;
    const block: V = data[base..][0..block_len].*;
    const digit: u64 = @bitCast(block -% @as(V, @splat('0')) < @as(V, @splat(10)));
    // std.ascii.whitespace: ' ' and '\t' (9) through '\r' (13)
    const space: u64 = @as(u64, @bitCast(block == @as(V, @splat(' ')))) | @as(u64, @bitCast(block -% @as(V, @splat(9)) < @as(V, @splat(5))));
    if (digit | space != std.math.maxInt(u64)) return false;
    // `pos.*` never sits inside a number, so a digit at bit 0 starts one too
    var starts = digit & ~(digit << 1);
    var ends = digit & ~(digit >> 1); // last digits
    // a number reaching the block's end may go on: the next block starts with it
    var next = base + block_len;
    if (digit >> 63 != 0) {
        const cut = 63 - @clz(starts);
        next = base + cut;
        starts &= ~(@as(u64, 1) << @intCast(cut));
        ends &= ~(@as(u64, 1) << 63);
    }
    if (starts == 0) return false;

    // locals: through the pointers, every store to `out` would force a reload
    var count = n.*;
    defer n.* = count;
    while (starts != 0 and count < out.len) {
        const s = @ctz(starts);
        const len = @ctz(ends) - s + 1;
        starts &= starts - 1;
        ends &= ends - 1;
        if (len > 8) {
            pos.* = base + s;
            return false;
        }
        // first digit in the lowest byte; shifting the number to the top drops what
        // follows it and leaves zero bytes (leading zeros) below it
        const bytes = std.mem.readInt(u64, data[base + s ..][0..8], .little) -% ones * '0';
        const v = parse8Digits(bytes << @intCast(8 * (8 - len)));
        if (v > scaler.max) return Error.InvalidNum;
        out[count] = if (identity) @intCast(v) else scaler.apply(v);
        count += 1;
    }
    pos.* = next;
    return true;
}

/// 0x01 in every byte of a u64.
const ones: u64 = 0x0101_0101_0101_0101;

/// Eight decimal digits (values 0..9, first digit in the lowest byte) to their number:
/// adjacent pairs, then quads, then the halves are combined by multiply-and-shift.
fn parse8Digits(digits: u64) u32 {
    var v = digits;
    v = (v *% 10 +% (v >> 8)) & 0x00FF_00FF_00FF_00FF;
    v = (v *% 100 +% (v >> 16)) & 0x0000_FFFF_0000_FFFF;
    return @intCast((v *% 10000 +% (v >> 32)) & 0xFFFF_FFFF);
}

fn decodeBinarySamples(raster: []const u8, max: u16, out: []u8) Error!void {
    const scaler: Scaler = .init(max);
    // samples per step: two registers of u32 lanes (16 with AVX2)
    const L = @import("../Colors/misc.zig").N / 2;
    var i: usize = 0;
    if (max <= 255) {
        if (raster.len < out.len) return Error.UnexpectedEndOfData;
        if (max == 255) return @memcpy(out, raster[0..out.len]);
        while (i + L <= out.len) : (i += L) {
            const v: @Vector(L, u8) = raster[i..][0..L].*;
            out[i..][0..L].* = scaler.applyV(u32, L, v);
        }
        for (out[i..], raster[i..out.len]) |*o, v| o.* = scaler.apply(v);
    } else {
        if (raster.len < out.len * 2) return Error.UnexpectedEndOfData;
        while (i + L <= out.len) : (i += L) {
            const v = simd.load(L, u16, raster[i * 2 ..]);
            out[i..][0..L].* = scaler.applyV(u64, L, if (native_endian == .little) @byteSwap(v) else v);
        }
        for (out[i..], i..) |*o, k| o.* = scaler.apply(std.mem.readInt(u16, raster[k * 2 ..][0..2], .big));
    }
}

/// Sample -> 8 bits for one maxval, rounded to nearest; out-of-range binary samples
/// clamp to white. Rounding (v * 255 + max / 2) / max is done as a multiply by a
/// fixed-point reciprocal instead of a division per sample (Granlund & Montgomery:
/// with numerators below 2^n and post = n + ceil(log2(max)), mul = ceil(2^post / max)
/// gives the exact quotient).
const Scaler = struct {
    max: u32,
    half: u32,
    mul: u64,
    post: u6,

    fn init(max: u16) Scaler {
        // samples above maxval clamp to it first; it scales to 255 just like they would
        const half = max / 2;
        const n = 64 - @clz(@as(u64, 255) * max + half);
        const post: u6 = @intCast(n + std.math.log2_int_ceil(u32, max));
        return .{ .max = max, .half = half, .mul = ((@as(u64, 1) << post) + max - 1) / max, .post = post };
    }

    fn apply(s: Scaler, v: u32) u8 {
        return @intCast((@as(u64, @min(v, s.max)) * 255 + s.half) * s.mul >> s.post);
    }

    /// `apply` on `L` samples in `W` lanes: u64 always fits, u32 does for maxval <= 255
    /// (the product stays below 255.5 * 2^24 + 2^16).
    fn applyV(s: Scaler, comptime W: type, comptime L: usize, samples: anytype) @Vector(L, u8) {
        const V = @Vector(L, W);
        const v = @min(@as(V, samples), @as(V, @splat(@intCast(s.max))));
        const post: std.math.Log2Int(W) = @intCast(s.post);
        return @intCast((v * @as(V, @splat(255)) + @as(V, @splat(s.half))) * @as(V, @splat(@intCast(s.mul))) >> @splat(post));
    }
};

fn convertedPixels(img: *const Image, tag: PixelTag, gpa: std.mem.Allocator) !?Image.Pixels {
    return if (std.meta.activeTag(img.pixels) == tag) null else try img.pixels.convertV(tag, gpa);
}

/// Binary P5 (`.g`) or P6 (`.rgb`), maxval 255; other layouts are converted.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator, tag: PixelTag) !void {
    std.debug.assert(tag == .g or tag == .rgb);
    const converted = try convertedPixels(img, tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const magic = if (tag == .g) "P5" else "P6";
    try w.print("{s}\n{} {}\n255\n", .{ magic, img.width, img.height });
    try w.writeAll((converted orelse img.pixels).asBytes());
}

/// Binary P4: gray values below 128 become black.
pub fn encodePbm(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const converted = try convertedPixels(img, .g, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const gray = (converted orelse img.pixels).asBytes();
    try w.print("P4\n{} {}\n", .{ img.width, img.height });
    var row_start: usize = 0;
    while (row_start < gray.len) : (row_start += img.width) {
        const row = gray[row_start..][0..img.width];
        var x: usize = 0;
        while (x < row.len) : (x += 8) {
            var byte: u8 = 0;
            for (row[x..@min(x + 8, row.len)], 0..) |v, bit| {
                if (v < 128) byte |= @as(u8, 0x80) >> @intCast(bit);
            }
            try w.writeByte(byte);
        }
    }
}

/// The PAM layout an image is stored as: gray / RGB, keeping alpha if present.
pub fn pamTag(tag: PixelTag) PixelTag {
    return switch (tag) {
        .g, .ga, .rgb, .rgba => tag,
        .bgr, .ycbcr => .rgb,
        .bgra, .ycbcra => .rgba,
    };
}

/// P7 with maxval 255 in the layout given by `pamTag`.
pub fn encodePam(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const tag = pamTag(std.meta.activeTag(img.pixels));
    const converted = try convertedPixels(img, tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const tuple_type = switch (tag) {
        .g => "GRAYSCALE",
        .ga => "GRAYSCALE_ALPHA",
        .rgb => "RGB",
        .rgba => "RGB_ALPHA",
        else => unreachable,
    };
    try w.print("P7\nWIDTH {}\nHEIGHT {}\nDEPTH {}\nMAXVAL 255\nTUPLTYPE {s}\nENDHDR\n", .{
        img.width, img.height, tag.bytesPerPixel(), tuple_type,
    });
    try w.writeAll((converted orelse img.pixels).asBytes());
}

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

/// Decodes `file` and checks it yields exactly `expected` as `tag` pixels.
fn expectDecodes(file: []const u8, tag: PixelTag, expected: []const u8) !void {
    const inf = try info(file);
    try testing.expectEqual(tag, inf.tag);
    const out = try testing.allocator.alloc(u8, try inf.byteLen());
    defer testing.allocator.free(out);
    try decodeInto(testing.allocator, file, inf, out);
    try testing.expectEqualSlices(u8, expected, out);
}

/// `header` (ending in its single whitespace byte) followed by 8-bit `samples` stored at
/// `max_val`: 16-bit big-endian v*257 for 65535, v*max/255 for small maxvals (exact when
/// the samples are multiples of 255/max), as decimal text when `ascii`.
fn buildFile(header: []const u8, samples: []const u8, max_val: u16, ascii: bool) ![]u8 {
    var file: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer file.deinit();
    try file.writer.writeAll(header);
    for (samples, 0..) |s, i| {
        const v: u16 = @intCast(@as(u32, s) * max_val / 255);
        if (ascii) {
            // uneven spacing and line breaks: any whitespace may separate samples
            try file.writer.print("{d}{s}", .{ v, if (i % 5 == 4) "\n" else " \t" });
        } else if (max_val > 255) {
            try file.writer.writeInt(u16, v, .big);
        } else {
            try file.writer.writeByte(@intCast(v));
        }
    }
    return file.toOwnedSlice();
}

// 4x3 pixels, all multiples of 17 so they survive maxval 15 exactly
const gray_4x3 = [_]u8{ 0, 17, 34, 51, 68, 85, 102, 119, 136, 204, 238, 255 };
const rgb_4x3 = gray_4x3 ++ [_]u8{ 255, 0, 17, 238, 34, 221, 51, 204, 68, 187, 85, 170 } ++ gray_4x3;

test "netpbm graymap and pixmap variants decode to the same pixels" {
    const gpa = testing.allocator;
    for ([_]u16{ 15, 255, 65535 }) |max| {
        const Case = struct { magic: []const u8, tag: PixelTag, pixels: []const u8, ascii: bool };
        const cases = [_]Case{
            .{ .magic = "P2", .tag = .g, .pixels = &gray_4x3, .ascii = true },
            .{ .magic = "P5", .tag = .g, .pixels = &gray_4x3, .ascii = false },
            .{ .magic = "P3", .tag = .rgb, .pixels = &rgb_4x3, .ascii = true },
            .{ .magic = "P6", .tag = .rgb, .pixels = &rgb_4x3, .ascii = false },
        };
        for (cases) |case| {
            const header = try std.fmt.allocPrint(gpa, "{s}\n4 3\n{d}\n", .{ case.magic, max });
            defer gpa.free(header);
            const file = try buildFile(header, case.pixels, max, case.ascii);
            defer gpa.free(file);
            expectDecodes(file, case.tag, case.pixels) catch |err| {
                std.debug.print("failed: {s} maxval {d}\n", .{ case.magic, max });
                return err;
            };
        }
        for ([_]PixelTag{ .g, .rgb }) |tag| {
            const header = try std.fmt.allocPrint(gpa, "P7\nWIDTH 4\nHEIGHT 3\nDEPTH {d}\nMAXVAL {d}\nTUPLTYPE {s}\nENDHDR\n", .{
                tag.bytesPerPixel(), max, if (tag == .g) "GRAYSCALE" else "RGB",
            });
            defer gpa.free(header);
            const pixels: []const u8 = if (tag == .g) &gray_4x3 else &rgb_4x3;
            const file = try buildFile(header, pixels, max, false);
            defer gpa.free(file);
            try expectDecodes(file, tag, pixels);
        }
    }
}

fn mapBits(comptime bits: []const u8, black: u8, white: u8) [bits.len]u8 {
    var out: [bits.len]u8 = undefined;
    for (&out, bits) |*o, b| o.* = if (b == '1') black else white;
    return out;
}

test "netpbm bitmap variants: P1, P4, PAM BLACKANDWHITE, P5 maxval 1" {
    // 10x2 so P4 rows need padding bits; 1 = black in PBM
    const bits = "1010000011" ++ "0111111110";
    const gray = comptime mapBits(bits, 0, 255);

    // P1 digits need no separators; comments may sit between them
    try expectDecodes("P1\n10 2\n10100 00011\n# row 2\n0111111110\n", .g, &gray);
    try expectDecodes("P1 10 2 10100000110111111110", .g, &gray);
    // row 0: 1010 0000 | 11xx xxxx, row 1: 0111 1111 | 10xx xxxx (padding bits are ignored)
    try expectDecodes("P4\n10 2\n" ++ [_]u8{ 0xA0, 0xC0, 0x7F, 0xBF }, .g, &gray);

    // the gray formats store white as maxval instead
    const white = comptime mapBits(bits, 0, 1);
    try expectDecodes("P5 10 2 1\n" ++ white, .g, &gray);
    try expectDecodes("P7\nWIDTH 10\nHEIGHT 2\nDEPTH 1\nMAXVAL 1\nTUPLTYPE BLACKANDWHITE\nENDHDR\n" ++ white, .g, &gray);

    try testing.expectError(Error.InvalidToken, expectDecodes("P1 2 1 12", .g, &gray));
    try testing.expectError(Error.UnexpectedEndOfData, expectDecodes("P4 10 2\n" ++ [_]u8{ 0xA0, 0xC0, 0x7F }, .g, &gray));
}

test "netpbm PAM alpha layouts" {
    const gpa = testing.allocator;
    const ga = [_]u8{ 0, 255, 17, 0, 136, 68, 255, 119 };
    const rgba = [_]u8{ 255, 0, 17, 255, 0, 34, 68, 0, 85, 102, 119, 136, 255, 255, 255, 17 };
    const Case = struct { tuple_type: []const u8, tag: PixelTag, pixels: []const u8 };
    const cases = [_]Case{
        .{ .tuple_type = "GRAYSCALE_ALPHA", .tag = .ga, .pixels = &ga },
        .{ .tuple_type = "RGB_ALPHA", .tag = .rgba, .pixels = &rgba },
        // unknown tuple types fall back to the depth
        .{ .tuple_type = "SOMETHING_ELSE", .tag = .rgba, .pixels = &rgba },
    };
    for (cases) |case| {
        for ([_]u16{ 15, 255, 65535 }) |max| {
            // keywords in any order, comments and blank lines allowed
            const header = try std.fmt.allocPrint(gpa, "P7\n# made by hand\nTUPLTYPE {s}\nMAXVAL {d}\n\n  DEPTH {d}\nHEIGHT 2\nWIDTH 2\nENDHDR\n", .{
                case.tuple_type, max, case.tag.bytesPerPixel(),
            });
            defer gpa.free(header);
            const file = try buildFile(header, case.pixels, max, false);
            defer gpa.free(file);
            try expectDecodes(file, case.tag, case.pixels);
        }
    }

    const bw_alpha = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 2\nMAXVAL 1\nTUPLTYPE BLACKANDWHITE_ALPHA\nENDHDR\n" ++ [_]u8{ 1, 0, 0, 1 };
    try expectDecodes(bw_alpha, .ga, &.{ 255, 0, 0, 255 });
    try testing.expectError(Error.InvalidChannels, info("P7\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"));
    try testing.expectError(Error.InvalidHeader, info("P7\nWIDTH 1\nHEIGHT 1\nMAXVAL 255\nENDHDR\n"));
    try testing.expectError(Error.InvalidHeader, info("P7\nWIDTH 1\nBOGUS 1\nENDHDR\n"));
}

test "netpbm maxval scaling rounds to nearest" {
    try expectDecodes("P2 4 1 3\n0 1 2 3\n", .g, &.{ 0, 85, 170, 255 });
    try expectDecodes("P2 3 1 2\n0 1 2\n", .g, &.{ 0, 128, 255 });
    // 16-bit with an odd maxval: 1 -> 0.255, 2 -> 0.51, 500 -> 127.5, 998 -> 254.49
    try expectDecodes("P5 5 1 1000\n" ++ [_]u8{ 0, 1, 0, 2, 0x01, 0xF4, 0x03, 0xE6, 0x03, 0xE8 }, .g, &.{ 0, 1, 128, 254, 255 });
    try expectDecodes("P6 1 1 65535\n" ++ [_]u8{ 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00 }, .rgb, &.{ 255, 128, 0 });
    try testing.expectError(Error.InvalidNum, expectDecodes("P2 1 1 3\n4\n", .g, &.{0}));
    try testing.expectError(Error.InvalidMaxVal, info("P5 1 1 65536\n"));
    try testing.expectError(Error.InvalidMaxVal, info("P5 1 1 0\n"));
}

test "netpbm header comments and whitespace" {
    try expectDecodes("P2\n# comment\n3 2 # trailing\n15\n0 15 7\n# mid\n1 2 3\n", .g, &.{ 0, 255, 119, 17, 34, 51 });
    // comments anywhere, CR/LF and tabs as separators, a comment glued to the maxval
    const raster = [_]u8{ 10, 32, 9, 13, 200, 1 }; // first samples look like whitespace
    try expectDecodes("P6#a\r\n\t2#b\n  1\r\n#c\n255\n" ++ raster, .rgb, &raster);
    try expectDecodes("P6 2 1 255#comment\n" ++ raster, .rgb, &raster);
    // exactly one whitespace byte separates the header from binary data
    try expectDecodes("P5 2 1 255\n\n ", .g, &.{ 10, 32 });
    try testing.expectError(Error.InvalidToken, info("P5 2 1 255x"));
    try testing.expectError(Error.UnexpectedEndOfData, info("P5 2 1 255"));
    try testing.expectError(Error.UnexpectedSignature, info("P8 1 1 255\n"));
    try testing.expectError(Error.InvalidDimensions, info("P5 0 1 255\n"));
}

test "netpbm encoders round trip" {
    const gpa = testing.allocator;
    const Case = struct { tag: PixelTag, pixels: []const u8, encoder: enum { pbm, pgm, ppm, pam } };
    const ga = [_]u8{ 0, 255, 17, 0, 136, 68, 255, 119, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const bitmap = [_]u8{ 0, 255, 255, 0, 0, 0, 255, 255, 0, 255, 0, 255 };
    const cases = [_]Case{
        .{ .tag = .g, .pixels = &bitmap, .encoder = .pbm },
        .{ .tag = .g, .pixels = &gray_4x3, .encoder = .pgm },
        .{ .tag = .rgb, .pixels = &rgb_4x3, .encoder = .ppm },
        .{ .tag = .g, .pixels = &gray_4x3, .encoder = .pam },
        .{ .tag = .ga, .pixels = &ga, .encoder = .pam },
        .{ .tag = .rgb, .pixels = &rgb_4x3, .encoder = .pam },
        .{ .tag = .rgba, .pixels = &(rgb_4x3 ++ gray_4x3), .encoder = .pam },
    };
    for (cases) |case| {
        const bytes = try gpa.dupe(u8, case.pixels);
        defer gpa.free(bytes);
        const img: Image = .{ .width = 4, .height = 3, .pixels = .fromBytes(case.tag, bytes), .fmt = Info.fmtFor(case.tag, true) };
        var file: std.Io.Writer.Allocating = .init(gpa);
        defer file.deinit();
        switch (case.encoder) {
            .pbm => try encodePbm(&img, &file.writer, gpa),
            .pgm => try encode(&img, &file.writer, gpa, .g),
            .ppm => try encode(&img, &file.writer, gpa, .rgb),
            .pam => try encodePam(&img, &file.writer, gpa),
        }
        try expectDecodes(file.written(), case.tag, case.pixels);
    }
}

fn readTestFile(io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .unlimited);
}

/// Encodes `img` as `tag`'s format and decodes it back through the `Image` codec table.
fn roundTrip(img: *const Image, tag: Image.ImageTag) !Image {
    var file: std.Io.Writer.Allocating = .init(testing.allocator);
    defer file.deinit();
    try img.encode(tag, &file.writer, testing.allocator);
    return Image.decode(tag, testing.allocator, file.written());
}

// The reference PPM / PGM (written by Pillow) re-expressed in every other netpbm encoding.
test "netpbm reference files in every encoding" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for ([_][]const u8{ "src/Data/Read/Gradient.ppm", "src/Data/Read/Gradient.pgm" }) |path| {
        const data = try readTestFile(io, path);
        defer gpa.free(data);
        const ref = try Image.decode(.ppm, gpa, data);
        defer ref.deinit(gpa);
        const tag = std.meta.activeTag(ref.pixels);
        const pixels = ref.pixels.asBytes();
        const n_channels: u8 = @intCast(tag.bytesPerPixel());
        const ascii_magic = if (tag == .g) "P2" else "P3";
        const binary_magic = if (tag == .g) "P5" else "P6";

        for ([_]u16{ 255, 65535 }) |max| {
            for ([_]bool{ true, false }) |ascii| {
                const header = try std.fmt.allocPrint(gpa, "{s}\n{d} {d}\n{d}\n", .{
                    if (ascii) ascii_magic else binary_magic, ref.width, ref.height, max,
                });
                defer gpa.free(header);
                const file = try buildFile(header, pixels, max, ascii);
                defer gpa.free(file);
                try expectDecodes(file, tag, pixels);
            }
            const header = try std.fmt.allocPrint(gpa, "P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH {d}\nMAXVAL {d}\nENDHDR\n", .{
                ref.width, ref.height, n_channels, max,
            });
            defer gpa.free(header);
            const file = try buildFile(header, pixels, max, false);
            defer gpa.free(file);
            try expectDecodes(file, tag, pixels);
        }

        // encoders, reached through the codec table by file extension tag
        for ([_]Image.ImageTag{ .pam, .pnm, .ppm, .pgm }) |img_tag| {
            const back = try roundTrip(&ref, img_tag);
            defer back.deinit(gpa);
            try Image.expectSimilar(gpa, &ref, &back, if (img_tag == .pgm) .g else tag, 0);
        }
        const with_alpha = try ref.convert(if (tag == .g) .ga else .rgba, gpa);
        defer with_alpha.deinit(gpa);
        const pam = try roundTrip(&with_alpha, .pam);
        defer pam.deinit(gpa);
        try testing.expectEqual(std.meta.activeTag(with_alpha.pixels), std.meta.activeTag(pam.pixels));
        try testing.expectEqualSlices(u8, with_alpha.pixels.asBytes(), pam.pixels.asBytes());

        // PBM keeps only a threshold of the gray image
        const gray = try ref.convert(.g, gpa);
        defer gray.deinit(gpa);
        const pbm = try roundTrip(&gray, .pbm);
        defer pbm.deinit(gpa);
        for (gray.pixels.asBytes(), pbm.pixels.asBytes()) |g, b| try testing.expectEqual(@as(u8, if (g < 128) 0 else 255), b);
    }
}

/// The scaling every sample went through before `Scaler`: one division each.
fn referenceScale(v: u32, max: u32) u8 {
    return @intCast(@min(255, (v * 255 + max / 2) / max));
}

test "netpbm Scaler equals the division for every sample" {
    // every 8-bit maxval and a spread of 16-bit ones, each against every 16-bit sample
    var maxes: [255 + 12]u16 = undefined;
    for (maxes[0..255], 1..) |*m, v| m.* = @intCast(v);
    maxes[255..].* = .{ 256, 257, 300, 511, 1000, 1023, 4095, 9999, 32767, 32768, 65534, 65535 };
    for (maxes) |max| {
        const s: Scaler = .init(max);
        var v: u32 = 0;
        while (v <= 0xFFFF) : (v += 1) {
            const want = referenceScale(v, max);
            try testing.expectEqual(want, s.apply(v));
            if (v % 16 == 0 and v + 16 <= 0x10000) {
                const lanes = std.simd.iota(u32, 16) + @as(@Vector(16, u32), @splat(v));
                const wide: [16]u8 = s.applyV(u64, 16, lanes);
                try testing.expectEqual(want, wide[0]);
                for (wide, 0..) |got, k| try testing.expectEqual(referenceScale(v + @as(u32, @intCast(k)), max), got);
                if (max <= 255 and v < 256) {
                    const narrow: [16]u8 = s.applyV(u32, 16, @as(@Vector(16, u8), @intCast(lanes)));
                    try testing.expectEqualSlices(u8, &wide, &narrow);
                }
            }
        }
    }
}

/// The original sample-at-a-time raster decoders, kept as the oracle for the faster ones.
fn decodeReference(data: []const u8, out: []u8) Error!void {
    const hdr = try decodeHeader(data);
    switch (hdr.magic) {
        .P1 => {
            var pos = hdr.data_start;
            for (out) |*o| {
                pos = skipWhitespaceAndComments(data, pos);
                if (pos >= data.len) return Error.UnexpectedEndOfData;
                o.* = switch (data[pos]) {
                    '0' => 255,
                    '1' => 0,
                    else => return Error.InvalidToken,
                };
                pos += 1;
            }
        },
        .P4 => {
            const raster = data[hdr.data_start..];
            const row_bytes = (@as(usize, hdr.width) + 7) / 8;
            if (raster.len < row_bytes * hdr.height) return Error.UnexpectedEndOfData;
            for (0..hdr.height) |y| for (out[y * hdr.width ..][0..hdr.width], 0..) |*o, x| {
                o.* = if ((raster[y * row_bytes + x / 8] >> @intCast(7 - x % 8)) & 1 == 1) 0 else 255;
            };
        },
        .P2, .P3 => {
            var pos = hdr.data_start;
            for (out) |*o| {
                const v = try readUint(data, &pos);
                if (v > hdr.max_val) return Error.InvalidNum;
                o.* = referenceScale(v, hdr.max_val);
            }
        },
        .P5, .P6, .P7 => {
            const raster = data[hdr.data_start..];
            if (hdr.max_val <= 255) {
                if (raster.len < out.len) return Error.UnexpectedEndOfData;
                for (out, raster[0..out.len]) |*o, v| o.* = referenceScale(v, hdr.max_val);
            } else {
                if (raster.len < out.len * 2) return Error.UnexpectedEndOfData;
                for (out, 0..) |*o, i| o.* = referenceScale(std.mem.readInt(u16, raster[i * 2 ..][0..2], .big), hdr.max_val);
            }
        },
    }
}

test "netpbm raster decoders match the sample-at-a-time reference" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x9B3);
    const rand = prng.random();
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    const magics = [_]Magic{ .P1, .P2, .P3, .P4, .P5, .P6 };
    var decoded: usize = 0;
    for (0..3000) |iter| {
        const magic = magics[iter % magics.len];
        const width = rand.intRangeAtMost(u32, 1, 70);
        const height = rand.intRangeAtMost(u32, 1, 4);
        const max: u16 = switch (rand.uintLessThan(u8, 4)) {
            0 => 255,
            1 => 65535,
            2 => rand.intRangeAtMost(u16, 1, 254),
            else => rand.intRangeAtMost(u16, 256, 65534),
        };
        const n_samples = @as(usize, width) * height * @as(usize, if (magic == .P3 or magic == .P6) 3 else 1);
        file.clearRetainingCapacity();
        const w = &file.writer;
        switch (magic) {
            .P1, .P4 => try w.print("{t}\n{} {}\n", .{ magic, width, height }),
            else => try w.print("{t}\n{} {}\n{}\n", .{ magic, width, height, max }),
        }
        // ASCII samples with uneven separators and comments; in some files one bad
        // token (junk, or a value above maxval). Binary samples may exceed maxval.
        const bad_at = if (rand.uintLessThan(u8, 8) == 0) rand.uintLessThan(usize, n_samples) else n_samples;
        if (magic == .P4) {
            for (0..(width + 7) / 8 * height) |_| try w.writeByte(rand.int(u8));
        } else for (0..n_samples) |i| switch (magic) {
            .P1 => try w.writeAll(if (i == bad_at) "2" else switch (rand.uintLessThan(u8, 20)) {
                0 => " #c 0\n1",
                1...8 => "1 ",
                else => "0",
            }),
            .P2, .P3 => {
                const v = if (i == bad_at) @as(u32, max) + 1 else rand.uintAtMost(u32, max);
                // leading zeros: 8 digits still fit one 8-byte load, 10 do not
                switch (rand.uintLessThan(u8, 30)) {
                    0 => try w.print("{d:0>8}", .{v}),
                    1 => try w.print("{d:0>10}", .{v}),
                    else => try w.print("{}", .{v}),
                }
                try w.writeAll(if (i + 1 == bad_at and rand.boolean()) "x" else switch (rand.uintLessThan(u8, 20)) {
                    0 => "#comment 9 9\n",
                    1...4 => "\n",
                    5...8 => "\t ",
                    else => " ",
                });
            },
            else => if (max > 255) try w.writeInt(u16, rand.int(u16), .big) else try w.writeByte(rand.int(u8)),
        };
        // sometimes cut the raster short
        const bytes = file.written();
        const keep = if (rand.uintLessThan(u8, 10) == 0) rand.uintAtMost(usize, bytes.len) else bytes.len;
        const data = bytes[0..keep];

        const inf = info(data) catch continue;
        const len = try inf.byteLen();
        const ours = try gpa.alloc(u8, len);
        defer gpa.free(ours);
        const theirs = try gpa.alloc(u8, len);
        defer gpa.free(theirs);
        const r1 = decodeInto(gpa, data, inf, ours);
        const r2 = decodeReference(data, theirs);
        if (r2) |_| {
            r1 catch |err| {
                std.debug.print("iter {}: {t} {}x{} max {}: reference decoded, new decoder failed with {t}\n", .{ iter, magic, width, height, max, err });
                return err;
            };
            testing.expectEqualSlices(u8, theirs, ours) catch |err| {
                std.debug.print("iter {}: {t} {}x{} max {}\n", .{ iter, magic, width, height, max });
                return err;
            };
            decoded += 1;
        } else |want| try testing.expectError(want, r1);
    }
    try testing.expect(decoded > 1500);
}

test "netpbm binary samples at vector-edge lengths vs per-sample scaling" {
    const L = @import("../Colors/misc.zig").N / 2; // as decodeBinarySamples
    var prng: std.Random.DefaultPrng = .init(16);
    const rand = prng.random();
    var raster: [2 * (4 * L + 7)]u8 = undefined;
    var out: [4 * L + 8]u8 = undefined;
    for ([_]usize{ 1, 2, 7, 15, 17, 33, L - 1, L, L + 1, 2 * L + 3, 4 * L + 7 }) |n| {
        for ([_]u16{ 1, 100, 254, 256, 1000, 65535 }) |max| {
            const s: Scaler = .init(max);
            const wide = max > 255;
            const len = if (wide) 2 * n else n;
            for (raster[0..len], 0..) |*b, i| b.* = if (wide and i % 2 == 0) rand.uintAtMost(u8, @intCast(max >> 8)) else rand.uintAtMost(u8, @intCast(@min(max, 255)));
            @memset(&out, 0xAA);
            try decodeBinarySamples(raster[0..len], max, out[0..n]);
            for (0..n) |k| {
                const v: u32 = if (wide) std.mem.readInt(u16, raster[k * 2 ..][0..2], .big) else raster[k];
                try testing.expectEqual(s.apply(v), out[k]);
            }
            try testing.expectEqual(@as(u8, 0xAA), out[n]);
        }
    }
}
