//! PNG structure check, and the IHDR rules Image's PNG codec decodes with
//! (Formats/png/header.zig uses `Header.parse` and these enums).
//!
//! Full check: signature; IHDR first, 13 bytes, CRC, legal field values and
//! (colour type, bit depth) pair, size limits applied right there; then
//! every chunk inside the file with a valid CRC and an alphabetic tag,
//! PLTE (required for palette images, forbidden for gray ones) before the
//! IDATs, IDATs consecutive, IEND present, unknown critical chunks
//! rejected. Bytes after IEND are ignored, as decoders do.
const std = @import("std");
const root = @import("root.zig");
const Crc32 = @import("crc.zig").Crc32;
const Error = root.Error;
const Limits = root.Limits;
const Info = root.Info;

pub const signature = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub fn sniff(data: []const u8) bool {
    return data.len >= 8 and std.mem.eql(u8, data[0..8], &signature);
}

/// Same names as Image's pixel tags.
pub const ColorType = enum(u8) {
    g = 0,
    rgb = 2,
    i = 3, // palette indices
    ga = 4,
    rgba = 6,

    pub fn channels(self: ColorType) u8 {
        return switch (self) {
            .g, .i => 1,
            .ga => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

/// Bits per sample.
pub const BitDepth = enum(u8) {
    bit1 = 1,
    bit2 = 2,
    bit4 = 4,
    bit8 = 8,
    bit16 = 16,
};

pub const InterlaceMethod = enum(u8) {
    none = 0,
    adam7 = 1,
};

/// The IHDR fields. Compression and filter method have a single legal
/// value (0) and are checked, not stored.
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: BitDepth,
    color_type: ColorType,
    interlace_method: InterlaceMethod,

    /// Parses and validates an IHDR body (13 bytes). Checks, in order: length,
    /// bit depth, colour type, compression, filter and interlace method,
    /// non-zero dimensions, the (colour type, bit depth) pair.
    pub fn parse(body: []const u8) Error!Header {
        if (body.len != 13) return error.InvalidHeader;
        const width = std.mem.readInt(u32, body[0..4], .big);
        const height = std.mem.readInt(u32, body[4..8], .big);
        const bit_depth = std.enums.fromInt(BitDepth, body[8]) orelse return error.InvalidBitDepth;
        const color_type = std.enums.fromInt(ColorType, body[9]) orelse return error.InvalidColorType;
        if (body[10] != 0) return error.InvalidCompression;
        if (body[11] != 0) return error.InvalidFilterMethod;
        const interlace_method = std.enums.fromInt(InterlaceMethod, body[12]) orelse return error.InvalidInterlaceMethod;
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const ok = switch (color_type) {
            .g => true,
            .i => @backingInt(bit_depth) <= 8,
            .rgb, .ga, .rgba => @backingInt(bit_depth) >= 8,
        };
        if (!ok) return error.InvalidBitDepth;
        return .{ .width = width, .height = height, .bit_depth = bit_depth, .color_type = color_type, .interlace_method = interlace_method };
    }

    pub fn encode(h: Header, buf: *[13]u8) void {
        std.mem.writeInt(u32, buf[0..4], h.width, .big);
        std.mem.writeInt(u32, buf[4..8], h.height, .big);
        buf[8..13].* = .{ @backingInt(h.bit_depth), @backingInt(h.color_type), 0, 0, @backingInt(h.interlace_method) };
    }

    /// Bits per pixel in the filtered stream.
    pub fn bitsPerPixel(h: Header) u32 {
        return @as(u32, h.color_type.channels()) * @backingInt(h.bit_depth);
    }

    pub fn interlaced(h: Header) bool {
        return h.interlace_method == .adam7;
    }

    /// Exact size of the inflated, filtered image data (all Adam7 passes
    /// for interlaced images): what a decoder must allocate for it.
    pub fn rawBytes(h: Header) u64 {
        const bpp: u64 = h.bitsPerPixel();
        if (!h.interlaced()) return @as(u64, h.height) * ((@as(u64, h.width) * bpp + 7) / 8 + 1);
        const passes = [7][4]u8{
            .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 },
            .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
        };
        var total: u64 = 0;
        for (passes) |p| {
            const pw: u64 = if (h.width > p[0]) (h.width - p[0] + p[2] - 1) / p[2] else 0;
            const ph: u64 = if (h.height > p[1]) (h.height - p[1] + p[3] - 1) / p[3] else 0;
            if (pw == 0) continue;
            total += ph * ((pw * bpp + 7) / 8 + 1);
        }
        return total;
    }

    /// Upper bound of bytes per pixel Image decodes this to (a tRNS chunk
    /// can add alpha; 16-bit gray stays 16-bit).
    pub fn decodedBytesPerPixel(h: Header) u64 {
        return switch (h.color_type) {
            .g, .ga => 2,
            .rgb, .rgba, .i => 4,
        };
    }
};

/// One chunk: its tag and body (CRC already checked by `Chunks`).
pub const Chunk = struct {
    tag: [4]u8,
    data: []const u8,
    /// Offset of the chunk's length field in the file.
    offset: usize,

    pub fn is(c: Chunk, tag: *const [4]u8) bool {
        return std.mem.eql(u8, &c.tag, tag);
    }

    /// Uppercase first letter: the chunk is critical.
    pub fn critical(c: Chunk) bool {
        return c.tag[0] & 0x20 == 0;
    }
};

/// Walks the chunks after the signature, checking each one's bounds, tag
/// and CRC, and the chunk count against `max_chunks`.
pub const Chunks = struct {
    data: []const u8,
    pos: usize = signature.len,
    count: u32 = 0,
    max_chunks: u32 = std.math.maxInt(u32),

    /// The next chunk, or null when fewer than 12 bytes are left.
    pub fn next(it: *Chunks) Error!?Chunk {
        const data = it.data;
        if (it.pos > data.len or data.len - it.pos < 12) return null;
        it.count += 1;
        if (it.count > it.max_chunks) return error.TooManyChunks;
        const at = it.pos;
        const len = std.mem.readInt(u32, data[at..][0..4], .big);
        if (len > data.len - at - 12) return error.Truncated;
        const tag = data[at + 4 ..][0..4].*;
        var h: Crc32 = .{};
        h.update(data[at + 4 ..][0 .. 4 + len]);
        if (h.final() != std.mem.readInt(u32, data[at + 8 + len ..][0..4], .big)) return error.InvalidCrc;
        for (tag) |c| if (!std.ascii.isAlphabetic(c)) return error.InvalidChunk;
        it.pos = at + 12 + len;
        return .{ .tag = tag, .data = data[at + 8 ..][0..len], .offset = at };
    }
};

/// Signature + IHDR, limits applied.
pub fn header(data: []const u8, limits: Limits) Error!Header {
    if (!sniff(data)) return error.UnknownFormat;
    if (data.len < 8 + 12 + 13) return error.Truncated;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return error.InvalidChunkOrder;
    if (std.mem.readInt(u32, data[8..12], .big) != 13) return error.InvalidHeader;
    var c: Crc32 = .{};
    c.update(data[12..29]);
    if (c.final() != std.mem.readInt(u32, data[29..33], .big)) return error.InvalidCrc;
    const h = try Header.parse(data[16..29]);
    try limits.admit(h.width, h.height);
    return h;
}

pub fn check(data: []const u8, limits: Limits, depth: root.Depth) Error!Info {
    const h = try header(data, limits);
    var info: Info = .{
        .format = .png,
        .width = h.width,
        .height = h.height,
        .channels = switch (h.color_type) {
            .i => 3,
            else => h.color_type.channels(),
        },
        .bits = @backingInt(h.bit_depth),
        .decode_bytes = 0,
        .png = h,
    };
    // Image's decoder: the inflated rows, the IDATs concatenated (when
    // there are several; bounded by the file), a zero row, the output.
    const fixed = h.rawBytes() + (@as(u64, h.width) * 8 + 8) + root.mul(info.pixels(), h.decodedBytesPerPixel());
    info.decode_bytes = fixed + data.len;
    if (depth == .header) return info;

    var it: Chunks = .{ .data = data, .max_chunks = limits.max_chunks };
    _ = try it.next(); // IHDR, checked above
    var plte = false;
    var trns = false;
    const Idat = enum { before, inside, after };
    var idat: Idat = .before;
    var idat_bytes: u64 = 0;
    var idat_chunks: u32 = 0;
    while (try it.next()) |c| {
        if (idat == .inside and !c.is("IDAT")) idat = .after;
        if (c.is("IDAT")) {
            if (idat == .after) return error.InvalidChunkOrder;
            if (h.color_type == .i and !plte) return error.InvalidChunkOrder;
            idat = .inside;
            idat_bytes += c.data.len;
            idat_chunks += 1;
        } else if (c.is("IEND")) {
            if (idat == .before) return error.MissingImageData;
            info.decode_bytes = fixed + if (idat_chunks > 1) idat_bytes else 0;
            if (trns and h.color_type == .i) info.channels = 4;
            if (trns and (h.color_type == .g or h.color_type == .rgb)) info.channels += 1;
            return info;
        } else if (c.is("PLTE")) {
            if (plte or idat != .before) return error.InvalidChunkOrder;
            if (c.data.len == 0 or c.data.len % 3 != 0 or c.data.len > 768) return error.InvalidChunk;
            if (h.color_type == .g or h.color_type == .ga) return error.InvalidChunk;
            plte = true;
        } else if (c.is("IHDR")) {
            return error.InvalidChunkOrder;
        } else if (c.is("tRNS")) {
            // Ancillary: decoders ignore a misplaced or malformed one.
            if (idat == .before) trns = switch (h.color_type) {
                .g => c.data.len == 2,
                .rgb => c.data.len == 6,
                .i => c.data.len > 0,
                .ga, .rgba => false,
            };
        } else if (c.critical()) {
            return error.UnsupportedFeature;
        }
    }
    return error.MissingEnd;
}

/// Writers for tests and fixtures (here, in Image's PNG tests and in
/// programs testing their own checks): no compressor needed.
pub const fixtures = struct {
    fn putChunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, tag: *const [4]u8, body: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(body.len), .big);
        try out.appendSlice(gpa, &len);
        const start = out.items.len;
        try out.appendSlice(gpa, tag);
        try out.appendSlice(gpa, body);
        var c: Crc32 = .{};
        c.update(out.items[start..]);
        var crc: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc, c.final(), .big);
        try out.appendSlice(gpa, &crc);
    }

    /// An 8-bit RGBA (colour type 6) PNG with filter-0 rows and stored
    /// (uncompressed) deflate blocks. `rgba.len` must be w * h * 4. Caller frees.
    pub fn encodeStored(gpa: std.mem.Allocator, w: u32, h: u32, rgba: []const u8) ![]u8 {
        if (rgba.len != @as(usize, w) * h * 4) return error.BadLength;
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(gpa);
        const stride = @as(usize, w) * 4;
        for (0..h) |y| {
            try raw.append(gpa, 0);
            try raw.appendSlice(gpa, rgba[y * stride ..][0..stride]);
        }
        var z: std.ArrayList(u8) = .empty;
        defer z.deinit(gpa);
        try z.appendSlice(gpa, &.{ 0x78, 0x01 });
        var rest: []const u8 = raw.items;
        while (true) {
            const n = @min(rest.len, 65535);
            const last = n == rest.len;
            try z.append(gpa, @intFromBool(last));
            var hdr: [4]u8 = undefined;
            std.mem.writeInt(u16, hdr[0..2], @intCast(n), .little);
            std.mem.writeInt(u16, hdr[2..4], ~@as(u16, @intCast(n)), .little);
            try z.appendSlice(gpa, &hdr);
            try z.appendSlice(gpa, rest[0..n]);
            rest = rest[n..];
            if (last) break;
        }
        var adler: [4]u8 = undefined;
        std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw.items), .big);
        try z.appendSlice(gpa, &adler);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, &signature);
        var ihdr: [13]u8 = undefined;
        (Header{ .width = w, .height = h, .bit_depth = .bit8, .color_type = .rgba, .interlace_method = .none }).encode(&ihdr);
        try putChunk(&out, gpa, "IHDR", &ihdr);
        try putChunk(&out, gpa, "IDAT", z.items);
        try putChunk(&out, gpa, "IEND", "");
        return out.toOwnedSlice(gpa);
    }

    /// A w x h gradient PNG (red across, green down, blue 0x80). Caller frees.
    pub fn testImage(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        defer gpa.free(px);
        for (0..h) |y| for (0..w) |x| {
            const p = px[(y * w + x) * 4 ..][0..4];
            p.* = .{ @truncate(x * 255 / @max(w - 1, 1)), @truncate(y * 255 / @max(h - 1, 1)), 0x80, 0xFF };
        };
        return encodeStored(gpa, w, h, px);
    }

    /// Recomputes every chunk's CRC in place (mutate a file, then make the
    /// CRCs right so the mutation reaches the next layer).
    pub fn fixCrcs(data: []u8) void {
        if (data.len < 8) return;
        var i: usize = 8;
        while (data.len - i >= 12) {
            const len = std.mem.readInt(u32, data[i..][0..4], .big);
            if (len > data.len - i - 12) return;
            var c: Crc32 = .{};
            c.update(data[i + 4 ..][0 .. 4 + len]);
            std.mem.writeInt(u32, data[i + 8 + len ..][0..4], c.final(), .big);
            i += 12 + len;
        }
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn validate(data: []const u8) Error!Info {
    return root.checkAs(.png, data, .{ .max_width = 8192, .max_height = 8192, .max_pixels = 32 << 20, .max_chunks = 4096 });
}

test "stored PNG validates" {
    const p = try fixtures.testImage(testing.allocator, 13, 7);
    defer testing.allocator.free(p);
    const info = try validate(p);
    try testing.expectEqual(@as(u32, 13), info.width);
    try testing.expectEqual(@as(u32, 7), info.height);
    try testing.expectEqual(@as(u64, 7 * (13 * 4 + 1)), info.png.?.rawBytes());
    try testing.expectEqual(ColorType.rgba, info.png.?.color_type);
}

test "header and structure rejections" {
    const gpa = testing.allocator;
    const p = try fixtures.testImage(gpa, 4, 4);
    defer gpa.free(p);
    try testing.expectError(error.UnknownFormat, validate("GIF89a"));
    try testing.expectError(error.UnknownFormat, validate(""));
    try testing.expectError(error.Truncated, validate(p[0..20]));
    // Every truncation fails cleanly.
    for (0..p.len) |n| try testing.expect(std.meta.isError(validate(p[0..n])));
    // ... and a header peek works as soon as the IHDR is complete.
    try testing.expectError(error.Truncated, root.checkHeaderAs(.png, p[0..32], .{}));
    _ = try root.checkHeaderAs(.png, p[0..33], .{});

    const m = try gpa.dupe(u8, p);
    defer gpa.free(m);
    m[20] ^= 1;
    try testing.expectError(error.InvalidCrc, validate(m));
    // Huge IHDR, CRC fixed: refused by the limits before anything else.
    @memcpy(m, p);
    std.mem.writeInt(u32, m[16..20], 100000, .big);
    fixtures.fixCrcs(m);
    try testing.expectError(error.ImageTooLarge, validate(m));
    std.mem.writeInt(u32, m[16..20], 8192, .big);
    std.mem.writeInt(u32, m[20..24], 8192, .big); // 64 Mpx > 32 Mpx
    fixtures.fixCrcs(m);
    try testing.expectError(error.ImageTooLarge, validate(m));
    std.mem.writeInt(u32, m[16..20], 0, .big);
    fixtures.fixCrcs(m);
    try testing.expectError(error.InvalidDimensions, validate(m));
    // Bad depth for the colour type.
    @memcpy(m, p);
    m[24] = 4; // RGBA at 4 bits
    fixtures.fixCrcs(m);
    try testing.expectError(error.InvalidBitDepth, validate(m));
    @memcpy(m, p);
    m[25] = 5;
    fixtures.fixCrcs(m);
    try testing.expectError(error.InvalidColorType, validate(m));
    @memcpy(m, p);
    m[27] = 1;
    fixtures.fixCrcs(m);
    try testing.expectError(error.InvalidFilterMethod, validate(m));
    @memcpy(m, p);
    m[28] = 2;
    fixtures.fixCrcs(m);
    try testing.expectError(error.InvalidInterlaceMethod, validate(m));
    // Chunk length pointing past the end.
    @memcpy(m, p);
    std.mem.writeInt(u32, m[33..37], 0x7FFFFFFF, .big);
    try testing.expectError(error.Truncated, validate(m));
    // Non-alphabetic tag.
    @memcpy(m, p);
    m[37] = '1';
    fixtures.fixCrcs(m);
    try testing.expectError(error.InvalidChunk, validate(m));
    // Unknown critical chunk (IDAT renamed "IDAX" keeps it critical).
    @memcpy(m, p);
    m[40] = 'X';
    fixtures.fixCrcs(m);
    try testing.expectError(error.UnsupportedFeature, validate(m));
    // ... but an unknown ancillary one is skipped: then no IDAT is left.
    m[37] = 'i';
    fixtures.fixCrcs(m);
    try testing.expectError(error.MissingImageData, validate(m));
    // No IEND.
    try testing.expectError(error.MissingEnd, validate(p[0 .. p.len - 12]));
}

test "chunk order" {
    const gpa = testing.allocator;
    const p = try fixtures.testImage(gpa, 3, 3);
    defer gpa.free(p);
    // Rebuild with extra chunks around the IDAT.
    const idat_at = 33;
    const idat_len = std.mem.readInt(u32, p[idat_at..][0..4], .big);
    const idat = p[idat_at..][0 .. 12 + idat_len];
    const Case = struct { before: []const u8, after: []const u8, err: ?Error };
    const plte = "\x00\x00\x00\x03PLTE\x00\x00\x00\x00\x00\x00\x00";
    const ihdr = p[8..33];
    const cases = [_]Case{
        .{ .before = plte, .after = "", .err = null }, // PLTE allowed for RGBA
        .{ .before = "", .after = plte, .err = error.InvalidChunkOrder },
        .{ .before = plte ++ plte, .after = "", .err = error.InvalidChunkOrder },
        .{ .before = "", .after = ihdr, .err = error.InvalidChunkOrder },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, p[0..idat_at]);
        try out.appendSlice(gpa, c.before);
        try out.appendSlice(gpa, idat);
        try out.appendSlice(gpa, c.after);
        try out.appendSlice(gpa, p[idat_at + idat.len ..]);
        fixtures.fixCrcs(out.items);
        if (c.err) |e| try testing.expectError(e, validate(out.items)) else _ = try validate(out.items);
    }
    // Split IDATs are fine; an IDAT after a different chunk is not.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, p[0..idat_at]);
    try out.appendSlice(gpa, idat);
    try out.appendSlice(gpa, "\x00\x00\x00\x00IDAT\x00\x00\x00\x00");
    try out.appendSlice(gpa, p[idat_at + idat.len ..]);
    fixtures.fixCrcs(out.items);
    const info = try validate(out.items);
    try testing.expect(info.decode_bytes >= info.png.?.rawBytes() + idat_len);
    try out.insertSlice(gpa, idat_at + idat.len, "\x00\x00\x00\x00teXt\x00\x00\x00\x00");
    fixtures.fixCrcs(out.items);
    try testing.expectError(error.InvalidChunkOrder, validate(out.items));
}

test "interlaced raw size" {
    const h: Header = .{ .width = 9, .height = 9, .bit_depth = .bit8, .color_type = .rgb, .interlace_method = .adam7 };
    // Pass sizes for 9x9: 2x2, 1x2, 2x1, 2x3, 3x2, 4x4(rows 4) ... computed by hand:
    // (w,h) = (2,2) (1,2) (3,1) (2,3) (5,2) (4,5) (9,4)
    const want: u64 = 2 * (2 * 3 + 1) + 2 * (1 * 3 + 1) + 1 * (3 * 3 + 1) + 3 * (2 * 3 + 1) + 2 * (5 * 3 + 1) + 5 * (4 * 3 + 1) + 4 * (9 * 3 + 1);
    try testing.expectEqual(want, h.rawBytes());
}
