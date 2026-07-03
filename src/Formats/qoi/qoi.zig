const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../error.zig");

const Header = @import("header.zig");

const Image = @import("../../root.zig");
const GRAY = @import("../../Colors/gray.zig");
const GRAYS = @import("../../Colors/grays.zig");
const RGB = @import("../../Colors/rgb.zig");
const RGBS = @import("../../Colors/rgbs.zig");
const RGBA = @import("../../Colors/rgba.zig");
const RGBAS = @import("../../Colors/rgbas.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

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

inline fn hashRGBA(rgba: RGBA) u6 {
    return @truncate(rgba.r *% 3 +% rgba.g *% 5 +% rgba.b *% 7 +% rgba.a *% 11);
}

inline fn hashRGB(rgb: RGB) u6 {
    return @truncate(rgb.r *% 3 +% rgb.g *% 5 +% rgb.b *% 7);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void { // !Image {
    const hdr: Header = try .decode(data);
    const fmt = blk: {
        var buf: [8]u8 = undefined;
        const fmt_str = try std.fmt.bufPrint(&buf, "{}_{}\n", .{
            switch (hdr.channel) {
                .rgb => "r8g8b8",
                .rgba => "r8g8b8a8",
            },
            switch (hdr.colorspace) {
                .srgb => "srgb",
                .linear => "unorm",
            },
        });
        const fmt = std.meta.stringToEnum(Format, fmt_str) orelse unreachable;
        break :blk fmt;
    };
    const n_pixels = hdr.width * hdr.height;
    const pixels = switch (hdr.channel) {
        .rgb => try decodeRGB(gpa, n_pixels),
        .rgba => try decodeRGBA(gpa, n_pixels),
    };
    if (std.mem.eql(u8, data[data.len - END_MARKER.len .. data.len], END_MARKER[0..END_MARKER.len])) //
        return error.InvalidEndMarker;
    return .{
        .fmt = fmt,
        .width = hdr.width,
        .height = hdr.height,
        .pixels = pixels,
    };
}

pub fn encode(w: *std.Io.Writer, img: *const Image) !void {
    const hdr: Header = try .fromImage(img);
    try hdr.encode(w);
    switch (img.pixels) {
        .rgb => |rgbs| try encodeRGB(w, rgbs),
        .rgba => |rgbas| try encodeRGBA(w, rgbas),
    }
    for (END_MARKER) |em| try w.writeByte(em);
    try w.flush();
}

fn decodeRGB(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !RGBS {
    var rgbs: RGBS = try .initEmpty(gpa, n_pixels);
    errdefer rgbs.deinit(gpa);

    var prev: RGB = .{};
    var table = [_]RGB{.{}} ** HASH_TABLE_SIZE;

    var i: usize = 0; // data idx
    var j: usize = 0; // rgbs idx
    while (i < data.len) : (i += 1) {
        const byte1 = data[i];
        switch (@as(ByteTags, @enumFromInt(byte1))) {
            .rgb => {
                prev = .{ .r = data[i + 1], .g = data[i + 2], .b = data[i + 3] };
                rgbs.set(j, prev);
                i += 3;
                j += 1;
                continue;
            },
            .rgba => unreachable,
            else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
                .run => {
                    const run = (byte1 & 0x3F) + 1;
                    @memset(rgbs.ptr[j..][0..run], prev.r);
                    @memset(rgbs.ptr[rgbs.len + j ..][0..run], prev.g);
                    @memset(rgbs.ptr[2 * rgbs.len + j ..][0..run], prev.b);
                    j += run;
                },
                .index => {},
                .diff => {},
                .luma => {},
            }
        }
    }
    return rgbs;
}

fn decodeRGBA(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !RGBAS {
    var rgbas: RGBAS = try .initEmpty(gpa, n_pixels);
    errdefer rgbas.deinit(gpa);
}

fn encodeRGB(w: *std.Io.Writer, rgbs: RGBS) !void {
    var px: RGB = .{};
    var prev: RGB = .{};
    var table = [_]RGB{.{}} ** HASH_TABLE_SIZE;
    var i: usize = 0;

    {
        const n = try first64RGBMatchesAt(rgbs, 0, px);
        if (n > 1) {
            const run = @min(n, 63) - 1; // 1..62
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            i += run;
        }
    }

    while (i < rgbs.len) : (i += 1) {
        px = rgbs.get(i) catch unreachable;

        const n = try first64RGBMatchesAt(rgbs, i, px);
        if (n > 1) {
            const run = @min(n, 63) - 1; // 1..62
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            i += run;
            prev = px;
            continue;
        }

        const index = hashRGB(px);
        if (table[index].eql(px)) {
            const byte = @as(u8, @intFromEnum(BitTags.index)) << 6 | index;
            try w.writeByte(byte);
            prev = px;
            continue;
        }
        table[index] = px;

        const diff: RGB = .{
            .r = px.r -% prev.r +% 2, // 0..3
            .g = px.g -% prev.g +% 2, // 0..3
            .b = px.b -% prev.b +% 2, // 0..3
        };
        if (diff.r <= 3 and diff.g <= 3 and diff.b <= 3) {
            const byte = @as(u8, //
                @intFromEnum(BitTags.diff)) << 6 | //
                ((diff.r & 0x03) << 4) | //
                ((diff.g & 0x03) << 2) | //
                (diff.b & 0x03);
            try w.writeByte(byte);
            prev = px;
            continue;
        }

        const luma: RGB = .{
            .r = (px.r -% prev.r) -% (px.g -% prev.g) +% 40, // drdg
            .g = (px.g -% prev.g) +% 32, // dg
            .b = (px.b -% prev.b) -% (px.g -% prev.g) +% 40, // dbdg
        };
        if (luma.g < 64 and luma.r < 16 and luma.b < 16) {
            const byte = @as(u8, @intFromEnum(BitTags.luma)) << 6 | (luma.g & 0x3F);
            const byte2 = luma.r << 4 | luma.b;
            try w.writeByte(byte);
            try w.writeByte(byte2);
            prev = px;
            continue;
        }

        prev = px;
        try w.writeByte(px.r);
        try w.writeByte(px.g);
        try w.writeByte(px.b);
    }
}

fn encodeRGBA(w: *std.Io.Writer, rgbas: RGBAS) !void {
    var px: RGBA = .{};
    var prev: RGBA = .{};
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
    var i: usize = 0;

    {
        const n = try first64RGBAMatchesAt(rgbas, 0, px);
        if (n > 1) {
            const run = @min(n, 62) - 1;
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            i += run;
        }
    }

    while (i < rgbas.len) : (i += 1) {
        px = rgbas.get(i) catch unreachable;

        const n = try first64RGBAMatchesAt(rgbas, i, px);
        if (n > 1) {
            const run = @min(n, 62) - 1;
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            i += run;
            prev = px;
            continue;
        }

        const index = hashRGBA(px);
        if (table[index].eql(px)) {
            const byte = @as(u8, @intFromEnum(BitTags.index)) << 6 | index;
            try w.writeByte(byte);
            prev = px;
            continue;
        }
        table[index] = px;

        if (px.a == prev.a) {
            const diff: RGB = .{
                .r = px.r -% prev.r +% 2, // 0..3
                .g = px.g -% prev.g +% 2, // 0..3
                .b = px.b -% prev.b +% 2, // 0..3
            };
            if (diff.r <= 3 and diff.g <= 3 and diff.b <= 3) {
                const byte = @as(u8, //
                    @intFromEnum(BitTags.diff)) << 6 | //
                    ((diff.r & 0x03) << 4) | //
                    ((diff.g & 0x03) << 2) | //
                    (diff.b & 0x03);
                try w.writeByte(byte);
                prev = px;
                continue;
            }

            const luma: RGB = .{
                .r = (px.r -% prev.r) -% (px.g -% prev.g) +% 40, // drdg
                .g = (px.g -% prev.g) +% 32, // dg
                .b = (px.b -% prev.b) -% (px.g -% prev.g) +% 40, // dbdg
            };
            if (luma.g < 64 and luma.r < 16 and luma.b < 16) {
                const byte = @as(u8, @intFromEnum(BitTags.luma)) << 6 | (luma.g & 0x3F);
                const byte2 = luma.r << 4 | luma.b;
                try w.writeByte(byte);
                try w.writeByte(byte2);
                prev = px;
                continue;
            }

            prev = px;
            const byte = @intFromEnum(ByteTags.rgb);
            try w.writeByte(byte);
            try w.writeByte(px.r);
            try w.writeByte(px.g);
            try w.writeByte(px.b);
        } else {
            prev = px;
            const byte = @intFromEnum(ByteTags.rgba);
            try w.writeByte(byte);
            try w.writeByte(px.r);
            try w.writeByte(px.g);
            try w.writeByte(px.b);
            try w.writeByte(px.a);
        }
    }
}

pub fn first64RGBMatchesAt(self: RGBS, i: usize, rgb: RGB) !u8 {
    if (i >= self.len) return error.OutOfBounds;
    const V64 = @Vector(64, u8);
    const rs: V64 = @splat(rgb.r);
    const gs: V64 = @splat(rgb.g);
    const bs: V64 = @splat(rgb.b);
    if (i + 63 < self.len) {
        const r2s: V64 = self.ptr[i..][0..64].*;
        const g2s: V64 = self.ptr[self.len * 1 + i ..][0..64].*;
        const b2s: V64 = self.ptr[self.len * 2 + i ..][0..64].*;
        const match: u64 = @bitCast((r2s != rs) | (g2s != gs) | (b2s != bs));
        return @truncate(@ctz(match));
    }
    const len = self.len - i;
    if (len == 0) return 0;
    var r2s = [_]u8{0} ** 64;
    var g2s = [_]u8{0} ** 64;
    var b2s = [_]u8{0} ** 64;
    @memcpy(r2s[0..len], self.ptr[i..self.len]);
    @memcpy(g2s[0..len], self.ptr[i + self.len .. 2 * self.len]);
    @memcpy(b2s[0..len], self.ptr[i + self.len * 2 .. 3 * self.len]);
    const match: u64 = @bitCast((r2s != rs) | (g2s != gs) | (b2s != bs));
    return @truncate(@min(len, @ctz(match)));
}

pub fn first64RGBAMatchesAt(self: RGBAS, i: usize, rgba: RGBA) !u8 {
    if (i >= self.len) return error.OutOfBounds;
    const V64 = @Vector(64, u8);
    const rs: V64 = @splat(rgba.r);
    const gs: V64 = @splat(rgba.g);
    const bs: V64 = @splat(rgba.b);
    const as: V64 = @splat(rgba.a);
    if (i + 63 < self.len) {
        const r2s: V64 = self.ptr[i..][0..64].*;
        const g2s: V64 = self.ptr[self.len * 1 + i ..][0..64].*;
        const b2s: V64 = self.ptr[self.len * 2 + i ..][0..64].*;
        const a2s: V64 = self.ptr[self.len * 3 + i ..][0..64].*;
        const match: u64 = @bitCast((r2s != rs) | (g2s != gs) | (b2s != bs) | (a2s != as));
        return @truncate(@ctz(match));
    }
    const len = self.len - i;
    if (len == 0) return 0;
    var r2s = [_]u8{0} ** 64;
    var g2s = [_]u8{0} ** 64;
    var b2s = [_]u8{0} ** 64;
    var a2s = [_]u8{0} ** 64;
    @memcpy(r2s[0..len], self.ptr[i..self.len]);
    @memcpy(g2s[0..len], self.ptr[i + self.len .. 2 * self.len]);
    @memcpy(b2s[0..len], self.ptr[i + self.len * 2 .. 3 * self.len]);
    @memcpy(a2s[0..len], self.ptr[i + self.len * 3 .. 4 * self.len]);
    const match: u64 = @bitCast((r2s != rs) | (g2s != gs) | (b2s != bs) | (a2s != as));
    return @truncate(@min(len, @ctz(match)));
}

test "First 64 Matches" {
    const allo = std.testing.allocator;

    {
        // Mismatch at 63
        const data1 = [_]u8{
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 10, //
        };
        const rgbs: RGBS = try .init(allo, &data1, .rgb);
        defer rgbs.deinit(allo);
        const n_matches = try first64RGBMatchesAt(0);
        try std.testing.expectEqual(63, n_matches);
    }

    {
        // Mismatch at 47
        const data1 = [_]u8{
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 0, //
            255, 100, 10, //
        };
        const rgbs: RGBS = try .init(allo, &data1, .rgb);
        defer rgbs.deinit(allo);
        const n_matches = try first64RGBMatchesAt(0);
        try std.testing.expectEqual(n_matches, 47);
    }

    {
        // Mismatch at 63
        const data1 = [_]u8{
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 10, 255, //
        };
        const rgbas = try .init(allo, &data1, .rgba);
        defer rgbas.deinit(allo);
        const n_matches = try first64RGBAMatchesAt(0);
        try std.testing.expectEqual(63, n_matches);
    }

    {
        // Mismatch at 47
        const data1 = [_]u8{
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 0, 255, //
            255, 100, 10, 255, //
        };
        const rgbas: RGBAS = try .init(allo, &data1, .rgba);
        defer rgbas.deinit(allo);
        const n_matches = try first64RGBAMatchesAt(0);
        try std.testing.expectEqual(n_matches, 47);
    }
}
