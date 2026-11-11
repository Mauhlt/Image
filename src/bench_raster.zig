//! Raster-format and pixel-conversion cases for `zig build bench`: BMP, TGA and netpbm
//! layouts the stock BasicArt files don't cover, built in memory from BasicArt's pixels,
//! plus `Pixels.convertV` between common tags. Prints the median of `N_ITERS` runs.
const std = @import("std");
const Image = @import("Image");

const N_ITERS = 15;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn medianMs(samples: []i96) f64 {
    std.mem.sort(i96, samples, {}, std.sort.asc(i96));
    return @as(f64, @floatFromInt(samples[samples.len / 2])) / 1e6;
}

fn report(name: []const u8, ms: f64, n_pixels: usize) void {
    const mpix = @as(f64, @floatFromInt(n_pixels)) / 1e6;
    std.debug.print("{s:<34} {d:>10.2} {d:>12.1}\n", .{ name, ms, mpix / (ms / 1000) });
}

fn benchDecode(io: std.Io, gpa: std.mem.Allocator, name: []const u8, tag: Image.ImageTag, data: []const u8) !void {
    const inf = try Image.info(tag, data);
    const out = try gpa.alloc(u8, try inf.byteLen());
    defer gpa.free(out);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var samples: [N_ITERS]i96 = undefined;
    for (&samples) |*s| {
        const start = nowNs(io);
        try Image.decodeInto(tag, arena.allocator(), data, inf, out);
        s.* = nowNs(io) - start;
        _ = arena.reset(.retain_capacity);
    }
    report(name, medianMs(&samples), try inf.nPixels());
}

/// Uncompressed-header BMP (bottom-up); `extra` is the masks or the palette.
fn bmpFile(gpa: std.mem.Allocator, w: u32, h: u32, bpp: u16, compression: u32, extra: []const u8, pixels: []const u8) ![]u8 {
    const offset: u32 = @intCast(14 + 40 + extra.len);
    const file = try gpa.alloc(u8, offset + pixels.len);
    @memset(file[0..offset], 0);
    file[0..2].* = "BM".*;
    std.mem.writeInt(u32, file[2..6], @intCast(file.len), .little);
    std.mem.writeInt(u32, file[10..14], offset, .little);
    std.mem.writeInt(u32, file[14..18], 40, .little);
    std.mem.writeInt(i32, file[18..22], @intCast(w), .little);
    std.mem.writeInt(i32, file[22..26], @intCast(h), .little);
    std.mem.writeInt(u16, file[26..28], 1, .little);
    std.mem.writeInt(u16, file[28..30], bpp, .little);
    std.mem.writeInt(u32, file[30..34], compression, .little);
    std.mem.writeInt(u32, file[34..38], @intCast(pixels.len), .little);
    if (bpp <= 8) std.mem.writeInt(u32, file[46..50], @intCast(extra.len / 4), .little);
    @memcpy(file[54..offset], extra);
    @memcpy(file[offset..], pixels);
    return file;
}

/// Raw/RLE TGA with an optional color map.
fn tgaFile(gpa: std.mem.Allocator, w: u16, h: u16, image_type: u8, depth: u8, descriptor: u8, cmap_depth: u8, cmap: []const u8, pixels: []const u8) ![]u8 {
    const file = try gpa.alloc(u8, 18 + cmap.len + pixels.len);
    @memset(file[0..18], 0);
    file[1] = @intFromBool(cmap.len > 0);
    file[2] = image_type;
    if (cmap.len > 0) std.mem.writeInt(u16, file[5..7], @intCast(cmap.len / ((cmap_depth + 7) / 8)), .little);
    file[7] = cmap_depth;
    std.mem.writeInt(u16, file[12..14], w, .little);
    std.mem.writeInt(u16, file[14..16], h, .little);
    file[16] = depth;
    file[17] = descriptor;
    @memcpy(file[18..][0..cmap.len], cmap);
    @memcpy(file[18 + cmap.len ..], pixels);
    return file;
}

/// 3-3-2 palette index of an RGB pixel, and the matching 256-entry BGRX palette.
fn index332(p: [3]u8) u8 {
    return (p[0] & 0xE0) | ((p[1] >> 3) & 0x1C) | (p[2] >> 6);
}

fn palette332() [256 * 4]u8 {
    var pal: [256 * 4]u8 = undefined;
    for (0..256) |i| {
        pal[i * 4 ..][0..4].* = .{ @intCast((i & 3) * 85), @intCast(((i >> 2) & 7) * 36), @intCast((i >> 5) * 36), 0 };
    }
    return pal;
}

fn lum(p: [3]u8) u8 {
    return @intCast((@as(u32, p[0]) * 77 + @as(u32, p[1]) * 150 + @as(u32, p[2]) * 29) >> 8);
}

pub fn run(io: std.Io, gpa: std.mem.Allocator) !void {
    const art = try Image.read(.{ .io = io, .gpa = gpa, .filepath = "src/Data/Read/BasicArt.ppm" });
    defer art.deinit(gpa);
    const w = art.width;
    const h = art.height;
    const n: usize = @as(usize, w) * h;
    const rgb = art.pixels.asBytes();
    const px = struct {
        fn at(bytes: []const u8, i: usize) [3]u8 {
            return bytes[i * 3 ..][0..3].*;
        }
    }.at;
    // BMP rows are bottom-up; BasicArt's width keeps every depth's rows 4-byte aligned
    const bmpIndex = struct {
        fn f(width: usize, height: usize, i: usize) usize {
            return (height - 1 - i / width) * width + i % width;
        }
    }.f;

    std.debug.print("\n{s:<34} {s:>10} {s:>12}\n", .{ "raster decode (median)", "ms", "MPix/s" });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    { // BMP 16-bit RGB565 bitfields
        const pixels = try gpa.alloc(u8, n * 2);
        defer gpa.free(pixels);
        for (0..n) |i| {
            const p = px(rgb, bmpIndex(w, h, i));
            const v: u16 = @as(u16, p[0] >> 3) << 11 | @as(u16, p[1] >> 2) << 5 | p[2] >> 3;
            std.mem.writeInt(u16, pixels[i * 2 ..][0..2], v, .little);
        }
        var masks: [12]u8 = undefined;
        std.mem.writeInt(u32, masks[0..4], 0xF800, .little);
        std.mem.writeInt(u32, masks[4..8], 0x07E0, .little);
        std.mem.writeInt(u32, masks[8..12], 0x001F, .little);
        const file = try bmpFile(gpa, w, h, 16, 3, &masks, pixels);
        defer gpa.free(file);
        try benchDecode(io, gpa, "bmp 16-bit 565", .bmp, file);
    }
    { // BMP 32-bit BGRA (V4 bitfields, from the encoder)
        const rgba = try art.convert(.rgba, gpa);
        defer rgba.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try Image.encode(&rgba, .bmp, &aw.writer, gpa);
        try benchDecode(io, gpa, "bmp 32-bit bitfields", .bmp, aw.written());
    }
    { // BMP 8-bit color palette, raw and RLE8
        const pal = palette332();
        const pixels = try gpa.alloc(u8, n);
        defer gpa.free(pixels);
        for (0..n) |i| pixels[i] = index332(px(rgb, bmpIndex(w, h, i)));
        const file = try bmpFile(gpa, w, h, 8, 0, &pal, pixels);
        defer gpa.free(file);
        try benchDecode(io, gpa, "bmp 8-bit palette", .bmp, file);

        buf.clearRetainingCapacity();
        for (0..h) |y| {
            const row = pixels[y * w ..][0..w];
            var x: usize = 0;
            while (x < w) {
                var len: usize = 1;
                while (x + len < w and len < 255 and row[x + len] == row[x]) len += 1;
                try buf.appendSlice(gpa, &.{ @intCast(len), row[x] });
                x += len;
            }
            try buf.appendSlice(gpa, &.{ 0, 0 });
        }
        try buf.appendSlice(gpa, &.{ 0, 1 });
        const rle = try bmpFile(gpa, w, h, 8, 1, &pal, buf.items);
        defer gpa.free(rle);
        try benchDecode(io, gpa, "bmp 8-bit RLE8", .bmp, rle);
    }
    { // BMP 4-bit and 1-bit palettes (16 / 2 grays)
        var pal: [16 * 4]u8 = undefined;
        for (0..16) |i| pal[i * 4 ..][0..4].* = .{ @intCast(i * 17), @intCast(i * 17), @intCast(i * 17), 0 };
        const pixels = try gpa.alloc(u8, n / 2);
        defer gpa.free(pixels);
        @memset(pixels, 0);
        for (0..n) |i| pixels[i / 2] |= (lum(px(rgb, bmpIndex(w, h, i))) >> 4) << @intCast(4 - 4 * (i % 2));
        const file = try bmpFile(gpa, w, h, 4, 0, &pal, pixels);
        defer gpa.free(file);
        try benchDecode(io, gpa, "bmp 4-bit palette", .bmp, file);

        const bits = pixels[0 .. n / 8];
        @memset(bits, 0);
        for (0..n) |i| bits[i / 8] |= (lum(px(rgb, bmpIndex(w, h, i))) >> 7) << @intCast(7 - i % 8);
        const pal1 = [_]u8{ 0, 0, 0, 0, 255, 255, 255, 0 };
        const file1 = try bmpFile(gpa, w, h, 1, 0, &pal1, bits);
        defer gpa.free(file1);
        try benchDecode(io, gpa, "bmp 1-bit palette", .bmp, file1);
    }

    const tw: u16 = @intCast(w);
    const th: u16 = @intCast(h);
    { // TGA raw 24-bit top-down, raw 32-bit bottom-up with alpha, raw 16-bit
        const bgr = try art.pixels.convertV(.bgr, gpa);
        defer bgr.deinit(gpa);
        const file = try tgaFile(gpa, tw, th, 2, 24, 0x20, 0, "", bgr.asBytes());
        defer gpa.free(file);
        try benchDecode(io, gpa, "tga raw 24-bit", .tga, file);

        const bgra = try art.pixels.convertV(.bgra, gpa);
        defer bgra.deinit(gpa);
        const file32 = try tgaFile(gpa, tw, th, 2, 32, 0x08, 0, "", bgra.asBytes());
        defer gpa.free(file32);
        try benchDecode(io, gpa, "tga raw 32-bit bottom-up", .tga, file32);

        const p16 = try gpa.alloc(u8, n * 2);
        defer gpa.free(p16);
        for (0..n) |i| {
            const p = px(rgb, i);
            const v: u16 = @as(u16, p[0] >> 3) << 10 | @as(u16, p[1] >> 3) << 5 | p[2] >> 3;
            std.mem.writeInt(u16, p16[i * 2 ..][0..2], v, .little);
        }
        const file16 = try tgaFile(gpa, tw, th, 2, 16, 0x20, 0, "", p16);
        defer gpa.free(file16);
        try benchDecode(io, gpa, "tga raw 16-bit", .tga, file16);
    }
    { // TGA 8-bit color-mapped (24-bit entries), raw
        const pal = palette332();
        var cmap: [256 * 3]u8 = undefined;
        for (0..256) |i| cmap[i * 3 ..][0..3].* = pal[i * 4 ..][0..3].*;
        const idx = try gpa.alloc(u8, n);
        defer gpa.free(idx);
        for (idx, 0..) |*v, i| v.* = index332(px(rgb, i));
        const file = try tgaFile(gpa, tw, th, 1, 8, 0x20, 24, &cmap, idx);
        defer gpa.free(file);
        try benchDecode(io, gpa, "tga 8-bit color-mapped", .tga, file);
    }

    { // netpbm: ASCII P3, 16-bit P5, maxval-100 P6, P4 bitmap
        buf.clearRetainingCapacity();
        var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
        try aw.writer.print("P3\n{} {}\n255\n", .{ w, h });
        for (0..h) |y| {
            for (rgb[y * w * 3 ..][0 .. w * 3]) |s| try aw.writer.print("{} ", .{s});
            try aw.writer.writeByte('\n');
        }
        buf = aw.toArrayList();
        try benchDecode(io, gpa, "ppm ASCII P3", .ppm, buf.items);

        buf.clearRetainingCapacity();
        aw = .fromArrayList(gpa, &buf);
        try aw.writer.print("P5\n{} {}\n65535\n", .{ w, h });
        for (0..n) |i| try aw.writer.writeInt(u16, @as(u16, lum(px(rgb, i))) * 257, .big);
        buf = aw.toArrayList();
        try benchDecode(io, gpa, "pgm 16-bit P5", .pgm, buf.items);

        buf.clearRetainingCapacity();
        aw = .fromArrayList(gpa, &buf);
        try aw.writer.print("P6\n{} {}\n100\n", .{ w, h });
        for (rgb) |s| try aw.writer.writeByte(@intCast(@as(u32, s) * 100 / 255));
        buf = aw.toArrayList();
        try benchDecode(io, gpa, "ppm P6 maxval 100", .ppm, buf.items);

        buf.clearRetainingCapacity();
        aw = .fromArrayList(gpa, &buf);
        try Image.encode(&art, .pbm, &aw.writer, gpa);
        buf = aw.toArrayList();
        try benchDecode(io, gpa, "pbm P4", .pbm, buf.items);
    }

    std.debug.print("\n{s:<34} {s:>10} {s:>12}\n", .{ "convertV (median)", "ms", "MPix/s" });
    const pairs = [_][2]Image.PixelTag{
        .{ .rgb, .rgba },  .{ .rgba, .rgb },  .{ .rgb, .bgr }, .{ .rgba, .bgra },
        .{ .bgr, .rgba },  .{ .rgb, .g },     .{ .g, .rgb },   .{ .g, .rgba },
        .{ .rgb, .ycbcr }, .{ .ycbcr, .rgb }, .{ .rgba, .ga }, .{ .ga, .rgba },
    };
    // an arena reused across runs keeps fresh-page faults of the 5 MB output out of the timing
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (pairs) |pair| {
        const src = try art.pixels.convertV(pair[0], gpa);
        defer src.deinit(gpa);
        var samples: [N_ITERS]i96 = undefined;
        for (&samples) |*s| {
            const start = nowNs(io);
            _ = try src.convertV(pair[1], arena.allocator());
            s.* = nowNs(io) - start;
            _ = arena.reset(.retain_capacity);
        }
        var name_buf: [34]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{t} -> {t}", .{ pair[0], pair[1] });
        report(name, medianMs(&samples), n);
    }
}
