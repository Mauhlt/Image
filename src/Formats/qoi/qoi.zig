const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../error.zig");

const Header = @import("header.zig");

const Image = @import("../../root.zig");
const RGB = @import("../../Colors/rgb.zig").RGB;
const RGBA = @import("../../Colors/rgba.zig").RGBA;
const Pixels = @import("../../Colors/pixels.zig").Pixels;

const SIG = @import("misc.zig").SIG;

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

fn hashRGB(rgb: RGB) u8 {
    return (rgb.r *% 3 +% //
        rgb.g *% 5 +% //
        rgb.b *% 7 +% //
        @as(u8, 255) *% 11) & //
        @as(u8, 63);
}

fn hashRGBA(rgba: RGBA) u8 {
    return (rgba.r *% 3 +% //
        rgba.g *% 5 +% //
        rgba.b *% 7 +% //
        rgba.a *% 11) & //
        @as(u8, 63);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    const hdr: Header = try .decode(data);
    const fmt: Format = switch (hdr.channel) {
        .rgb => switch (hdr.colorspace) {
            .srgb => .r8g8b8_srgb,
            .linear => .r8g8b8_uint,
        },
        .rgba => switch (hdr.colorspace) {
            .srgb => .r8g8b8a8_srgb,
            .linear => .r8g8b8a8_uint,
        },
    };
    const n_pixels, const overflow = @mulWithOverflow(hdr.width, hdr.height);
    if (overflow > 0) return Error.Decode.InvalidDimensions;
    const pixels_slice = data[14 .. data.len - END_MARKER.len];
    const pixels: Pixels = switch (hdr.channel) {
        .rgb => try decodeRgb(gpa, n_pixels, pixels_slice),
        .rgba => try decodeRgba(gpa, n_pixels, pixels_slice),
    };
    errdefer pixels.deinit(gpa);
    for (data[data.len - END_MARKER.len ..], END_MARKER) |dem, em| {
        if (dem != em) return Error.Decode.InvalidEndMarker;
    }
    return .{
        .fmt = fmt,
        .width = hdr.width,
        .height = hdr.height,
        .pixels = pixels,
    };
}

pub fn encode(img: *const Image, w: *std.Io.Writer) !void {
    const hdr: Header = try .fromImage(img);
    try hdr.encode(w);
    switch (img.pixels) {
        .rgb => |rgb| try encodeRgb(w, rgb),
        .rgba => |rgba| try encodeRgba(w, rgba),
        else => return Error.Encode.InvalidColorspace,
    }
    try w.writeAll(END_MARKER[0..END_MARKER.len]);
    try w.flush();
}

fn decodeRgb(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !Pixels {
    if (data.len == 0) return Error.Decode.InvalidDataLen;
    const rgb_pxs: Pixels = .{ .rgb = try gpa.alloc(RGB, n_pixels) };
    // var rgb_pxs: Pixels = try .initEmpty(gpa, .rgbs, n_pixels);
    errdefer rgb_pxs.deinit(gpa);
    var prev: RGB = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var px: RGB = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var table: [HASH_TABLE_SIZE]RGB = @splat(.{
        .r = 0,
        .g = 0,
        .b = 0,
    });
    var i: usize = 0; // data idx
    var j: usize = 0; // rgbs idx
    while (i < data.len) : (i += 1) {
        const byte1 = data[i];
        switch (@as(ByteTags, @enumFromInt(byte1))) {
            .rgb => {
                if (i + 3 >= data.len) return Error.Decode.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                i += 3;
            },
            .rgba => return error.InvalidByteTag,
            else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
                .run => {
                    const run = (byte1 & 0x3F) + 1;
                    if (j + run > n_pixels) return Error.Decode.OutOfBounds;
                    @memset(rgb_pxs.rgb[j..][0..run], prev);
                    j += run;
                    continue;
                },
                .index => {
                    const index = byte1 & 0x3F;
                    px = table[index];
                },
                .diff => {
                    px.r = prev.r +% ((byte1 >> 4) & 0x03) -% 2;
                    px.g = prev.g +% ((byte1 >> 2) & 0x03) -% 2;
                    px.b = prev.b +% (byte1 & 0x03) -% 2;
                },
                .luma => {
                    i += 1;
                    if (i >= data.len) return Error.Decode.OutOfBounds;
                    const byte2 = data[i];
                    const drgb: RGB = .{
                        .r = ((byte2 & 0xF0) >> 4) +% (byte1 & 0x3F),
                        .g = (byte1 & 0x3F),
                        .b = (byte2 & 0x0F) +% (byte1 & 0x3F),
                    };
                    px.r = prev.r +% drgb.r -% 40;
                    px.g = prev.g +% drgb.g -% 32;
                    px.b = prev.b +% drgb.b -% 40;
                },
            }
        }
        prev = px;
        table[hashRGB(px)] = px;
        if (j > n_pixels) return Error.Decode.OutOfBounds;
        rgb_pxs.rgb[j] = px;
        j += 1;
    }
    if (rgb_pxs.rgb.len != n_pixels) return Error.Decode.MismatchInNumberOfPixels;
    return rgb_pxs;
}

fn decodeRgba(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !Pixels {
    if (data.len == 0) return Error.Decode.InvalidDataLen;
    const rgba_pxs: Pixels = .{ .rgba = try gpa.alloc(RGBA, n_pixels) };
    errdefer rgba_pxs.deinit(gpa);
    var prev: RGBA = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var px: RGBA = .{
        .r = 0,
        .g = 0,
        .b = 0,
    };
    var table: [HASH_TABLE_SIZE]RGBA = @splat(.{
        .r = 0,
        .g = 0,
        .b = 0,
    });
    var i: usize = 0; // data idx
    var j: usize = 0; // rgbas idx
    while (i < data.len) : (i += 1) {
        const byte1 = data[i];
        switch (@as(ByteTags, @enumFromInt(byte1))) {
            .rgb => {
                if (i + 3 >= data.len) return Error.Decode.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                i += 3;
            },
            .rgba => {
                if (i + 4 >= data.len) return Error.Decode.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                px.a = data[i + 4];
                i += 4;
            },
            else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
                .run => {
                    const run = (byte1 & 0x3F) + 1;
                    if (j + run > n_pixels) return Error.Decode.OutOfBounds;
                    @memset(rgba_pxs.rgba[j..][0..run], prev);
                    j += run;
                    continue;
                },
                .index => {
                    const index = byte1 & 0x3F;
                    px = table[index];
                },
                .diff => {
                    px.r = prev.r +% ((byte1 >> 4) & 0x03) -% 2;
                    px.g = prev.g +% ((byte1 >> 2) & 0x03) -% 2;
                    px.b = prev.b +% (byte1 & 0x03) -% 2;
                },
                .luma => {
                    i += 1;
                    if (i >= data.len) return Error.Decode.OutOfBounds;
                    const byte2 = data[i];
                    const drgb: RGB = .{
                        .r = ((byte2 & 0xF0) >> 4) +% (byte1 & 0x3F),
                        .g = byte1 & 0x3F,
                        .b = ((byte2 & 0x0F)) +% (byte1 & 0x3F),
                    };
                    px.r = prev.r +% drgb.r -% 40;
                    px.g = prev.g +% drgb.g -% 32;
                    px.b = prev.b +% drgb.b -% 40;
                },
            }
        }
        prev = px;
        table[hashRGBA(px)] = px;
        if (j > n_pixels) return Error.Decode.OutOfBounds;
        rgba_pxs.rgba[j] = px;
        j += 1;
    }
    if (rgba_pxs.rgba.len != n_pixels) return Error.Decode.MismatchInNumberOfPixels;
    return rgba_pxs;
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
        if (table[index].eql(px)) {
            const byte = (@as(u8, @intFromEnum(BitTags.index)) << 6) | index;
            try w.writeByte(byte);
            continue;
        }
        table[index] = px;

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

test "QOI" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    { // RGB
        // Expected (6 Total): rgb, run, diff, luma, index, rgb
        const data = [_]u8{
            255, 255, 10, // rgb
            255, 255, 10, //
            255, 255, 10, // run (1)
            253, 253, 8, // diff
            17, 10, 17, // luma
            255, 255, 10, // index
            30, 30, 30, // rgb
        };

        const rgb_pxs: Pixels = try .init(.rgb, gpa, &data);
        defer rgb_pxs.deinit(gpa);

        const img1: Image = .{
            .width = @truncate(rgb_pxs.rgb.len),
            .height = 1,
            .pixels = rgb_pxs,
            .fmt = .r8g8b8_srgb,
        };
        // if (@import("builtin").mode == .debug) std.debug.print("{f}\n", .{img1});

        const read_filepath = "src/Data/Read/BasicDecodeRGB.qoi";
        try img1.write(io, gpa, read_filepath);

        var img2: Image = try .read(.{
            .io = io,
            .gpa = gpa,
            .filepath = read_filepath,
        });
        defer img2.deinit(gpa);
        // std.debug.print("{f}\n", .{img2});
        // try img2.printPixels();

        // std.debug.print("Pixels\n", .{});
        const tag1 = std.meta.activeTag(img1.pixels);
        const tag2 = std.meta.activeTag(img2.pixels);
        try std.testing.expect(tag1 == tag2);
        for (img1.pixels.rgb, img2.pixels.rgb) |px1, px2| {
            // std.debug.print("{} {}\n", .{ px1, px2 });
            try std.testing.expectEqualDeep(px1, px2);
        }
    }

    { // RGBA
        // Expected (6 Total): rgba, run, diff, luma, index, rgb, rgba
        const data = [_]u8{
            255, 255, 10, 0, // rgba
            255, 255, 10, 0, //
            255, 255, 10, 0, // run 1
            253, 253, 8, 0, // diff
            17, 10, 17, 0, // luma
            255, 255, 10, 0, // index
            30, 30, 30, 0, // rgb
            170, 170, 170, 170, // rgba
        };
        const rgba_pxs: Pixels = try .init(.rgba, gpa, &data);
        defer rgba_pxs.deinit(gpa);

        const img1: Image = .{
            .width = @truncate(rgba_pxs.rgba.len),
            .height = 1,
            .pixels = rgba_pxs,
            .fmt = .r8g8b8a8_srgb,
        };
        // std.debug.print("{f}\n", .{img3});
        // try img3.printPixels();

        const read_filepath = "src/Data/Read/BasicDecodeRGBA.qoi";
        try img1.write(io, gpa, read_filepath);

        var img2: Image = try .read(.{
            .io = io,
            .gpa = gpa,
            .filepath = read_filepath,
        });
        defer img2.deinit(gpa);
        // std.debug.print("{f}\n", .{img4});
        // try img4.printPixels();

        const tag1 = std.meta.activeTag(img1.pixels);
        const tag2 = std.meta.activeTag(img2.pixels);
        try std.testing.expect(tag1 == tag2);
        for (img1.pixels.rgba, img2.pixels.rgba) |px1, px2| {
            // std.debug.print("{} {}\n", .{ px1, px2 });
            try std.testing.expectEqualDeep(px1, px2);
        }
    }
}
