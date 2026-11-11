const std = @import("std");
const Error = @import("../error.zig").Error;

const Header = @import("header.zig");

const Image = @import("../../root.zig");
const RGB = @import("../../Colors/rgb.zig").RGB;
const RGBA = @import("../../Colors/rgba.zig").RGBA;
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;


const findFirst64Matches = @import("matches.zig").findFirst64Matches;

const HASH_TABLE_SIZE = 64;
pub const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub const ByteTags = enum(u8) {
    rgb = 0xFE,
    rgba = 0xFF,
    _,
};

pub const BitTags = enum(u2) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

pub fn hashRGB(rgb: RGB) u8 {
    return (rgb.r *% 3 +% //
        rgb.g *% 5 +% //
        rgb.b *% 7 +% //
        @as(u8, 255) *% 11) & //
        @as(u8, 63);
}

pub fn hashRGBA(rgba: RGBA) u8 {
    return (rgba.r *% 3 +% //
        rgba.g *% 5 +% //
        rgba.b *% 7 +% //
        rgba.a *% 11) & //
        @as(u8, 63);
}

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data);
    const tag: PixelTag = switch (hdr.channel) {
        .rgb => .rgb,
        .rgba => .rgba,
    };
    return .{
        .width = hdr.width,
        .height = hdr.height,
        .tag = tag,
        .fmt = Info.fmtFor(tag, hdr.colorspace == .srgb),
    };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    _ = scratch;
    if (data.len < Header.SIZE + END_MARKER.len) return Error.UnexpectedEndOfData;
    if (!std.mem.eql(u8, data[data.len - END_MARKER.len ..], &END_MARKER)) return Error.InvalidEndMarker;
    const body = data[Header.SIZE .. data.len - END_MARKER.len];
    switch (inf.tag) {
        .rgb => try decodeOps(3, body, out),
        .rgba => try decodeOps(4, body, out),
        else => return Error.UnsupportedPixels,
    }
}

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const tag: PixelTag = switch (img.pixels) {
        .g, .rgb, .bgr, .ycbcr => .rgb,
        .ga, .rgba, .bgra, .ycbcra => .rgba,
    };
    const converted = if (std.meta.activeTag(img.pixels) == tag) null else try img.pixels.convertV(tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const pixels = converted orelse img.pixels;
    const hdr: Header = try .fromImage(img, tag);
    try hdr.encode(w);
    switch (pixels) {
        .rgb => |rgb| try encodeRgb(w, rgb),
        .rgba => |rgba| try encodeRgba(w, rgba),
        else => unreachable,
    }
    try w.writeAll(&END_MARKER);
}

/// Decodes the op stream `data` into `out`, `ch` bytes per pixel.
/// Most of the image goes through ops with no bounds checks at all: an op is
/// only started there while the longest op (5 bytes) fits in the input and the
/// longest run (62 pixels), plus the overshoot of whole-vector stores, fits in
/// the output. The tail runs the same ops with every check, so malformed
/// streams fail exactly as before.
fn decodeOps(comptime ch: usize, data: []const u8, out: []u8) !void {
    const n = out.len / ch;
    // Plain locals, one per channel: LLVM keeps them in registers, so diff and
    // luma are a single add per channel on the pixel-to-pixel chain. (Held in a
    // struct or a [4]u8 they were spilled and reloaded on every pixel.)
    // An rgb stream never changes alpha, so its hash sees 255 there.
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 255;
    // packed as in memory (r | g << 8 | ...), so an entry is one load or store;
    // the spec starts the index at all zeros (transparent black)
    var index: [64]u32 = @splat(0);
    var i: usize = 0; // next op byte
    var j: usize = 0; // next pixel
    // the longest run, plus 16 pixels for vector stores past a pixel or run
    // (at most 31 bytes)
    const margin = 62 + 16;
    inline for (.{ false, true }) |checked| {
        while (if (checked) i < data.len else i + 5 <= data.len and j + margin <= n) {
            const b1 = data[i];
            if (b1 >= @intFromEnum(ByteTags.rgb)) {
                if (b1 == @intFromEnum(ByteTags.rgba)) {
                    if (ch == 3) return Error.InvalidChannels;
                    if (checked and i + 4 >= data.len) return Error.OutOfBounds;
                    a = data[i + 4];
                } else if (checked and i + 3 >= data.len) return Error.OutOfBounds;
                r = data[i + 1];
                g = data[i + 2];
                b = data[i + 3];
                i += if (b1 == @intFromEnum(ByteTags.rgba)) 5 else 4;
            } else switch (@as(BitTags, @enumFromInt(b1 >> 6))) {
                .index => {
                    const e = index[b1]; // the tag bits are 0: b1 is the index
                    r = @truncate(e);
                    g = @truncate(e >> 8);
                    b = @truncate(e >> 16);
                    a = @truncate(e >> 24);
                    i += 1;
                },
                .diff => {
                    r = r +% ((b1 >> 4) & 3) -% 2;
                    g = g +% ((b1 >> 2) & 3) -% 2;
                    b = b +% (b1 & 3) -% 2;
                    i += 1;
                },
                .luma => {
                    if (checked and i + 1 >= data.len) return Error.OutOfBounds;
                    const b2 = data[i + 1];
                    const dg = b1 & 0x3F;
                    r = r +% (b2 >> 4) +% dg -% 40;
                    g = g +% dg -% 32;
                    b = b +% (b2 & 0x0F) +% dg -% 40;
                    i += 2;
                },
                .run => {
                    const run: usize = (b1 & 0x3F) + 1;
                    if (checked and j + run > n) return Error.OutOfBounds;
                    fillRun(ch, checked, out[j * ch ..], pack(r, g, b, a), run);
                    j += run;
                    i += 1;
                    continue; // a run repeats the previous pixel: the index already has it
                },
            }
            const word = pack(r, g, b, a);
            index[(r *% 3 +% g *% 5 +% b *% 7 +% a *% 11) & 63] = word;
            if (checked) {
                if (j >= n) return Error.OutOfBounds;
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, word, .little);
                out[j * ch ..][0..ch].* = bytes[0..ch].*;
            } else {
                // all 4 bytes even for rgb: one store, the extra byte is rewritten next
                std.mem.writeInt(u32, out[j * ch ..][0..4], word, .little);
            }
            j += 1;
        }
    }
    if (j != n) return Error.InvalidNumOfPixels;
}

/// r | g << 8 | b << 16 | a << 24: the channels in memory order
fn pack(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) | @as(u32, g) << 8 | @as(u32, b) << 16 | @as(u32, a) << 24;
}

/// Writes `run` copies of pixel `word` at the start of `at`. Unchecked, this
/// stores whole vectors of the repeating pattern, overshooting the run by up to
/// 31 bytes that later pixels overwrite.
inline fn fillRun(comptime ch: usize, comptime checked: bool, at: []u8, word: u32, run: usize) void {
    if (checked) {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        for (0..run) |k| at[k * ch ..][0..ch].* = bytes[0..ch].*;
        return;
    }
    // The pattern is built in general registers and stored as a typed vector:
    // LLVM turns a byte shuffle, or a byte array built from integers, back into
    // one store per byte.
    if (ch == 4) {
        // fixed: 32-byte stores, the overshoot the callers' 31 bytes of slack allow
        const v: @Vector(8, u32) = @splat(std.mem.nativeToLittle(u32, word));
        var k: usize = 0;
        while (k < run * 4) : (k += 32) std.mem.bytesAsValue(@Vector(8, u32), at[k..][0..32]).* = v;
        return;
    }
    // 16 bytes of the pattern hold 5 rgb pixels and a byte (fixed: the 15-byte period)
    const p: u64 = word & 0xFF_FFFF;
    const lo = p | p << 24 | p << 48; // r g b r g b r g
    const hi = p >> 16 | p << 8 | p << 32 | p << 56; // b r g b r g b r
    const v: @Vector(2, u64) = .{ std.mem.nativeToLittle(u64, lo), std.mem.nativeToLittle(u64, hi) };
    var k: usize = 0;
    while (k < run * 3) : (k += 15) std.mem.bytesAsValue(@Vector(2, u64), at[k..][0..16]).* = v;
}

fn encodeRgb(w: *std.Io.Writer, rgbs: []RGB) !void {
    var px: RGB = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var prev: RGB = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var table: [HASH_TABLE_SIZE]RGB = @splat(.{
        .r = 0,
        .g = 0,
        .b = 0,
    });
    // A decoder starts the index at transparent black, which an opaque rgb pixel
    // never equals: only slots this encoder has written may be referenced.
    var filled: u64 = 0;

    var i: usize = 0;
    const len = rgbs.len;
    while (i < len) : (i += 1) {
        px = rgbs[i];
        defer prev = px;
        const n = findFirst64Matches(RGB, rgbs[i..], prev);
        if (n > 1) {
            const run = @min(n, 62) - 1; // 1..62
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            i += run;
            continue;
        }

        const index = hashRGB(px);
        if (filled >> @intCast(index) & 1 == 1 and table[index].eql(px)) {
            const byte = (@as(u8, @intFromEnum(BitTags.index)) << 6) | index;
            try w.writeByte(byte);
            continue;
        }
        table[index] = px;
        filled |= @as(u64, 1) << @intCast(index);

        const drgb: RGB = .{
            .r = px.r -% prev.r +% 2,
            .g = px.g -% prev.g +% 2,
            .b = px.b -% prev.b +% 2,
        };
        if ((drgb.r < 4) and (drgb.g < 4) and (drgb.b < 4)) {
            const byte = (@as(u8, @intFromEnum(BitTags.diff)) << 6) | //
                (drgb.r & 0x03) << 4 | //
                (drgb.g & 0x03) << 2 | //
                (drgb.b & 0x03);
            try w.writeByte(byte);

            continue;
        }

        const dg2 = drgb.g +% 30;
        const drdg = drgb.r -% drgb.g +% 8;
        const dbdg = drgb.b -% drgb.g +% 8;
        if (dg2 < 64 and drdg < 16 and dbdg < 16) {
            const byte1 = (@as(u8, @intFromEnum(BitTags.luma)) << 6) | dg2;
            const byte2 = (drdg << 4) | dbdg;
            try w.writeByte(byte1);
            try w.writeByte(byte2);
            continue;
        }

        const byte = @as(u8, @intFromEnum(ByteTags.rgb));
        try w.writeByte(byte);
        try w.writeByte(px.r);
        try w.writeByte(px.g);
        try w.writeByte(px.b);
    }
}

fn encodeRgba(w: *std.Io.Writer, rgbas: []RGBA) !void {
    var px: RGBA = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var prev: RGBA = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var table: [HASH_TABLE_SIZE]RGBA = @splat(.{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 0, // the spec starts the index at all zeros
    });
    var i: usize = 0;

    while (i < rgbas.len) : (i += 1) {
        px = rgbas[i];
        defer prev = px;

        const n = findFirst64Matches(RGBA, rgbas[i..], prev);
        if (n > 1) {
            const run = @min(n, 62) - 1;
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            i += run;
            continue;
        }

        const index = hashRGBA(px);
        if (table[index].eql(px)) {
            const byte = @as(u8, @intFromEnum(BitTags.index)) << 6 | index;
            try w.writeByte(byte);
            continue;
        }
        table[index] = px;

        if (px.a == prev.a) {
            const dr = px.r -% prev.r;
            const dg = px.g -% prev.g;
            const db = px.b -% prev.b;

            if ((dr +% 2) < 4 and (dg +% 2) < 4 and (db +% 2) < 4) {
                const byte = @as(u8, //
                    @intFromEnum(BitTags.diff)) << 6 | //
                    (((dr +% 2) & 0x03) << 4) | //
                    (((dg +% 2) & 0x03) << 2) | //
                    ((db +% 2) & 0x03);
                try w.writeByte(byte);
                continue;
            }

            const dg2 = dg +% 32;
            const drdg = dr -% dg +% 8;
            const dbdg = db -% dg +% 8;
            if (dg2 < 64 and drdg < 16 and dbdg < 16) {
                const byte1 = (@as(u8, @intFromEnum(BitTags.luma)) << 6) | dg2;
                const byte2 = (drdg << 4) | dbdg;
                try w.writeByte(byte1);
                try w.writeByte(byte2);
                continue;
            }

            const byte1 = @intFromEnum(ByteTags.rgb);
            try w.writeByte(byte1);
            try w.writeByte(px.r);
            try w.writeByte(px.g);
            try w.writeByte(px.b);
        } else {
            const byte1 = @intFromEnum(ByteTags.rgba);
            try w.writeByte(byte1);
            try w.writeByte(px.r);
            try w.writeByte(px.g);
            try w.writeByte(px.b);
            try w.writeByte(px.a);
        }
    }
}

/// Runs the oracle and `decodeOps` on the same stream: both must fail with the
/// same error, or both succeed with the same pixels.
fn expectMatchesOracle(gpa: std.mem.Allocator, comptime ch: usize, body: []const u8, n_pixels: usize) !void {
    const scalar = @import("scalar.zig");
    const want = try gpa.alloc(u8, n_pixels * ch);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, n_pixels * ch);
    defer gpa.free(got);
    const want_result = if (ch == 3) scalar.decodeRgb(body, @ptrCast(want)) else scalar.decodeRgba(body, @ptrCast(want));
    const got_result = decodeOps(ch, body, got);
    if (want_result) |_| {
        try got_result;
        try std.testing.expectEqualSlices(u8, want, got);
    } else |err| try std.testing.expectError(err, got_result);
}

test "qoi decoder matches the scalar oracle on the fixtures" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    inline for (.{ "BasicArt.qoi", "BasicDecodeRGB.qoi", "BasicDecodeRGBA.qoi" }) |name| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, "src/Data/Read/" ++ name, gpa, .unlimited);
        defer gpa.free(data);
        const inf = try info(data);
        const body = data[Header.SIZE .. data.len - END_MARKER.len];
        switch (inf.tag) {
            .rgb => try expectMatchesOracle(gpa, 3, body, inf.width * inf.height),
            .rgba => try expectMatchesOracle(gpa, 4, body, inf.width * inf.height),
            else => unreachable,
        }
    }
}

test "qoi decoder matches the scalar oracle on random op streams" {
    // Random ops of every kind, then the pixel count is perturbed and the stream
    // sometimes cut mid-op, so the fast loop, the checked tail and every error
    // (overflowing run or pixel, truncated op, short image, rgba op in rgb) occur.
    const gpa = std.testing.allocator;
    var rng: std.Random.DefaultPrng = .init(0x901);
    const random = rng.random();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (0..400) |round| {
        stream.clearRetainingCapacity();
        const n_ops = random.uintLessThan(usize, if (round % 4 == 0) 40 else 1500);
        var n_pixels: usize = 0;
        for (0..n_ops) |_| switch (random.uintLessThan(u8, 12)) {
            0, 1 => try stream.append(gpa, random.uintLessThan(u8, 64)), // index
            2, 3 => try stream.append(gpa, 0x40 | random.uintLessThan(u8, 64)), // diff
            4, 5 => try stream.appendSlice(gpa, &.{ 0x80 | random.uintLessThan(u8, 64), random.int(u8) }), // luma
            6, 7, 8 => {
                const run = random.uintLessThan(u8, 62); // 0..61, i.e. 1..62 pixels
                try stream.append(gpa, 0xC0 | run);
                n_pixels += run;
            },
            9, 10 => try stream.appendSlice(gpa, &.{ 0xFE, random.int(u8), random.int(u8), random.int(u8) }),
            else => try stream.appendSlice(gpa, &.{ 0xFF, random.int(u8), random.int(u8), random.int(u8), random.int(u8) }),
        };
        n_pixels += n_ops;
        var body = stream.items;
        if (random.uintLessThan(u8, 8) == 0 and body.len > 0) body = body[0 .. body.len - 1 - random.uintLessThan(usize, @min(body.len, 4))];
        const n = switch (random.uintLessThan(u8, 6)) {
            0 => n_pixels -| random.uintLessThan(usize, 70),
            1 => n_pixels + random.uintLessThan(usize, 70),
            else => n_pixels,
        };
        try expectMatchesOracle(gpa, 4, body, n);
        // rgb streams: the same, with and without the rgba ops it must reject
        try expectMatchesOracle(gpa, 3, body, n);
        var rgb_only: std.ArrayList(u8) = .empty;
        defer rgb_only.deinit(gpa);
        var k: usize = 0;
        var rgb_pixels = n;
        while (k < body.len) {
            const len: usize = switch (body[k]) {
                0xFF => 5,
                0xFE => 4,
                0x80...0xBF => 2,
                else => 1,
            };
            if (k + len > body.len) break;
            if (body[k] == 0xFF) rgb_pixels -|= 1 else try rgb_only.appendSlice(gpa, body[k..][0..len]);
            k += len;
        }
        try expectMatchesOracle(gpa, 3, rgb_only.items, rgb_pixels);
    }
}

test "qoi index starts as transparent black, as the spec says" {
    // rgba: an index op into an untouched slot gives (0, 0, 0, 0)
    var px4: [4]u8 = undefined;
    try decodeOps(4, &.{0x00}, &px4);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &px4);

    // rgb: that pixel's alpha 0 carries into the hash of the next one, so
    // (10, 20, 30) lands in slot 20 (not 9) and index op 20 finds it
    const body = [_]u8{ 0x00, 0xFE, 10, 20, 30, 0x14 };
    var px3: [9]u8 = undefined;
    try decodeOps(3, &body, &px3);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 10, 20, 30, 10, 20, 30 }, &px3);
    try expectMatchesOracle(std.testing.allocator, 3, &body, 3);
}

test "qoi encoder output decodes with spec index semantics" {
    // a small palette makes index ops common; opaque and transparent black are
    // the colours a wrongly initialised index confuses
    const gpa = std.testing.allocator;
    const scalar = @import("scalar.zig");
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    const palette = [_]RGBA{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .{ .r = 200, .g = 10, .b = 10 },       .{ .r = 10, .g = 200, .b = 10, .a = 128 },
        .{ .r = 1, .g = 2, .b = 3 },
    };
    for (0..50) |_| {
        const n = random.intRangeAtMost(usize, 1, 300);
        const rgba = try gpa.alloc(RGBA, n);
        defer gpa.free(rgba);
        const rgb = try gpa.alloc(RGB, n);
        defer gpa.free(rgb);
        for (rgba, rgb) |*a, *b| {
            a.* = palette[random.uintLessThan(usize, palette.len)];
            b.* = .{ .r = a.r, .g = a.g, .b = a.b };
        }

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try encodeRgb(&aw.writer, rgb);
        const got3 = try gpa.alloc(RGB, n);
        defer gpa.free(got3);
        try scalar.decodeRgb(aw.written(), got3);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(rgb), std.mem.sliceAsBytes(got3));

        aw.clearRetainingCapacity();
        try encodeRgba(&aw.writer, rgba);
        const got4 = try gpa.alloc(RGBA, n);
        defer gpa.free(got4);
        try scalar.decodeRgba(aw.written(), got4);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(rgba), std.mem.sliceAsBytes(got4));
    }
}
