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
        .rgb => try decodeRgb(body, @ptrCast(out)),
        .rgba => try decodeRgba(body, @ptrCast(out)),
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

fn decodeRgb(data: []const u8, out: []RGB) !void {
    const n_pixels = out.len;
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
                if (i + 3 >= data.len) return Error.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                i += 3;
            },
            .rgba => return Error.InvalidChannels,
            else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
                .run => {
                    const run = (byte1 & 0x3F) + 1;
                    if (j + run > n_pixels) return Error.OutOfBounds;
                    @memset(out[j..][0..run], prev);
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
                    if (i >= data.len) return Error.OutOfBounds;
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
        if (j >= n_pixels) return Error.OutOfBounds;
        out[j] = px;
        j += 1;
    }
    if (j != n_pixels) return Error.InvalidNumOfPixels;
}

fn decodeRgba(data: []const u8, out: []RGBA) !void {
    const n_pixels = out.len;
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
                if (i + 3 >= data.len) return Error.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                i += 3;
            },
            .rgba => {
                if (i + 4 >= data.len) return Error.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                px.a = data[i + 4];
                i += 4;
            },
            else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
                .run => {
                    const run = (byte1 & 0x3F) + 1;
                    if (j + run > n_pixels) return Error.OutOfBounds;
                    @memset(out[j..][0..run], prev);
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
                    if (i >= data.len) return Error.OutOfBounds;
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
        if (j >= n_pixels) return Error.OutOfBounds;
        out[j] = px;
        j += 1;
    }
    if (j != n_pixels) return Error.InvalidNumOfPixels;
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
