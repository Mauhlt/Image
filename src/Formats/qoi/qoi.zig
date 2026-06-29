const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../error.zig");

// Header
const Header = @import("header.zig");

// Misc
const Channel = @import("misc.zig").Channel;
const Colorspace = @import("misc.zig").Colorspace;
const ByteTags = @import("misc.zig").ByteTags;
const BitTags = @import("misc.zig").BitTags;
const SIG = @import("misc.zig").SIG;
const END_MARKER = @import("misc.zig").END_MARKER;

// Colors
const Image = @import("../../root.zig");
const GRAY = @import("../../Colors/gray.zig");
const GRAYS = @import("../../Colors/grays.zig");
const RGB = @import("../../Colors/rgb.zig");
const RGBS = @import("../../Colors/rgbs.zig");
const RGBA = @import("../../Colors/rgba.zig");
const RGBAS = @import("../../Colors/rgbas.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

const isSigSame = @import("Misc.zig").isSigSame;

// Constants
pub const HASH_TABLE_SIZE = 64;

pub fn hashRGB(rgb: RGB) u6 {
    return @truncate(rgb.r *% 3 +% rgb.g *% 5 +% rgb.b *% 7);
}

pub fn hashRGBA(rgba: RGBA) u6 {
    return @truncate(rgba.r *% 3 +% rgba.g *% 5 +% rgba.b *% 7 +% rgba.a *% 11);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 22) return error.InvalidDataLength;
    const hdr: Header = try .decode(data[0..14]);
    const pixels_slice = data[14 .. data.len - 8];
    if (!std.mem.eql(u8, data[data.len - END_MARKER.len ..], END_MARKER[0..END_MARKER.len]))
        return Error.Decode.InvalidEndMarker;
    const fmt: Format = switch (hdr.channel) {
        .rgb => .r8g8b8_srgb,
        .rgba => .r8g8b8a8_srgb,
    };
    const n_pixels = hdr.width * hdr.height;
    const pixels: Pixels = switch (hdr.channel) {
        .rgb => try decodeRGB(gpa, n_pixels, pixels_slice),
        .rgba => try decodeRGBA(gpa, n_pixels, pixels_slice),
    };
    defer pixels.deinit(gpa);
    return .{
        .fmt = fmt,
        .width = hdr.width,
        .height = hdr.height,
        .pixels = pixels,
    };
}

pub fn decodeRGB(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !Pixels {
    const pixels: Pixels = .{ .rgb = try .initEmpty(gpa, n_pixels) };
    errdefer pixels.deinit(gpa);

    var i: usize = 0; // data position
    var j: usize = 0; // pixels position
    var prev_pixel: RGB = .{ .r = 0, .b = 0, .g = 0 };
    var table = [_]RGB{.{ .r = 0, .g = 0, .b = 0 }} ** HASH_TABLE_SIZE;
    while (i < data.len) : (i += 1) {
        const byte = data[i];
        const byte_tag: ByteTags = @enumFromInt(byte);
        switch (byte_tag) {
            .rgb => {
                if (i + @sizeOf(RGB) > data.len) //
                    return Error.Decode.UnexpectedEndOfData;
                inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
                    @field(prev_pixel, field_name) = data[i + k + 1];
                }
                i += @sizeOf(RGB);
            },
            .rgba => unreachable,
            else => {
                const bit_tag: BitTags = @enumFromInt(byte >> 6);
                switch (bit_tag) {
                    .index => prev_pixel = table[(byte & 0x3F)],
                    .diff => {
                        const drgb: RGB = .{
                            .r = (byte >> 4) & 0x03,
                            .g = (byte >> 2) & 0x03,
                            .b = byte & 0x03,
                        };
                        inline for (comptime std.meta.fieldNames(RGB)) |field_name| {
                            @field(prev_pixel, field_name) = @field(prev_pixel, field_name) +% @field(drgb, field_name) -% 2;
                        }
                    },
                    .luma => {
                        i += 1;
                        if (i > data.len) //
                            return Error.Decode.UnexpectedEndOfData;
                        const byte2 = data[i];

                        const dg = byte & 0x3F;
                        const drdg = byte2 >> 4;
                        const dbdg = byte2 & 0x0F;

                        prev_pixel.g = prev_pixel.g +% dg -% 32;
                        prev_pixel.r = prev_pixel.r +% drdg +% dg -% 8;
                        prev_pixel.b = prev_pixel.b +% dbdg +% dg -% 8;
                    },
                    .run => {
                        const run: usize = (byte & 0x3F) +% 1;
                        if (j + run > n_pixels) //
                            return Error.Decode.DataOutOfBounds;
                        switch (pixels) {
                            .rgb => |rgbs| {
                                inline for (comptime std.meta.fieldNames(RGB)) |field_name| {
                                    @memset(rgbs.ptr[j..][0..run], @field(prev_pixel, field_name));
                                }
                            },
                            else => unreachable,
                        }
                        j += run;
                        continue;
                    },
                }
            },
        }
        table[hashRGB(prev_pixel)] = prev_pixel;
        if (j + 1 > n_pixels) return Error.Decode.DataOutOfBounds;
        j += 1;
        try pixels.rgb.replace(i, prev_pixel);
    }
    std.debug.assert(j == n_pixels);
    return pixels;
}

pub fn decodeRGBA(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !Pixels {
    const pixels: Pixels = .{ .rgba = try .initEmpty(gpa, n_pixels) };
    errdefer pixels.deinit(gpa);

    var i: usize = 0; // data position
    var j: usize = 0; // pixels position
    var prev_pixel: RGBA = .{ .r = 0, .b = 0, .g = 0, .a = 0xFF };
    var table = [_]RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0xFF }} ** HASH_TABLE_SIZE;
    while (i < data.len) : (i += 1) {
        const byte = data[i];
        const byte_tag: ByteTags = @enumFromInt(byte);
        switch (byte_tag) {
            .rgb => {
                if (i + @sizeOf(RGB) > data.len) //
                    return Error.Decode.UnexpectedEndOfData;
                inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
                    @field(prev_pixel, field_name) = data[i + k + 1];
                }
                i += @sizeOf(RGB);
            },
            .rgba => {
                if (i + @sizeOf(RGBA) > data.len) //
                    return Error.Decode.UnexpectedEndOfData;
                inline for (comptime std.meta.fieldNames(RGBA), 0..) |field_name, k| {
                    @field(prev_pixel, field_name) = data[i + k + 1];
                }
                i += @sizeOf(RGBA);
            },
            else => {
                const bit_tag: BitTags = @enumFromInt(byte >> 6);
                switch (bit_tag) {
                    .index => prev_pixel = table[byte & 0x3F],
                    .diff => {
                        const drgb: RGB = .{
                            .r = (byte >> 4) & 0x03,
                            .g = (byte >> 2) & 0x03,
                            .b = byte & 0x03,
                        };
                        inline for (comptime std.meta.fieldNames(RGB)) |field_name| {
                            @field(prev_pixel, field_name) = @field(prev_pixel, field_name) +% @field(drgb, field_name) -% 2;
                        }
                    },
                    .luma => {
                        i += 1;
                        if (i > data.len) //
                            return Error.Decode.UnexpectedEndOfData;
                        const byte2 = data[i];

                        const dg = byte & 0x3F;
                        const drdg = byte2 >> 4;
                        const dbdg = byte2 & 0x0F;

                        prev_pixel.g = prev_pixel.g +% dg -% 32;
                        prev_pixel.r = prev_pixel.r +% drdg +% dg -% 8;
                        prev_pixel.b = prev_pixel.b +% dbdg +% dg -% 8;
                    },
                    .run => {
                        const run: usize = (byte & 0x3F) +% 1;
                        if (j + run > n_pixels) //
                            return Error.Decode.DataOutOfBounds;
                        switch (pixels) {
                            .rgb => |rgbs| {
                                inline for (comptime std.meta.fieldNames(RGB)) |field_name| {
                                    @memset(rgbs.ptr[j..][0..run], @field(prev_pixel, field_name));
                                }
                            },
                            else => unreachable,
                        }
                        j += run;
                        continue;
                    },
                }
            },
        }
        table[hashRGBA(prev_pixel)] = prev_pixel;
        if (j + 1 > n_pixels) return Error.Decode.DataOutOfBounds;
        j += 1;
        try pixels.rgba.replace(i, prev_pixel);
    }
    return pixels;
}

pub fn encode(
    gpa: std.mem.Allocator,
    img: *const Image,
    w: *std.Io.Writer,
    maybe_hdr: ?Header,
) !void {
    const hdr: Header = if (maybe_hdr) |hdr| hdr else try .fromImage(img);
    try hdr.encode(w);

    const max_size = img.width * img.height * 5; // overestimate: assumes new RGBA per pixel
    const buf = try gpa.alloc(u8, max_size);
    defer gpa.free(buf);

    const n_bytes_written = switch (img.pixels) {
        .rgb => |rgbs| try encodeRGB(buf, rgbs),
        .rgba => |rgbas| try encodeRGBA(buf, rgbas),
        else => unreachable,
    };
    try w.writeAll(buf[0..n_bytes_written]);
    for (0..END_MARKER.len) |i| try w.writeByte(END_MARKER[i]);
    try w.flush();
}

fn encodeRGB(buf: []u8, rgbs: RGBS) !usize {
    if (@mod(rgbs.len, @sizeOf(RGB)) != 0) return error.InvalidDataLength;
    var table = [_]RGB{.{}} ** HASH_TABLE_SIZE;
    var prev: RGB = .{};
    var px: RGB = .{};
    var run: u8 = 0;
    // idx
    var i: usize = 0; // data idx
    var j: usize = 0; // pixel idx
    while (i < rgbs.len) : (i += 1) {
        px = rgbs.get(i) catch unreachable;
        // simd run
        const matches: u8 = rgbs.first64MatchesAt(i) catch unreachable;
        if (matches > 1) { // 2..64
            run = @max(63, matches) - 1; // 1..62 = 0b0011 1111
            buf[j] = @as(u8, @intFromEnum(BitTags.run)) << 6 | run;
            j += 1;
            i += run;
            run = 0;
            prev = px;
            continue;
        }
        // index
        const idx: u8 = hashRGB(px);
        if (table[idx].eql(px)) {
            buf[j] = (@as(u8, @intFromEnum(BitTags.index)) << 6) | idx;
            j += 1;
            prev = px;
            continue;
        }
        table[idx] = px;
        // diff
        var drgb: RGB = .{
            .r = px.r -% prev.r,
            .g = px.g -% prev.g,
            .b = px.b -% prev.b,
        };
        if ((drgb.r +% 2) <= 3 and (drgb.g +% 2) <= 3 and (drgb.b +% 2) <= 3) {
            buf[j] = @as(u8, @intFromEnum(BitTags.diff)) << 6 | (drgb.r +% 2) << 4 | (drgb.g +% 2) << 2 | (drgb.b +% 2);
            j += 1;
            prev = px;
            continue;
        }
        // luma
        drgb.g +%= 32;
        const dr_dg = drgb.r -% drgb.g +% 8;
        const db_dg = drgb.b -% drgb.g +% 8;
        if (drgb.g < 64 and dr_dg < 16 and db_dg < 16) {
            buf[j] = (@as(u8, @intFromEnum(BitTags.luma)) << 6) | drgb.g;
            buf[j + 1] = (dr_dg << 4) | (db_dg & 0x0F);
            j += 2;
            prev = px;
            continue;
        }
        // rgb
        buf[j] = @intFromEnum(ByteTags.rgb);
        j += 1;
        inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
            buf[j + k] = @field(px, field_name);
        }
        j += comptime std.meta.fieldNames(RGB).len;
        prev = px;
    }
    return j;
}

fn encodeRGBA(buf: []u8, rgbas: RGBAS) !usize {
    if (@mod(rgbas.len, @sizeOf(RGBA)) != 0) return error.InvalidDataLength;
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
    var prev: RGBA = .{};
    var px: RGBA = .{};
    var run: u8 = 0;

    var i: usize = 0;
    var j: usize = 0;
    const len = rgbas.len;
    while (i < len) : (i += 1) {
        px = rgbas.get(i) catch unreachable;
        const matches = rgbas.first64MatchesAt(i) catch unreachable;
        if (matches > 1) {
            run = @min(63, matches) - 1;
            buf[j] = @as(u8, @intFromEnum(BitTags.run)) << 6 | run;
            j += 1;
            i += run;
            run = 0;
            prev = px;
            continue;
        }
        // index
        const idx = hashRGBA(px);
        if (table[idx].eql(px)) {
            buf[j] = @as(u8, @intFromEnum(BitTags.index)) << 6 | idx;
            j += 1;
            prev = px;
            continue;
        }
        table[idx] = px;
        // diff
        var drgb: RGBA = .{
            .r = px.r -% prev.r,
            .g = px.g -% prev.g,
            .b = px.b -% prev.b,
        };
        if (drgb.r +% 2 <= 3 and drgb.g +% 2 <= 3 and drgb.b +% 2 <= 3) {
            buf[j] = (@as(u8, @intFromEnum(BitTags.diff)) << 6) |
                (@as(u8, @intCast(drgb.r +% 2)) << 4) |
                (@as(u8, @intCast(drgb.g +% 2)) << 2) |
                (@as(u8, @intCast(drgb.b +% 2)));
            j += 1;
            prev = px;
            continue;
        }
        // luma
        drgb.g = drgb.g +% 32;
        const dr_dg = drgb.r -% drgb.g +% 8;
        const db_dg = drgb.b -% drgb.g +% 8;
        if (drgb.g < 64 and dr_dg < 16 and db_dg < 16) {
            buf[j] = @as(u8, @intFromEnum(BitTags.luma)) << 6 | drgb.g;
            buf[j + 1] = (dr_dg << 4) | (db_dg & 0x0F);
            j += 2;
            prev = px;
            continue;
        }
        // rgb
        if (px.a == prev.a) {
            buf[j] = @intFromEnum(ByteTags.rgb);
            j += 1;
            inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
                buf[j + k] = @field(px, field_name);
            }
            j += comptime std.meta.fieldNames(RGB).len;
            prev = px;
            continue;
        }
        // rgba
        buf[j] = @intFromEnum(ByteTags.rgba);
        j += 1;
        inline for (comptime std.meta.fieldNames(RGBA), 0..) |field_name, k| {
            buf[j + k] = @field(px, field_name);
        }
        j += comptime std.meta.fieldNames(RGBA).len;
        prev = px;
    }
    return j;
}
