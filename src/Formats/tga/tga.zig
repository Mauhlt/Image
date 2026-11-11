//! TGA (Targa): true-color 15/16/24/32-bit, grayscale 8/16-bit (gray+alpha),
//! color-mapped 8-bit, raw or RLE, any origin.
//! Encode: RLE, top-left origin; g -> gray, ga -> gray+alpha, rgb -> 24-bit, rgba -> 32-bit.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const Header = @import("header.zig");

/// Output layout: TGA stores BGR(A) so those are returned without a swizzle.
fn outTag(hdr: *const Header) PixelTag {
    return switch (hdr.image_type.base()) {
        .grayscale => if (hdr.depth == 16) .ga else .g,
        .color_mapped => if (hdr.cmap_depth == 32) .bgra else .bgr,
        else => if (hdr.depth == 32) .bgra else .bgr,
    };
}

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data);
    const tag = outTag(&hdr);
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

/// Converts one stored pixel (`src`, `in_bpp` bytes) to the output layout.
inline fn convertPixel(hdr: *const Header, cmap: []const u8, src: []const u8, dst: []u8) Error!void {
    const base = hdr.image_type.base();
    var px = src;
    var depth = hdr.depth;
    if (base == .color_mapped) {
        const idx = @as(usize, src[0]);
        if (idx < hdr.cmap_first) return Error.OutOfBounds;
        const entry = idx - hdr.cmap_first;
        const eb = (@as(usize, hdr.cmap_depth) + 7) / 8;
        if (entry >= hdr.cmap_len) return Error.OutOfBounds;
        px = cmap[entry * eb ..][0..eb];
        depth = hdr.cmap_depth;
    }
    switch (depth) {
        8 => dst[0] = px[0],
        15, 16 => if (base == .grayscale) {
            dst[0] = px[0];
            dst[1] = px[1];
        } else {
            // ARRRRRGG GGGBBBBB (little endian)
            const v = std.mem.readInt(u16, px[0..2], .little);
            dst[0] = expand5(@truncate(v));
            dst[1] = expand5(@truncate(v >> 5));
            dst[2] = expand5(@truncate(v >> 10));
        },
        24 => @memcpy(dst[0..3], px[0..3]),
        32 => @memcpy(dst[0..4], px[0..4]),
        else => return Error.UnsupportedDepth,
    }
}

fn expand5(v: u5) u8 {
    return (@as(u8, v) << 3) | (@as(u8, v) >> 2);
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    _ = scratch;
    const hdr: Header = try .decode(data);
    if (outTag(&hdr) != inf.tag) return Error.InvalidHeader;
    const width: usize = hdr.width;
    const height: usize = hdr.height;
    const in_bpp = (@as(usize, hdr.depth) + 7) / 8;
    const out_bpp = inf.tag.bytesPerPixel();
    const cmap = data[hdr.cmapOffset()..][0..hdr.cmapBytes()];
    const src = data[hdr.pixelOffset()..];

    // pixels arrive in file order; map file index -> (x, y) in a top-left image
    var pos: usize = 0;
    var n: usize = 0;
    const total = width * height;
    while (n < total) {
        var count: usize = 1;
        var is_run = false;
        if (hdr.image_type.isRle()) {
            if (pos >= src.len) return Error.UnexpectedEndOfData;
            const packet = src[pos];
            pos += 1;
            count = (packet & 0x7F) + 1;
            is_run = packet & 0x80 != 0;
            if (n + count > total) return Error.InvalidRLEData;
        }
        var px: [4]u8 = undefined;
        if (is_run) {
            if (pos + in_bpp > src.len) return Error.UnexpectedEndOfData;
            try convertPixel(&hdr, cmap, src[pos..][0..in_bpp], &px);
            pos += in_bpp;
        }
        for (0..count) |_| {
            if (!is_run) {
                if (pos + in_bpp > src.len) return Error.UnexpectedEndOfData;
                try convertPixel(&hdr, cmap, src[pos..][0..in_bpp], &px);
                pos += in_bpp;
            }
            const fy = n / width;
            const fx = n % width;
            const y = if (hdr.topDown()) fy else height - 1 - fy;
            const x = if (hdr.rightToLeft()) width - 1 - fx else fx;
            @memcpy(out[(y * width + x) * out_bpp ..][0..out_bpp], px[0..out_bpp]);
            n += 1;
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

test "tga 16-bit pixel expansion" {
    try std.testing.expectEqual(@as(u8, 255), expand5(31));
    try std.testing.expectEqual(@as(u8, 0), expand5(0));
}
