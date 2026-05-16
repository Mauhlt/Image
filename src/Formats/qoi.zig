const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("error.zig");
const Image = @import("img.zig");
const RGBA = @import("color.zig").RGBA;
const Pixels = @import("color.zig").Pixels;
const isSigSame = @import("Misc.zig").isSigSame;

// TODO:
// - track number of pixels - make sure it matches n_pixels
// - track amount of data left - do not go over

const SIG = "QOIF";
const HASH_TABLE_SIZE = 64;
const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

fn hash(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void {
    const hdr: Header = try .decode(data);
    std.debug.print("{f}", .{hdr});
    // check end bytes
    std.debug.assert(std.mem.eql(u8, data[data.len - 8 ..], [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }));

    const pixels_slice = data[14 .. pixels_slice.len - 8];
    if (!std.mem.eql(u8, pixels_slice[pixels_slice.len - 8 ..], &END_MARKER))
        return Error.Decode.InvalidEndMarker;
    const n_pixels = hdr.width * hdr.height;
    const pixels: Pixels = switch (hdr.channels) {
        .rgb => .{ .rgb = try .initCapacity(gpa, n_pixels) },
        .rgba => .{ .rgba = try .initCapacity(gpa, n_pixels) },
    };
    // const pixels = blk: {
    //     var pixels: Pixels = undefined;
    //     switch (hdr.channel) {
    //         .rgb => {
    //             pixels = .{ .rgb = try .initCapacity(gpa, n_pixels) };
    //             break :blk pixels;
    //         },
    //         .rgba => {
    //             pixels = .{ .rgba = try .initCapacity(gpa, n_pixels) };
    //             break :blk pixels;
    //         },
    //     }
    //     break :blk pixels;
    // };
    defer pixels.deinit(gpa);

    var i: usize = 0; // input position
    var j: usize = 0; // output position
    var prev_pixel: RGBA = .{ .r = 0, .b = 0, .g = 0, .a = 0xFF };
    var indices = [_]RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0xFF }} ** HASH_TABLE_SIZE;
    while (i < pixels_slice.len) : (i += 1) {
        const byte = pixels_slice[i];
        switch (byte) {
            0xFE => { // RGB
                if (i + 3 > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                prev_pixel = .{
                    .r = pixels_slice[i + 1],
                    .g = pixels_slice[i + 2],
                    .b = pixels_slice[i + 3],
                };
                i += 3;
            },
            0xFF => { // RGBA
                if (i + 4 > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                prev_pixel = .{
                    .r = pixels_slice[i + 1],
                    .g = pixels_slice[i + 2],
                    .b = pixels_slice[i + 3],
                    .a = pixels_slice[i + 4],
                };
                i += 4;
            },
            else => {
                const byte2 = pixels_slice[i];
                const bits: BitTags = @enumFromInt(byte2 >> 6);
                switch (bits) {
                    .index => {
                        const idx: u6 = @truncate(byte2);
                        prev_pixel = indices[idx];
                    },
                    .diff => {
                        std.debug.print("Diff\n", .{});
                        const dr = (byte2 >> 4) & 0x03;
                        const dg = (byte2 >> 2) & 0x03;
                        const db = byte2 & 0x03;
                        const dr2 = @as(i8, @intCast((byte2 >> 4) & 0x03)) - 2;
                        const dg2 = @as(i8, @intCast((byte2 >> 2) & 0x03)) - 2;
                        const db2 = @as(i8, @intCast((byte2) & 0x03)) - 2;
                        std.debug.print("Dpixel 1: {} {} {}\n", .{ dr, dg, db });
                        std.debug.print("Dpixel 2: {} {} {}\n", .{ dr2, dg2, db2 });
                        const pr = prev_pixel.r +% @as(u8, @bitCast(dr2));
                        const pg = prev_pixel.g +% @as(u8, @bitCast(dg2));
                        const pb = prev_pixel.b +% @as(u8, @bitCast(db2));
                        prev_pixel.r = prev_pixel.r +% dr -% 2;
                        prev_pixel.g = prev_pixel.g +% dg -% 2;
                        prev_pixel.b = prev_pixel.b +% db -% 2;
                        std.debug.print("Prev Pixel 1: {} {} {}\n", .{ prev_pixel.r, prev_pixel.g, prev_pixel.b });
                        std.debug.print("Prev Pixel 2: {} {} {}\n", .{ pr, pg, pb });
                    },
                    .luma => {
                        std.debug.print("Luma\n", .{});
                        i += 1;
                        if (i > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                        const byte3 = pixels_slice[i];
                        const dg = byte3 & 0x3F; // -32:31
                        const drdg = byte3 >> 4; // -8:7
                        const dbdg = byte3 & 0x3F; // -8:7
                        const dg2 = @as(i8, @intCast((byte3 & 0x3F))) - 32;
                        const drdg2 = @as(i8, @intCast((byte3 >> 4) & 0x0F)) - 8;
                        const dbdg2 = @as(i8, @intCast(byte3 & 0x0F)) - 8;
                        std.debug.print("Dpixel 1: {} {} {}\n", .{ dg, drdg, dbdg });
                        std.debug.print("Dpixel 1: {} {} {}\n", .{ dg2, drdg2, dbdg2 });
                        const pr = prev_pixel.g +% @as(u8, @bitCast(dg2));
                        const pg = prev_pixel.r +% @as(u8, @bitCast(dg2 +% drdg2));
                        const pb = prev_pixel.b +% @as(u8, @bitCast(dg2 +% dbdg2));
                        prev_pixel.g = prev_pixel.g +% dg -% 32;
                        prev_pixel.r = prev_pixel.r +% drdg +% dg -% 8;
                        prev_pixel.b = prev_pixel.b +% dbdg +% dg -% 8;
                        std.debug.print("Prev Pixel 1: {} {} {}\n", .{ prev_pixel.r, prev_pixel.g, prev_pixel.b });
                        std.debug.print("Prev Pixel 2: {} {} {}\n", .{ pr, pg, pb });
                    },
                    .run => {
                        const run: usize = (byte & 0x3F) + 1;
                        if (j + run > n_pixels) return Error.Decode.DataOutOfBounds;
                        switch (pixels) {
                            .rgb => |rgb| {
                                const slice = rgb.slice();
                                const r = slice.ptrs[0];
                                const g = slice.ptrs[1];
                                const b = slice.ptrs[2];
                                @memset(r[j..][0..run], prev_pixel.r);
                                @memset(g[j..][0..run], prev_pixel.g);
                                @memset(b[j..][0..run], prev_pixel.b);
                            },
                            .rgba => |rgba| {
                                const slice = rgba.slice();
                                const r = slice.ptrs[0];
                                const g = slice.ptrs[1];
                                const b = slice.ptrs[2];
                                const a = slice.ptrs[3];
                                @memset(r[j..][0..run], prev_pixel.r);
                                @memset(g[j..][0..run], prev_pixel.g);
                                @memset(b[j..][0..run], prev_pixel.b);
                                @memset(a[j..][0..run], prev_pixel.a);
                            },
                            else => unreachable,
                        }
                        j += run;
                        continue;
                    },
                }
            },
        }

        indices[hash(prev_pixel)] = prev_pixel;

        if (j + 1 > n_pixels) return Error.Decode.DataOutOfBounds;
        j += 1;

        switch (pixels) {
            .rgb => |rgb| rgb.appendAssumeCapacity(.{
                .r = prev_pixel.r,
                .g = prev_pixel.g,
                .b = prev_pixel.b,
            }),
            .rgba => |rgba| rgba.appendAssumeCapacity(prev_pixel),
            else => unreachable,
        }
    }

    // verify end marker
    if (i != pixels_slice.len - 8) return Error.Decode.InvalidEndMarker;
}

const BitTags = enum(u8) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

pub fn encode(img: *const Image, w: *std.Io.Writer, maybe_hdr: ?Header) !void {
    const hdr: Header = if (maybe_hdr) |hdr| hdr else try .fromImage(img);
    try hdr.encode(w);
    var prev_pixel: RGBA = .{};
    // we want run - luma - index - so on
    switch (img.pixels) {
        .gray => {},
        .rgb => |rgb| {
            const len = rgb.len;
            for (0..len) |i| {
                try w.writeInt(rgb.get(i));
            }
        },
        .rgba => |rgba| {
            const len = rgba.len;
            for (0..len) |i| {
                try w.writeInt(rgba.get(i)); // TODO: NOT CORRECT, FIX
            }
        },
    }
}

const Header = struct {
    width: u32,
    height: u32,
    channel: Channel,
    colorspace: Colorspace,

    pub fn fromImage() @This() {}

    pub fn decode(data: []const u8) !@This() {
        std.debug.assert(data.len > 14);
        var i: usize = 0;
        try isSigSame(SIG, data[i..][0..SIG.LEN]);
        i += SIG.LEN;
        const width = std.mem.readInt(u32, data[i..][0..4], .big);
        i += 4;
        const height = std.mem.readInt(u32, data[i..][0..4], .big);
        _, const overflow: u1 = @mulWithOverflow(width, height);
        if (overflow > 0) return error.InvalidDimensions;
        const channel = std.enums.fromInt(Channel, data[i]) orelse
            return error.InvalidChannelValue;
        i += 1;
        const colorspace = std.enums.fromInt(Colorspace, data[i]) orelse
            return error.InvalidColorspaceValue;
        return .{
            .width = width,
            .height = height,
            .channel = channel,
            .colorpace = colorspace,
        };
    }

    pub fn encode() void {}

    pub fn format(self: @This(), w: *std.Io.Writer) void {
        try w.print("Width: {}\n", .{self.width});
        try w.print("Height: {}\n", .{self.height});
        try w.print("Colorspace: {t}\n", .{self.colorspace});
        try w.print("Channels: {t}\n", .{self.channel});
    }
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};
