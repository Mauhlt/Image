//! TGA (Targa) 2.0: true-color 15/16/24/32-bit, grayscale 8/16-bit (gray+alpha),
//! color-mapped with 8/16-bit indices into 15/16/24/32-bit entries; raw or RLE, any origin.
//! Encode: RLE, top-left origin; g -> gray, ga -> gray+alpha, rgb -> 24-bit, rgba -> 32-bit.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const Header = @import("header.zig");

const Alpha = enum { none, straight, premultiplied };

/// What the alpha field of a 16/32-bit color holds. The descriptor's alpha-bit count
/// decides, except where the TGA 2.0 extension area says more: types 1/2 declare
/// the field garbage (Truevision's own utc32.tga has 8 alpha bits, all 0, tagged 2),
/// 3/4 declare real alpha. Type 0 ("no alpha") is also what a zero-filled extension
/// area reads as, so it is not trusted over a descriptor that counts alpha bits.
fn alphaMode(hdr: *const Header, data: []const u8) Alpha {
    switch (hdr.colorDepth()) {
        16, 32 => {},
        else => return .none, // 15/24-bit color and 8-bit gray have no alpha field
    }
    const from_descriptor: Alpha = if (hdr.alphaBits() > 0) .straight else .none;
    return switch (Header.attributeType(data) orelse return from_descriptor) {
        .undefined_ignore, .undefined_retain => .none,
        .alpha => .straight,
        .premultiplied => .premultiplied,
        else => from_descriptor,
    };
}

/// Output layout: TGA stores BGR(A) so those are returned without a swizzle.
fn outTag(hdr: *const Header, alpha: Alpha) PixelTag {
    const has_alpha = alpha != .none;
    return switch (hdr.image_type.base()) {
        .grayscale => if (has_alpha) .ga else .g,
        else => if (has_alpha) .bgra else .bgr,
    };
}

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data);
    const tag = outTag(&hdr, alphaMode(&hdr, data));
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

/// Expands one stored color to B, G, R, A (gray, alpha for grayscale);
/// the output tag decides how many of the 4 bytes are kept.
fn expand(depth: u8, gray: bool, src: []const u8) [4]u8 {
    return switch (depth) {
        8 => .{ src[0], 0, 0, 0 },
        15, 16 => if (gray) .{ src[0], src[1], 0, 0 } else {
            // A1R5G5B5, little endian; bit 15 is only kept when alphaMode says so
            const v = std.mem.readInt(u16, src[0..2], .little);
            return .{
                expand5(@truncate(v)),
                expand5(@truncate(v >> 5)),
                expand5(@truncate(v >> 10)),
                if (v & 0x8000 != 0) 255 else 0,
            };
        },
        24 => .{ src[0], src[1], src[2], 0 },
        32 => src[0..4].*,
        else => unreachable, // rejected by Header.decode
    };
}

/// Replicates the top bits into the low ones so 0 -> 0 and 31 -> 255 exactly.
fn expand5(v: u5) u8 {
    return (@as(u8, v) << 3) | (@as(u8, v) >> 2);
}

/// Reads stored pixels (colors, or indices into a pre-expanded palette) in file order.
const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    in_bpp: usize,
    depth: u8,
    gray: bool,
    palette: ?[]const [4]u8,
    first: usize, // index of palette[0] (the header's color map origin)

    fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.src.len) return Error.UnexpectedEndOfData;
        defer self.pos += 1;
        return self.src[self.pos];
    }

    fn pixel(self: *Reader) Error![4]u8 {
        if (self.src.len - self.pos < self.in_bpp) return Error.UnexpectedEndOfData;
        const bytes = self.src[self.pos..][0..self.in_bpp];
        self.pos += self.in_bpp;
        const palette = self.palette orelse return expand(self.depth, self.gray, bytes);
        const idx: usize = if (bytes.len == 2) std.mem.readInt(u16, bytes[0..2], .little) else bytes[0];
        const entry = std.math.sub(usize, idx, self.first) catch return Error.OutOfBounds;
        if (entry >= palette.len) return Error.OutOfBounds;
        return palette[entry];
    }
};

/// Places pixels given in file order: rows run bottom-up unless the descriptor
/// says top-down, columns left-to-right unless it says right-to-left.
const Cursor = struct {
    out: []u8,
    bpp: usize,
    width: usize,
    height: usize,
    top_down: bool,
    right_to_left: bool,
    fx: usize = 0,
    fy: usize = 0,

    fn put(self: *Cursor, px: [4]u8) void {
        const x = if (self.right_to_left) self.width - 1 - self.fx else self.fx;
        const y = if (self.top_down) self.fy else self.height - 1 - self.fy;
        @memcpy(self.out[(y * self.width + x) * self.bpp ..][0..self.bpp], px[0..self.bpp]);
        self.fx += 1;
        if (self.fx == self.width) {
            self.fx = 0;
            self.fy += 1;
        }
    }
};

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const hdr: Header = try .decode(data);
    const alpha = alphaMode(&hdr, data);
    if (outTag(&hdr, alpha) != inf.tag) return Error.InvalidHeader;
    const base = hdr.image_type.base();

    const palette: ?[][4]u8 = if (base == .color_mapped) blk: {
        const eb = Header.bytesFor(hdr.cmap_depth);
        const cmap = data[hdr.cmapOffset()..][0..hdr.cmapBytes()];
        const pal = try scratch.alloc([4]u8, hdr.cmap_len);
        for (pal, 0..) |*p, i| p.* = expand(hdr.cmap_depth, false, cmap[i * eb ..][0..eb]);
        break :blk pal;
    } else null;

    var reader: Reader = .{
        .src = data[hdr.pixelOffset()..],
        .in_bpp = Header.bytesFor(hdr.depth),
        .depth = hdr.depth,
        .gray = base == .grayscale,
        .palette = palette,
        .first = hdr.cmap_first,
    };
    var cursor: Cursor = .{
        .out = out,
        .bpp = inf.tag.bytesPerPixel(),
        .width = hdr.width,
        .height = hdr.height,
        .top_down = hdr.topDown(),
        .right_to_left = hdr.rightToLeft(),
    };

    // A raw image is one packet of literal pixels. RLE packets may cross scanlines
    // (allowed by TGA 2.0 and written by many encoders), so they are only bounded
    // by the image end.
    const total = @as(usize, hdr.width) * hdr.height;
    var n: usize = 0;
    while (n < total) {
        var count = total - n;
        var is_run = false;
        if (hdr.image_type.isRle()) {
            const packet = try reader.byte();
            count = @as(usize, packet & 0x7F) + 1;
            is_run = packet & 0x80 != 0;
            if (count > total - n) return Error.InvalidRLEData;
        }
        if (is_run) {
            const px = try reader.pixel();
            for (0..count) |_| cursor.put(px);
        } else {
            for (0..count) |_| cursor.put(try reader.pixel());
        }
        n += count;
    }
    if (alpha == .premultiplied) unpremultiply(out, cursor.bpp);
}

/// Library pixels carry straight alpha, so TGA 2.0 premultiplied colors are divided back out.
fn unpremultiply(out: []u8, bpp: usize) void {
    var i: usize = 0;
    while (i < out.len) : (i += bpp) {
        const px = out[i..][0..bpp];
        const a: u32 = px[bpp - 1];
        for (px[0 .. bpp - 1]) |*c| {
            c.* = if (a == 0) 0 else @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
        }
    }
}

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    if (img.width > 0xFFFF or img.height > 0xFFFF) return Error.InvalidDimensions;
    const tag: PixelTag = switch (img.pixels) {
        .g => .g,
        .ga => .ga,
        .rgb, .bgr, .ycbcr => .bgr,
        .rgba, .bgra, .ycbcra => .bgra,
    };
    const converted = if (std.meta.activeTag(img.pixels) == tag) null else try img.pixels.convertV(tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const bytes = (converted orelse img.pixels).asBytes();
    const bpp: usize = tag.bytesPerPixel();

    const hdr: Header = .{
        .image_type = if (tag == .g or tag == .ga) .rle_grayscale else .rle_true_color,
        .width = @intCast(img.width),
        .height = @intCast(img.height),
        .depth = @intCast(bpp * 8),
        .descriptor = 0x20 | @as(u8, if (tag == .bgra or tag == .ga) 8 else 0),
    };
    try hdr.encode(w);

    // RLE per row (packets never cross rows, for compatibility)
    const width: usize = img.width;
    for (0..img.height) |y| {
        const row = bytes[y * width * bpp ..][0 .. width * bpp];
        var x: usize = 0;
        while (x < width) {
            const px = row[x * bpp ..][0..bpp];
            // run of identical pixels?
            var run: usize = 1;
            while (x + run < width and run < 128 and
                std.mem.eql(u8, px, row[(x + run) * bpp ..][0..bpp])) run += 1;
            if (run > 1) {
                try w.writeByte(@intCast(0x80 | (run - 1)));
                try w.writeAll(px);
                x += run;
                continue;
            }
            // raw packet until the next repeat
            var raw: usize = 1;
            while (x + raw < width and raw < 128) : (raw += 1) {
                const a = row[(x + raw) * bpp ..][0..bpp];
                if (x + raw + 1 < width and std.mem.eql(u8, a, row[(x + raw + 1) * bpp ..][0..bpp])) break;
            }
            try w.writeByte(@intCast(raw - 1));
            try w.writeAll(row[x * bpp ..][0 .. raw * bpp]);
            x += raw;
        }
    }
    // TGA 2.0 footer (no extension / developer areas)
    try w.writeAll(&@as([8]u8, @splat(0)));
    try w.writeAll("TRUEVISION-XFILE.\x00");
}

// ───────────────────────────── Tests ─────────────────────────────
// Files are assembled byte by byte from the spec, decoded, and compared with the
// pixels they were built from.

const testing = std.testing;

/// A test file: header fields plus already-encoded color map and pixel data.
const TestFile = struct {
    image_type: Header.ImageType,
    width: u16 = ref_w,
    height: u16 = ref_h,
    depth: u8,
    descriptor: u8 = 0,
    id: []const u8 = "",
    cmap_first: u16 = 0,
    cmap_depth: u8 = 0,
    cmap: []const u8 = "", // stored entries; a non-empty map sets color_map_type = 1
    pixels: []const u8,
    attribute: ?Header.AttributeType = null, // adds a TGA 2.0 extension area

    fn build(f: TestFile, gpa: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var hdr: [Header.SIZE]u8 = @splat(0);
        hdr[0] = @intCast(f.id.len);
        hdr[1] = @intFromBool(f.cmap.len > 0);
        hdr[2] = @backingInt(f.image_type);
        const cmap_len: u16 = if (f.cmap.len > 0) @intCast(f.cmap.len / Header.bytesFor(f.cmap_depth)) else 0;
        std.mem.writeInt(u16, hdr[3..5], f.cmap_first, .little);
        std.mem.writeInt(u16, hdr[5..7], cmap_len, .little);
        hdr[7] = f.cmap_depth;
        std.mem.writeInt(u16, hdr[12..14], f.width, .little);
        std.mem.writeInt(u16, hdr[14..16], f.height, .little);
        hdr[16] = f.depth;
        hdr[17] = f.descriptor;
        try list.appendSlice(gpa, &hdr);
        try list.appendSlice(gpa, f.id);
        try list.appendSlice(gpa, f.cmap);
        try list.appendSlice(gpa, f.pixels);
        var ext_offset: u32 = 0;
        if (f.attribute) |attr| {
            ext_offset = @intCast(list.items.len);
            var ext: [495]u8 = @splat(0);
            std.mem.writeInt(u16, ext[0..2], ext.len, .little);
            ext[494] = @backingInt(attr);
            try list.appendSlice(gpa, &ext);
        }
        var footer: [26]u8 = undefined;
        std.mem.writeInt(u32, footer[0..4], ext_offset, .little);
        std.mem.writeInt(u32, footer[4..8], 0, .little);
        footer[8..].* = "TRUEVISION-XFILE.\x00".*;
        try list.appendSlice(gpa, &footer);
        return list.toOwnedSlice(gpa);
    }
};

fn decodeTest(gpa: std.mem.Allocator, f: TestFile) !Image {
    const bytes = try f.build(gpa);
    defer gpa.free(bytes);
    return Image.decode(.tga, gpa, bytes);
}

fn expectPixels(img: *const Image, tag: PixelTag, expected: []const u8) !void {
    try testing.expectEqual(tag, std.meta.activeTag(img.pixels));
    try testing.expectEqualSlices(u8, expected, img.pixels.asBytes());
}

/// 4x3 reference image (top-left first) as BGRA. Channels are 5-bit values scaled to 8 bits
/// (spelled out rather than computed with expand5) and alphas are 0 or 255, so every depth
/// stores it losslessly.
/// Repeats (some crossing rows) give RLE something to compress.
const ref_w = 4;
const ref_h = 3;
const ref = blk: {
    const palette = [_][4]u8{
        .{ 0xFF, 0x00, 0x00, 255 }, // 5-bit 31, 0, 0
        .{ 0x00, 0xFF, 0x00, 255 },
        .{ 0x00, 0x00, 0xFF, 0 },
        .{ 0x84, 0x42, 0x08, 255 }, // 5-bit 16, 8, 1
        .{ 0x18, 0xEF, 0x8C, 0 }, // 5-bit 3, 29, 17
    };
    const order = [ref_w * ref_h]u8{ 0, 1, 1, 1, 1, 2, 3, 3, 3, 4, 4, 0 };
    var px: [ref_w * ref_h][4]u8 = undefined;
    for (&px, order) |*p, i| p.* = palette[i];
    break :blk .{ .palette = palette, .order = order, .px = px };
};

/// The reference image's pixels in `tag` layout (gray uses the blue byte).
fn refPixels(tag: PixelTag) [ref_w * ref_h * 4]u8 {
    var buf: [ref_w * ref_h * 4]u8 = undefined;
    var i: usize = 0;
    for (ref.px) |p| {
        const kept: []const u8 = switch (tag) {
            .g => &.{p[0]},
            .ga => &.{ p[0], p[3] },
            .bgr => p[0..3],
            else => &p,
        };
        @memcpy(buf[i..][0..kept.len], kept);
        i += kept.len;
    }
    return buf;
}

/// Stores one BGRA color at `depth`. 15-bit colors set bit 15 anyway: it must be ignored.
fn store(depth: u8, gray: bool, p: [4]u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    switch (depth) {
        8 => try out.append(gpa, p[0]),
        15, 16 => if (gray) try out.appendSlice(gpa, &.{ p[0], p[3] }) else {
            const v: u16 = @as(u16, p[0] >> 3) | @as(u16, p[1] >> 3) << 5 | @as(u16, p[2] >> 3) << 10 |
                @as(u16, if (depth == 15 or p[3] != 0) 0x8000 else 0);
            try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
        },
        24 => try out.appendSlice(gpa, p[0..3]),
        32 => try out.appendSlice(gpa, &p),
        else => unreachable,
    }
}

/// Simple RLE packer that ignores scanlines, so runs cross row boundaries.
fn rle(gpa: std.mem.Allocator, raw: []const u8, bpp: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const n = raw.len / bpp;
    const at = struct {
        fn f(r: []const u8, b: usize, i: usize) []const u8 {
            return r[i * b ..][0..b];
        }
    }.f;
    var i: usize = 0;
    while (i < n) {
        var run: usize = 1;
        while (i + run < n and run < 128 and std.mem.eql(u8, at(raw, bpp, i), at(raw, bpp, i + run))) run += 1;
        if (run > 1) {
            try out.append(gpa, @intCast(0x80 | (run - 1)));
            try out.appendSlice(gpa, at(raw, bpp, i));
        } else {
            while (i + run < n and run < 128 and
                (i + run + 1 >= n or !std.mem.eql(u8, at(raw, bpp, i + run), at(raw, bpp, i + run + 1)))) run += 1;
            try out.append(gpa, @intCast(run - 1));
            try out.appendSlice(gpa, raw[i * bpp ..][0 .. run * bpp]);
        }
        i += run;
    }
    return out.toOwnedSlice(gpa);
}

const Variant = struct {
    base: Header.ImageType,
    depth: u8, // pixel depth; index size for color-mapped
    cmap_depth: u8 = 0,
    alpha_bits: u8 = 0,
    tag: PixelTag,
};

const variants = [_]Variant{
    .{ .base = .true_color, .depth = 15, .tag = .bgr },
    .{ .base = .true_color, .depth = 16, .alpha_bits = 1, .tag = .bgra },
    .{ .base = .true_color, .depth = 16, .tag = .bgr }, // alpha bit present but not counted
    .{ .base = .true_color, .depth = 24, .tag = .bgr },
    .{ .base = .true_color, .depth = 32, .alpha_bits = 8, .tag = .bgra },
    .{ .base = .true_color, .depth = 32, .tag = .bgr },
    .{ .base = .grayscale, .depth = 8, .tag = .g },
    .{ .base = .grayscale, .depth = 16, .alpha_bits = 8, .tag = .ga },
    .{ .base = .color_mapped, .depth = 8, .cmap_depth = 15, .tag = .bgr },
    .{ .base = .color_mapped, .depth = 8, .cmap_depth = 16, .alpha_bits = 1, .tag = .bgra },
    .{ .base = .color_mapped, .depth = 8, .cmap_depth = 24, .tag = .bgr },
    .{ .base = .color_mapped, .depth = 8, .cmap_depth = 32, .alpha_bits = 8, .tag = .bgra },
    .{ .base = .color_mapped, .depth = 16, .cmap_depth = 24, .tag = .bgr },
    .{ .base = .color_mapped, .depth = 16, .cmap_depth = 32, .alpha_bits = 8, .tag = .bgra },
};

/// Builds the reference image as `v`, raw or RLE, with the given origin bits (0x00-0x30).
fn buildVariant(gpa: std.mem.Allocator, v: Variant, compressed: bool, origin: u8) !Image {
    const mapped = v.base == .color_mapped;
    // 8-bit indices start at origin 5; 16-bit ones use a 300-entry map whose used
    // entries sit past 255, so indices need both bytes.
    const first: u16 = if (v.depth == 16) 2 else 5;
    const pad: usize = if (v.depth == 16) 290 else 0;

    var cmap: std.ArrayList(u8) = .empty;
    defer cmap.deinit(gpa);
    if (mapped) {
        for (0..pad) |_| try store(v.cmap_depth, false, .{ 9, 9, 9, 9 }, &cmap, gpa);
        for (ref.palette) |p| try store(v.cmap_depth, false, p, &cmap, gpa);
        for (0..5) |_| try store(v.cmap_depth, false, .{ 7, 7, 7, 7 }, &cmap, gpa);
    }

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..ref_h) |fy| for (0..ref_w) |fx| {
        const x = if (origin & 0x10 != 0) ref_w - 1 - fx else fx;
        const y = if (origin & 0x20 != 0) fy else ref_h - 1 - fy;
        const i = y * ref_w + x;
        if (mapped) {
            const idx: u16 = @intCast(first + pad + ref.order[i]);
            if (v.depth == 8) try raw.append(gpa, @intCast(idx)) else try raw.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, idx)));
        } else try store(v.depth, v.base == .grayscale, ref.px[i], &raw, gpa);
    };

    const pixels = if (compressed) try rle(gpa, raw.items, Header.bytesFor(v.depth)) else try raw.toOwnedSlice(gpa);
    defer gpa.free(pixels);
    return decodeTest(gpa, .{
        .image_type = if (compressed) @fromBackingInt(@intCast(@backingInt(v.base) + 8)) else v.base,
        .depth = v.depth,
        .descriptor = origin | v.alpha_bits,
        .cmap_first = if (mapped) first else 0,
        .cmap_depth = v.cmap_depth,
        .cmap = cmap.items,
        .pixels = pixels,
    });
}

test "tga every depth, palette entry size, raw/RLE and origin" {
    const gpa = testing.allocator;
    for (variants) |v| for ([_]bool{ false, true }) |compressed| for ([_]u8{ 0x00, 0x10, 0x20, 0x30 }) |origin| {
        const img = try buildVariant(gpa, v, compressed, origin);
        defer img.deinit(gpa);
        const expected = refPixels(v.tag);
        expectPixels(&img, v.tag, expected[0 .. ref_w * ref_h * v.tag.bytesPerPixel()]) catch |err| {
            std.debug.print("variant {any} rle={} origin=0x{x}\n", .{ v, compressed, origin });
            return err;
        };
    };
}

test "tga 5-bit channels scale to the full 8-bit range" {
    try testing.expectEqual(@as(u8, 255), expand5(31));
    try testing.expectEqual(@as(u8, 0), expand5(0));
    try testing.expectEqual(@as(u8, 0x84), expand5(16));
    const gpa = testing.allocator;
    // 0 RRRRR GGGGG BBBBB = 0 11111 10000 00001
    const img = try decodeTest(gpa, .{ .image_type = .true_color, .width = 1, .height = 1, .depth = 15, .pixels = &.{ 0x01, 0x7E } });
    defer img.deinit(gpa);
    try expectPixels(&img, .bgr, &.{ 0x08, 0x84, 0xFF });
}

test "tga skips the image ID and an unused color map" {
    const gpa = testing.allocator;
    const img = try decodeTest(gpa, .{
        .image_type = .true_color,
        .width = 2,
        .height = 1,
        .depth = 24,
        .id = "image id field",
        .cmap_depth = 15, // 2 bytes per entry although 15 is not a byte multiple
        .cmap = &.{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
        .pixels = &.{ 1, 2, 3, 4, 5, 6 },
    });
    defer img.deinit(gpa);
    try expectPixels(&img, .bgr, &.{ 1, 2, 3, 4, 5, 6 });
}

test "tga RLE packet crossing a scanline" {
    const gpa = testing.allocator;
    // 3x2 bottom-left: raw A B, run of 3 C (end of row 0 + start of row 1), raw D
    const img = try decodeTest(gpa, .{
        .image_type = .rle_grayscale,
        .width = 3,
        .height = 2,
        .depth = 8,
        .pixels = &.{ 0x01, 'A', 'B', 0x82, 'C', 0x00, 'D' },
    });
    defer img.deinit(gpa);
    try expectPixels(&img, .g, "CCDABC");
}

test "tga extension area attribute type" {
    const gpa = testing.allocator;
    const px32 = [_]u8{ 10, 20, 30, 0, 40, 50, 60, 128 };
    const Case = struct { attr: ?Header.AttributeType, bits: u8, depth: u8 = 32, pixels: []const u8 = &px32, tag: PixelTag, out: []const u8 };
    const cases = [_]Case{
        // no extension area: the descriptor decides
        .{ .attr = null, .bits = 8, .tag = .bgra, .out = &px32 },
        .{ .attr = null, .bits = 0, .tag = .bgr, .out = &.{ 10, 20, 30, 40, 50, 60 } },
        // 0 may just be a zero-filled area, so counted alpha bits win
        .{ .attr = .no_alpha, .bits = 8, .tag = .bgra, .out = &px32 },
        .{ .attr = .no_alpha, .bits = 0, .tag = .bgr, .out = &.{ 10, 20, 30, 40, 50, 60 } },
        // undefined alpha data, whatever the descriptor says
        .{ .attr = .undefined_ignore, .bits = 8, .tag = .bgr, .out = &.{ 10, 20, 30, 40, 50, 60 } },
        .{ .attr = .undefined_retain, .bits = 8, .tag = .bgr, .out = &.{ 10, 20, 30, 40, 50, 60 } },
        // useful alpha even if the descriptor forgot to count it, 16-bit too
        .{ .attr = .alpha, .bits = 0, .tag = .bgra, .out = &px32 },
        .{ .attr = .alpha, .bits = 0, .depth = 16, .pixels = &.{ 0x1F, 0x80, 0x00, 0x7C }, .tag = .bgra, .out = &.{ 255, 0, 0, 255, 0, 0, 255, 0 } },
        // premultiplied: colors are divided back by alpha (rounded), alpha 0 -> black
        .{ .attr = .premultiplied, .bits = 8, .tag = .bgra, .out = &.{ 0, 0, 0, 0, 80, 100, 120, 128 } },
        // reserved values fall back to the descriptor
        .{ .attr = @fromBackingInt(@intCast(200)), .bits = 8, .tag = .bgra, .out = &px32 },
    };
    for (cases) |c| {
        const img = try decodeTest(gpa, .{
            .image_type = .true_color,
            .width = 2,
            .height = 1,
            .depth = c.depth,
            .descriptor = 0x20 | c.bits,
            .pixels = c.pixels,
            .attribute = c.attr,
        });
        defer img.deinit(gpa);
        expectPixels(&img, c.tag, c.out) catch |err| {
            std.debug.print("attribute case {any}\n", .{c});
            return err;
        };
    }
}

test "tga rejects bad files" {
    const gpa = testing.allocator;
    const Case = struct { err: anyerror, f: TestFile };
    const cases = [_]Case{
        .{ .err = Error.UnsupportedDepth, .f = .{ .image_type = .true_color, .width = 1, .height = 1, .depth = 12, .pixels = &.{ 0, 0 } } },
        .{ .err = Error.UnsupportedDepth, .f = .{ .image_type = .grayscale, .width = 1, .height = 1, .depth = 24, .pixels = &.{ 0, 0, 0 } } },
        .{ .err = Error.UnsupportedDepth, .f = .{ .image_type = .color_mapped, .width = 1, .height = 1, .depth = 8, .cmap_depth = 8, .cmap = &.{0}, .pixels = &.{0} } },
        .{ .err = Error.UnsupportedDepth, .f = .{ .image_type = .color_mapped, .width = 1, .height = 1, .depth = 24, .cmap_depth = 24, .cmap = &.{ 0, 0, 0 }, .pixels = &.{ 0, 0, 0 } } },
        .{ .err = Error.InvalidHeader, .f = .{ .image_type = .color_mapped, .width = 1, .height = 1, .depth = 8, .pixels = &.{0} } },
        // index below the map's origin, and past its end
        .{ .err = Error.OutOfBounds, .f = .{ .image_type = .color_mapped, .width = 1, .height = 1, .depth = 8, .cmap_first = 4, .cmap_depth = 24, .cmap = &.{ 0, 0, 0 }, .pixels = &.{3} } },
        .{ .err = Error.OutOfBounds, .f = .{ .image_type = .color_mapped, .width = 1, .height = 1, .depth = 8, .cmap_first = 4, .cmap_depth = 24, .cmap = &.{ 0, 0, 0 }, .pixels = &.{5} } },
        // run of 3 in a 2-pixel image
        .{ .err = Error.InvalidRLEData, .f = .{ .image_type = .rle_grayscale, .width = 2, .height = 1, .depth = 8, .pixels = &.{ 0x82, 0 } } },
    };
    for (cases) |c| try testing.expectError(c.err, decodeTest(gpa, c.f));

    // truncated pixel data: cut the footer off a raw 2x2 24-bit file mid-pixel
    const bytes = try (TestFile{ .image_type = .true_color, .width = 2, .height = 2, .depth = 24, .pixels = &(@as([12]u8, @splat(1))) }).build(gpa);
    defer gpa.free(bytes);
    try testing.expectError(Error.UnexpectedEndOfData, Image.decode(.tga, gpa, bytes[0 .. Header.SIZE + 10]));
    try testing.expectError(Error.UnexpectedEndOfData, Image.decode(.tga, gpa, bytes[0 .. Header.SIZE - 1]));
}

// Real files: Truevision's TGA 2.0 sample images plus image-rs' 16-bit, color map
// origin and orientation cases, checked against image-rs' PNG decodes of them and
// against each other (see src/Data/Read/tga/README.md).
test "tga conformance files" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "src/Data/Read/tga/";

    const Case = struct { a: []const u8, b: []const u8, tag: PixelTag, max_diff: u8 = 0 };
    const cases = [_]Case{
        .{ .a = "cbw8.tga", .b = "cbw8.tga.png", .tag = .g },
        .{ .a = "ctc24.tga", .b = "ctc24.tga.png", .tag = .rgb },
        // the same picture as RLE 24-bit, RLE color-mapped and raw 16-bit
        .{ .a = "ccm8.tga", .b = "ctc24.tga", .tag = .rgb },
        .{ .a = "utc16.tga", .b = "ctc24.tga", .tag = .rgb },
        .{ .a = "cmap_offset.tga", .b = "cmap_offset.tga.png", .tag = .rgb },
        .{ .a = "bottom_left.tga", .b = "bottom_left.tga.png", .tag = .rgba },
        .{ .a = "bottom_right.tga", .b = "bottom_right.tga.png", .tag = .rgba },
        .{ .a = "top_left.tga", .b = "top_left.tga.png", .tag = .rgba },
        .{ .a = "top_right.tga", .b = "top_right.tga.png", .tag = .rgba },
        // image-rs scales 5-bit channels by rounding v * 255 / 31, which differs
        // from bit replication by at most 1
        .{ .a = "b5-noattrib.tga", .b = "b5-noattrib.tga.png", .tag = .rgb, .max_diff = 1 },
        // 16-bit: color-mapped, true color with an unused color map, alpha bit counted
        .{ .a = "b5-cmap.tga", .b = "b5-noattrib.tga", .tag = .rgb },
        .{ .a = "b5-unused-cmap.tga", .b = "b5-noattrib.tga", .tag = .rgb },
        .{ .a = "b5-attrib.tga", .b = "b5-noattrib.tga", .tag = .rgb },
    };
    inline for (cases) |c| {
        const a = try Image.read(.{ .io = io, .gpa = gpa, .filepath = dir ++ c.a });
        defer a.deinit(gpa);
        const b = try Image.read(.{ .io = io, .gpa = gpa, .filepath = dir ++ c.b });
        defer b.deinit(gpa);
        try testing.expectEqual(a.width, b.width);
        try testing.expectEqual(a.height, b.height);
        const pa = try a.pixels.convert(c.tag, gpa);
        defer pa.deinit(gpa);
        const pb = try b.pixels.convert(c.tag, gpa);
        defer pb.deinit(gpa);
        for (pa.asBytes(), pb.asBytes()) |x, y| if (@max(x, y) - @min(x, y) > c.max_diff) {
            std.debug.print("{s} vs {s}: {} vs {}\n", .{ c.a, c.b, x, y });
            return error.TestExpectedSimilar;
        };
    }

    // utc16 counts 1 alpha bit but its extension area says the alpha data is undefined
    // (every bit is 0), and b5-attrib really uses its alpha bit
    const utc16 = try Image.read(.{ .io = io, .gpa = gpa, .filepath = dir ++ "utc16.tga" });
    defer utc16.deinit(gpa);
    try testing.expectEqual(PixelTag.bgr, std.meta.activeTag(utc16.pixels));
    const b5 = try Image.read(.{ .io = io, .gpa = gpa, .filepath = dir ++ "b5-attrib.tga" });
    defer b5.deinit(gpa);
    var opaque_px: usize = 0;
    for (b5.pixels.bgra) |p| opaque_px += @intFromBool(p.a == 255);
    try testing.expect(opaque_px > 0 and opaque_px < b5.pixels.bgra.len);
}
