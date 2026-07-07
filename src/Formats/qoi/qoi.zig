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

const SIG = @import("misc.zig").SIG;

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

inline fn hashRGB(rgb: RGB) u6 {
    return @truncate(rgb.r *% 3 +% rgb.g *% 5 +% rgb.b *% 7);
}

inline fn hashRGBA(rgba: RGBA) u6 {
    return @truncate(rgba.r *% 3 +% rgba.g *% 5 +% rgba.b *% 7 +% rgba.a *% 11);
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
    const n_pixels = hdr.width * hdr.height;
    const pixels: Pixels = switch (hdr.channel) {
        .rgb => .{ .rgb = try decodeRGB(gpa, n_pixels, data[14 .. data.len - END_MARKER.len]) },
        .rgba => .{ .rgba = try decodeRGBA(gpa, n_pixels, data[14 .. data.len - END_MARKER.len]) },
    };
    errdefer pixels.deinit(gpa);
    for (data[data.len - END_MARKER.len ..], END_MARKER) |dem, em| {
        if (dem != em) return error.InvalidEndMarker;
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
        .rgb => |rgbs| try encodeRGB(w, rgbs),
        .rgba => |rgbas| try encodeRGBA(w, rgbas),
        else => unreachable,
    }
    try w.writeAll(END_MARKER[0..END_MARKER.len]);
    try w.flush();
}

// TODO: Fix me!
fn decodeRGB(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !RGBS {
    var rgbs: RGBS = try .initEmpty(gpa, n_pixels);
    errdefer rgbs.deinit(gpa);

    var prev: RGB = .{};
    var px: RGB = .{};
    var table = [_]RGB{.{}} ** HASH_TABLE_SIZE;
    // std.debug.print("Decode\n", .{});

    var i: usize = 0; // data idx
    var j: usize = 0; // rgbs idx
    while (i < data.len) : (i += 1) {
        const byte1 = data[i];
        switch (@as(ByteTags, @enumFromInt(byte1))) {
            .rgb => {
                // std.debug.print("rgb ", .{});
                if (i + 3 > data.len) return error.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                i += 3;
            },
            .rgba => unreachable,
            else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
                .run => {
                    // std.debug.print("run ", .{});
                    const run = (byte1 & 0x3F) + 1;
                    if (j + run > n_pixels) return error.OutOfBounds;
                    rgbs.setMany(j, run, prev) catch unreachable;
                    j += run;
                    continue;
                },
                .index => {
                    // std.debug.print("index ", .{});
                    const index = byte1 & 0x3F;
                    px = table[index];
                },
                .diff => {
                    // std.debug.print("diff ", .{});
                    px.r = prev.r +% ((byte1 >> 4) & 0x03) -% 2;
                    px.g = prev.g +% ((byte1 >> 2) & 0x03) -% 2;
                    px.b = prev.b +% (byte1 & 0x03) -% 2;
                },
                .luma => {
                    // std.debug.print("luma ", .{});
                    i += 1;
                    if (i >= data.len) return error.OutOfBounds;
                    const byte2 = data[i];
                    const dg = (byte1 & 0x3F);
                    const dr = ((byte2 & 0xF0) >> 4) +% dg;
                    const db = (byte2 & 0x0F) +% dg;
                    px.r = prev.r +% dr -% 40;
                    px.g = prev.g +% dg -% 32;
                    px.b = prev.b +% db -% 40;
                },
            }
        }
        prev = px;
        table[hashRGB(px)] = px;
        rgbs.set(j, px) catch unreachable;
        j += 1;
    }
    // std.debug.print("\n", .{});
    return rgbs;
}

fn decodeRGBA(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !RGBAS {
    var rgbas: RGBAS = try .initEmpty(gpa, n_pixels);
    errdefer rgbas.deinit(gpa);

    var prev: RGBA = .{};
    var px: RGBA = .{};
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
    // std.debug.print("Decode RGBA: ", .{});

    var i: usize = 0; // data idx
    var j: usize = 0; // rgbas idx
    while (i < data.len) : (i += 1) {
        const byte1 = data[i];
        switch (@as(ByteTags, @enumFromInt(byte1))) {
            .rgb => {
                // std.debug.print("rgb ", .{});
                if (i + 3 >= data.len) return error.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                i += 3;
            },
            .rgba => {
                // std.debug.print("rgba ", .{});
                if (i + 4 >= data.len) return error.OutOfBounds;
                px.r = data[i + 1];
                px.g = data[i + 2];
                px.b = data[i + 3];
                px.a = data[i + 4];
                i += 4;
            },
            else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
                .run => {
                    // std.debug.print("run ", .{});
                    const run = (byte1 & 0x3F) + 1;
                    rgbas.setMany(j, run, prev) catch unreachable;
                    j += run;
                    continue;
                },
                .index => {
                    // std.debug.print("index ", .{});
                    const index = byte1 & 0x3F;
                    px = table[index];
                },
                .diff => {
                    // std.debug.print("diff ", .{});
                    px.r = prev.r +% ((byte1 >> 4) & 0x03) -% 2;
                    px.g = prev.g +% ((byte1 >> 2) & 0x03) -% 2;
                    px.b = prev.b +% (byte1 & 0x03) -% 2;
                },
                .luma => {
                    // std.debug.print("luma ", .{});
                    i += 1;
                    if (i >= data.len) return error.OutOfBounds;
                    const byte2 = data[i];
                    const dg = (byte1 & 0x3F);
                    const dr = ((byte2 & 0xF0) >> 4) +% dg;
                    const db = (byte2 & 0x0F) +% dg;
                    px.r = prev.r +% dr -% 40;
                    px.g = prev.g +% dg -% 32;
                    px.b = prev.b +% db -% 40;
                },
            }
        }
        prev = px;
        table[hashRGBA(px)] = px;
        rgbas.set(j, px) catch unreachable;
        j += 1;
    }
    // std.debug.print("\n", .{});
    if (rgbas.len != n_pixels) return error.MismatchInNumberOfPixels;
    return rgbas;
}

fn encodeRGB(w: *std.Io.Writer, rgbs: RGBS) !void {
    var px: RGB = .{};
    var prev: RGB = .{};
    var table = [_]RGB{.{}} ** HASH_TABLE_SIZE;
    var i: usize = 0;
    // std.debug.print("Encode RGB: ", .{});

    const len = rgbs.len;
    while (i < len) : (i += 1) {
        px = try rgbs.get(i);
        defer prev = px;

        const n = first64RGBMatchesAt(rgbs, i, prev);
        if (n > 1) {
            const run = @min(n, 63) - 1;
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            // std.debug.print("run ", .{});
            i += run;
            continue;
        }

        const index = hashRGB(px);
        if (table[index].eql(px)) {
            const byte = (@as(u8, @intFromEnum(BitTags.index)) << 6) | index;
            try w.writeByte(byte);
            // std.debug.print("index ", .{});
            continue;
        }
        table[index] = px;

        const diff: RGB = .{
            .r = px.r -% prev.r +% 2, // 0..3
            .g = px.g -% prev.g +% 2, // 0..3
            .b = px.b -% prev.b +% 2, // 0..3
        };
        if (diff.r < 4 and diff.g < 4 and diff.b < 4) {
            const byte = (@as(u8, @intFromEnum(BitTags.diff)) << 6) | //
                ((diff.r & 0x03) << 4) | //
                ((diff.g & 0x03) << 2) | //
                (diff.b & 0x03);
            try w.writeByte(byte);
            // std.debug.print("diff ", .{});
            continue;
        }

        const dg = px.g -% prev.g +% 32;
        const drdg = (px.r -% prev.r) -% (px.g -% prev.g) +% 8;
        const dbdg = (px.b -% prev.b) -% (px.g -% prev.g) +% 8;
        if (dg < 64 and drdg < 16 and dbdg < 16) {
            const byte1 = (@as(u8, @intFromEnum(BitTags.luma)) << 6) | dg;
            const byte2 = (drdg << 4) | dbdg;
            try w.writeByte(byte1);
            try w.writeByte(byte2);
            // std.debug.print("luma ", .{});
            continue;
        }

        const byte = @as(u8, @intFromEnum(ByteTags.rgb));
        try w.writeByte(byte);
        try w.writeByte(px.r);
        try w.writeByte(px.g);
        try w.writeByte(px.b);
        // std.debug.print("rgb ", .{});
    }
    // std.debug.print("\n", .{});
}

fn encodeRGBA(w: *std.Io.Writer, rgbas: RGBAS) !void {
    var px: RGBA = .{};
    var prev: RGBA = .{};
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
    var i: usize = 0;
    // std.debug.print("Encode RGBA: ", .{});

    while (i < rgbas.len) : (i += 1) {
        px = try rgbas.get(i);
        defer prev = px;

        const n = first64RGBAMatchesAt(rgbas, i, prev);
        if (n > 1) {
            // std.debug.print("run ", .{});
            const run = @min(n, 62) - 1;
            const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
            try w.writeByte(byte);
            i += run;
            continue;
        }

        const index = hashRGBA(px);
        if (table[index].eql(px)) {
            // std.debug.print("index ", .{});
            const byte = @as(u8, @intFromEnum(BitTags.index)) << 6 | index;
            try w.writeByte(byte);
            continue;
        }
        table[index] = px;

        if (px.a == prev.a) {
            const diff: RGB = .{
                .r = px.r -% prev.r +% 2, // 0..3
                .g = px.g -% prev.g +% 2, // 0..3
                .b = px.b -% prev.b +% 2, // 0..3
            };
            if (diff.r < 4 and diff.g < 4 and diff.b < 4) {
                // std.debug.print("diff ", .{});
                const byte = @as(u8, //
                    @intFromEnum(BitTags.diff)) << 6 | //
                    ((diff.r & 0x03) << 4) | //
                    ((diff.g & 0x03) << 2) | //
                    (diff.b & 0x03);
                try w.writeByte(byte);
                continue;
            }

            const dg = px.g -% prev.g +% 32;
            const drdg = (px.r -% prev.r) -% (px.g -% prev.g) +% 8;
            const dbdg = (px.b -% prev.b) -% (px.g -% prev.g) +% 8;
            if (dg < 64 and drdg < 16 and dbdg < 16) {
                // std.debug.print("luma ", .{});
                const byte1 = (@as(u8, @intFromEnum(BitTags.luma)) << 6) | dg;
                const byte2 = (drdg << 4) | dbdg;
                try w.writeByte(byte1);
                try w.writeByte(byte2);
                // std.debug.print("luma ", .{});
                continue;
            }

            // std.debug.print("rgb ", .{});
            const byte1 = @intFromEnum(ByteTags.rgb);
            try w.writeByte(byte1);
            try w.writeByte(px.r);
            try w.writeByte(px.g);
            try w.writeByte(px.b);
        } else {
            // std.debug.print("rgba ", .{});
            const byte1 = @intFromEnum(ByteTags.rgba);
            try w.writeByte(byte1);
            try w.writeByte(px.r);
            try w.writeByte(px.g);
            try w.writeByte(px.b);
            try w.writeByte(px.a);
        }
    }
    // std.debug.print("\n", .{});
}

pub fn first64RGBMatchesAt(self: RGBS, i: usize, rgb: RGB) u8 {
    const V64 = @Vector(64, u8);
    const rs: V64 = @splat(rgb.r);
    const gs: V64 = @splat(rgb.g);
    const bs: V64 = @splat(rgb.b);
    if (i >= self.len) return 0;
    if (i + 63 < self.len) {
        const r2s: V64 = self.ptr[i..][0..64].*;
        const g2s: V64 = self.ptr[self.len + i ..][0..64].*;
        const b2s: V64 = self.ptr[2 * self.len + i ..][0..64].*;
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

pub fn first64RGBAMatchesAt(self: RGBAS, i: usize, rgba: RGBA) u8 {
    const V64 = @Vector(64, u8);
    const rs: V64 = @splat(rgba.r);
    const gs: V64 = @splat(rgba.g);
    const bs: V64 = @splat(rgba.b);
    const as: V64 = @splat(rgba.a);
    if (i >= self.len) return 0;
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
        var rgbs: RGBS = try .init(allo, &data1, .rgb);
        defer rgbs.deinit(allo);
        const n_matches = first64RGBMatchesAt(rgbs, 0, .{ .r = 255, .g = 100, .b = 0 });
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
        var rgbs: RGBS = try .init(allo, &data1, .rgb);
        defer rgbs.deinit(allo);
        const n_matches = first64RGBMatchesAt(rgbs, 0, .{ .r = 255, .g = 100, .b = 0 });
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
        var rgbas: RGBAS = try .init(allo, &data1, .rgba);
        defer rgbas.deinit(allo);
        const n_matches = first64RGBAMatchesAt(rgbas, 0, .{ .r = 255, .g = 100, .b = 0, .a = 255 });
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
        var rgbas: RGBAS = try .init(allo, &data1, .rgba);
        defer rgbas.deinit(allo);
        const n_matches = first64RGBAMatchesAt(rgbas, 0, .{ .r = 255, .g = 100, .b = 0, .a = 255 });
        try std.testing.expectEqual(n_matches, 47);
    }
}
