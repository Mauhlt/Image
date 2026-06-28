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

pub fn hashRGBA(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

pub fn hashRGB(c: RGB) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    const hdr: Header = try .decode(data);
    const pixels_slice = data[14 .. data.len - 8];
    if (!std.mem.eql(u8, pixels_slice[pixels_slice.len - END_MARKER.len ..], &END_MARKER))
        return Error.Decode.InvalidEndMarker;
    const fmt: @TypeOf(@FieldType(Image, "fmt")) = switch (hdr.channel) {
        .rgb => .r8g8b8_srgb,
        .rgba => .r8g8b8a8_srgb,
    };
    const n_pixels = hdr.width * hdr.height;
    const pixels: Pixels = switch (hdr.channel) {
        .rgb => try decodeRGB(gpa, n_pixels, data),
        .rgba => try decodeRGBA(gpa, n_pixels, data),
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
    const pixels = .{ .rgb = try .initEmpty(gpa, n_pixels) };
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
        // table
        table[hashRGB(prev_pixel)] = prev_pixel;

        if (j + 1 > n_pixels) return Error.Decode.DataOutOfBounds;
        j += 1;

        try pixels.rgbs.replace(i, prev_pixel);
    }

    return pixels;
}

pub fn decodeRGBA(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !Pixels {
    const pixels = .{ .rgba = try .initEmpty(gpa, n_pixels) };
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

        try pixels.rgbas.replace(i, prev_pixel);
    }

    return pixels;
}

pub fn encode(
    gpa: std.mem.Allocator,
    img: *const Image,
    w: *std.Io.Writer,
    maybe_hdr: ?Header,
) !void {
    const n_pixels = switch (img.pixels) {
        inline else => |colors| colors.len,
    };

    // over-allocate memory
    const max_size = @sizeOf(Header) + n_pixels * 5 + END_MARKER.len;
    var buf = try gpa.alloc(u8, max_size);
    defer gpa.free(buf);

    const hdr: Header = if (maybe_hdr) |hdr| hdr else try .fromImage(img);
    try hdr.encode(w);

    switch (img.pixels) {
        .rgb => |rgbs| try encodeRGB(&buf, rgbs),
        .rgba => |rgbas| try encodeRGBA(&buf, rgbas),
        else => unreachable,
    }

    try w.writeAll(&END_MARKER);
}

fn encodeRGB(buf: []u8, data: []const RGB) !void {
    if (@mod(data.len, @sizeOf(RGB)) != 0) return error.InvalidDataLength;
    const n_pixels = data.len / @sizeOf(RGB);
    var table = [_]RGB{.{}} ** HASH_TABLE_SIZE;
    var prev: RGB = .{};
    var px: RGB = .{};
    var run: u8 = 0;

    var i: usize = 0; // data idx
    var j: usize = 0; // pixel idx
    while (i < data.len) : (i += 1) {
        // fill px
        inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
            @field(px, field_name) = data[i + k];
        }
        // run
        if (px.eql(prev)) {
            run += 1;
            if (run == 62 or j == n_pixels - 1) {
                buf[j] = @intFromEnum(BitTags.run) | run - 1;
                j += 1;
                run = 0;
            }
            prev = px;
            continue;
        }
        // flush
        if (run > 0) {
            buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | @as(u8, @intCast(run - 1));
        }
        // index
        const idx = hashRGB(px);
        if (table[idx].eql(px)) {
            buf[j] = @as(u8, @intFromEnum(BitTags.index) << 6) | @as(u8, idx);
            j += 1;
            table[idx] = px;
            prev = px;
            continue;
        }
        table[idx] = px;

        const dr = px.r -% prev.r;
        const dg = px.g -% prev.g;
        const db = px.b -% prev.b;
        if (dr +% 2 <= 3 and dg +% 2 <= 3 and db +% 2 <= 3) { // diff
            buf[j] = @as(u8, @intFromEnum(BitTags.diff) << 6) |
                @as(u8, @intCast(dr +% 2)) << 4 |
                @as(u8, @intCast(dg +% 2)) << 2 |
                @as(u8, @intCast(db +% 2));
            j += 1;
            continue;
        }
        const dr_dg = dr -% dg;
        const db_dg = db -% dg;
        if (dg +% 32 <= 64 and dr_dg +% 8 <= 16 and db_dg +% 8 <= 16) { // luma
            buf[j] = (@intFromEnum(BitTags.luma) << 6) | dg + 32;
            buf[j + 1] = dr_dg << 4 | db_dg +% 8;
            continue;
        }
        buf[j] = @intFromEnum(ByteTags.rgb);
        inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
            buf[j + k + 1] = @field(px, field_name);
        }
        j += comptime std.meta.fieldNames(RGB).len;
    }
}

fn encodeRGBA(buf: []u8, data: []const RGBA) !void {
    if (@mod(data.len, @sizeOf(RGBA)) != 0) return error.InvalidDataLength;
    const n_pixels = data.len / @sizeOf(RGBA);
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
    var prev: RGBA = .{};
    var px: RGBA = .{};
    var run: u8 = 0;

    var i: usize = 0;
    var j: usize = 0;
    while (i < data.len) : (i += 1) {
        // fill px
        inline for (comptime std.meta.fieldNames(RGBA), 0..) |field_name, k| {
            @field(px, field_name) = data[i + k];
        }
        // run
        if (px.eql(prev)) {
            run += 1;
            if (run == 62 or j == n_pixels - 1) {
                buf[j] = @intFromEnum(BitTags.run) | run - 1;
                j += 1;
                run = 0;
            }
            prev = px;
            continue;
        }
        // flush
        if (run > 0) {
            buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | @as(u8, @intCast(run - 1));
        }
        // index
        const idx = hashRGB(px);
        if (table[idx].eql(px)) {
            buf[j] = @as(u8, @intFromEnum(BitTags.index) << 6) | @as(u8, idx);
            j += 1;
            table[idx] = px;
            prev = px;
            continue;
        }
        table[idx] = px;

        const dr = px.r -% prev.r;
        const dg = px.g -% prev.g;
        const db = px.b -% prev.b;
        if (dr +% 2 <= 3 and dg +% 2 <= 3 and db +% 2 <= 3) { // diff
            buf[j] = @as(u8, @intFromEnum(BitTags.diff) << 6) |
                @as(u8, @intCast(dr +% 2) << 4) |
                @as(u8, @intCast(dg +% 2) << 2) |
                @as(u8, @intCast(db +% 2));
            j += 1;
            continue;
        }
        const dr_dg = dr -% dg;
        const db_dg = db -% dg;
        if (dg +% 32 <= 64 and dr_dg +% 8 <= 16 and db_dg +% 8 <= 16) { // luma
            buf[j] = (@intFromEnum(BitTags.luma) << 6) | dg + 32;
            buf[j + 1] = dr_dg << 4 | db_dg +% 8;
            continue;
        }
        buf[j] = @intFromEnum(ByteTags.rgb);
        inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
            buf[j + k + 1] = @field(px, field_name);
        }
        j += comptime std.meta.fieldNames(RGB).len;
    }
}

// fn encodeDataSIMD(
//     comptime T: Channel,
//     buf: []u8,
//     data: switch (T) {
//         .rgb => []const RGB,
//         .rgba => []const RGBA,
//     },
// ) !void {
//     var table = [_]RGBA{.{}} ** 64;
//     var prev: switch (T) {
//         .rgb => RGB,
//         .rgba => RGBA,
//     } = .{};
//     var run: usize = 0;
//
//     const n_pixels = data.len;
//     var i: usize = 0; // index into data
//     var j: usize = 0; // index into buffer
//     while (true) {
//         const n_matches = if (i + 64 <= n_pixels) //
//             countStartingMatchesSIMD(T, data[i], @ptrCast(data[i..][0..64]))
//         else //
//             countStartingMatches(T, data[i], data[i..]);
//         if (n_matches > 0) {
//             buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | run;
//         }
//         const px = data[i];
//         // check run
//         if (px.eql(prev)) {
//             run += 1;
//             if (run == 62 or i == n_pixels - 1) {
//                 buf[j] = @intFromEnum(BitTags.run) << 6 | @as(u8, @intCast(run - 1));
//                 j += 1;
//                 run = 0;
//             }
//             prev = px;
//             continue;
//         }
//
//         // flush run
//         if (run > 0) {
//             buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | @as(u8, @intCast(run - 1));
//             j += 1;
//             run = 0;
//         }
//
//         // index
//         const idx = hash(px);
//         if (table[idx].eql(px)) {
//             buf[j] = @as(u8, @intFromEnum(BitTags.index) << 6) | @as(u8, idx);
//             j += 1;
//             table[idx] = px;
//             prev = px;
//             continue;
//         }
//         table[idx] = px;
//
//         switch (T) {
//             .rgb => {
//                 const dr = @as(i8, px.r) - prev.r;
//                 const dg = @as(i8, px.g) - prev.g;
//                 const db = @as(i8, px.b) - prev.b;
//                 const dr_dg = dr - dg;
//                 const db_dg = db - dg;
//                 if (dr >= -2 and dr <= 1 and //
//                     dg >= -2 and dg <= 1 and //
//                     db >= -2 and db <= 1)
//                 {
//                     // diff
//                     buf[j] = calcDiff(.{ .r = dr, .g = dg, .b = db });
//                 } else if { // luma
//                     buf[j] = @intFromEnum(ByteTags.rgb);
//                 } else { // run
//
//                 }
//             },
//             .rgba => {
//                 if (px.a == prev.a) {
//                     const drgb: RGB = .{
//                         .r = px.r -% prev.r,
//                         .g = px.g -% prev.g,
//                         .b = px.b -% prev.b,
//                     };
//                     const drgb_dg: RGB = .{
//                         .r = drgb.r - drgb.g,
//                         .g = drgb.g,
//                         .b = drgb.b - drgb.g,
//                     };
//                     if (drgb.r >= -2 and drgb <= 1 and //
//                         dg >= -2 and dg <= 1 and //
//                         db >= -2 and db <= 1)
//                     {
//                         // diff
//                         buf[j] = calcDiff(.{ .r = @intCast(dr), .g = @intCast(dg), .b = @intCast(db) });
//                         j += 1;
//                     } else if (dg >= -32 and dg <= 31 and
//                         dr_dg >= -8 and dr_dg <= 7 and
//                         db_dg >= -8 and db_dg <= 7)
//                     {
//                         // luma
//                         buf[j] = (@intFromEnum(BitTags.luma) << 6) | (@as(u8, @intCast(dg)) + 32);
//                         buf[j + 1] = (@as(u8, @intCast(dr_dg + 8)) << 4) | (@as(u8, @intCast(db_dg)) + 8);
//                     } else {
//                         // rgb
//                         buf[j] = @intFromEnum(ByteTags.rgb);
//                         buf[j + 1] = px.r;
//                         buf[j + 2] = px.g;
//                         buf[j + 3] = px.b;
//                         j += 4;
//                     }
//                 } else {
//                     // RGBA
//                     buf[j] = @intFromEnum(ByteTags.rgba);
//                     buf[j + 1] = px.r;
//                     buf[j + 2] = px.g;
//                     buf[j + 3] = px.b;
//                     buf[j + 4] = px.a;
//                     j += 5;
//                 }
//                 prev = px;
//             },
//         }
//     }
// }
//
// fn calcDiff(rgb: RGB) RGB {
//     return @as(u8, @intFromEnum(BitTags.diff) << 6) |
//         (rgb.r + 2) << 4 |
//         (rgb.g + 2) << 2 |
//         (rgb.b + 2);
// }
// //
// // fn calcLuma() void {}
//
// fn countStartingMatches(
//     comptime T: Channel,
//     needle: switch (T) {
//         .rgb => RGB,
//         .rgba => RGBA,
//     },
//     haystack: switch (T) {
//         .rgb => RGB,
//         .rgba => RGBA,
//     },
// ) usize {
//     for (haystack, 0..) |s, i| {
//         if (!needle.eql(s)) return i;
//     } else return haystack.len;
// }
//
// fn countStartingMatchesSIMD(
//     comptime T: Channel,
//     needle: switch (T) {
//         .rgb => RGB,
//         .rgba => RGBA,
//     },
//     haystack: switch (T) {
//         .rgb => RGB,
//         .rgba => RGBA,
//     },
// ) u64 {
//     const V = @Vector(64, u8);
//     const field_names = comptime std.meta.fieldNames(@TypeOf(needle));
//     const len = field_names.len;
//     var n_vecs: [len]V = undefined;
//     var h_vecs: [len]V = undefined;
//     var matches: u64 = 0;
//     for (0..len) |i| {
//         n_vecs[i] = @splat(@field(needle, field_names[i]));
//         h_vecs[i] = @bitCast(@field(haystack, field_names[i]).*);
//         matches |= @bitCast(n_vecs[i] != h_vecs[i]);
//     }
//     return @ctz(matches);
// }
//
// test "Count Starting Matches" {
//     const allo = std.testing.allocator;
//
//     {
//         const rgb: RGB = .{};
//         var rgbs64: std.MultiArrayList(RGB) = try .initCapacity(allo, 64);
//         defer rgbs64.deinit(allo);
//         for (0..64) |_| {
//             rgbs64.appendAssumeCapacity(.{});
//         }
//         const slice = rgbs64.slice();
//         const n_matches64_1 = countStartingMatches(
//             .rgb,
//             rgb,
//             .{ .r = slice.ptrs[0], .g = slice.ptrs[1], .b = slice.ptrs[2] },
//         );
//         const n_matches64_2 = countStartingMatchesSIMD(
//             .rgb,
//             rgb,
//             .{ .r = slice.ptrs[0], .g = slice.ptrs[1], .b = slice.ptrs[2] },
//         );
//         try std.testing.expectEqual(n_matches64_1, 64);
//         try std.testing.expectEqual(n_matches64_2, 64);
//     }
//
//     {
//         const rgb: RGB = .{};
//         var rgbs7: std.MultiArrayList(RGB) = try .initCapacity(allo, 64);
//         defer rgbs7.deinit(allo);
//         for (0..7) |_| rgbs7.appendAssumeCapacity(.{});
//         rgbs7.appendAssumeCapacity(.{ .r = 1, .g = 1, .b = 1 });
//         for (8..64) |_| rgbs7.appendAssumeCapacity(.{});
//
//         const n_matches7_1 = countStartingMatches(.rgb, rgb, &rgbs7);
//         const n_matches7_2 = countStartingMatchesSIMD(.rgb, rgb, &rgbs7);
//         try std.testing.expectEqual(n_matches7_1, 7);
//         try std.testing.expectEqual(n_matches7_2, 7);
//     }
// }
//
// test "Basic Fns Work How I Expect" {
//     if (px.a == prev.a) {
//         const drgb: RGB = .{
//             .r = px.r -% prev.r,
//             .g = px.g -% prev.g,
//             .b = px.b -% prev.b,
//         };
//         const drgb_dg: RGB = .{
//             .r = drgb.r - drgb.g,
//             .g = drgb.g,
//             .b = drgb.b - drgb.g,
//         };
//         if (drgb.r >= -2 and drgb <= 1 and //
//             dg >= -2 and dg <= 1 and //
//             db >= -2 and db <= 1)
//         {
//             // diff
//             buf[j] = calcDiff(.{ .r = @intCast(dr), .g = @intCast(dg), .b = @intCast(db) });
//             j += 1;
//         } else if (dg >= -32 and dg <= 31 and
//             dr_dg >= -8 and dr_dg <= 7 and
//             db_dg >= -8 and db_dg <= 7)
//         {
//             // luma
//             buf[j] = (@intFromEnum(BitTags.luma) << 6) | (@as(u8, @intCast(dg)) + 32);
//             buf[j + 1] = (@as(u8, @intCast(dr_dg + 8)) << 4) | (@as(u8, @intCast(db_dg)) + 8);
//         } else {
//             // rgb
//             buf[j] = @intFromEnum(ByteTags.rgb);
//             buf[j + 1] = px.r;
//             buf[j + 2] = px.g;
//             buf[j + 3] = px.b;
//             j += 4;
//         }
//     } else {
//         // RGBA
//         buf[j] = @intFromEnum(ByteTags.rgba);
//         buf[j + 1] = px.r;
//         buf[j + 2] = px.g;
//         buf[j + 3] = px.b;
//         buf[j + 4] = px.a;
//         j += 5;
//     }
//     prev = px;
// }
//
