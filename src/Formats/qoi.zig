const std = @import("std");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");
const Image = @import("Image.zig");
const Format = @import("Vulkan").Format;
const isSigSame = @import("Misc.zig").isSigSame;

// TODO:
// - track number of pixels - make sure it matches n_pixels
// - track amount of data left - do not go over

const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 22) return error.InvalidData; // @sizeOf(Header) + @sizeOf(END_MARKER)
    const hdr: Header = try .decode(data[0..14]);
    const n_pixels = hdr.width * hdr.height;
    const pixel_formats: Format = blk: switch (hdr.channels) {
        .rgb => switch (hdr.colorspace) {
            .linear => break :blk .r8g8b8_snorm,
            .srgb => break :blk .r8g8b8_srgb,
        },
        .rgba => switch (hdr.colorspace) {
            .linear => break :blk .r8g8b8a8_snorm,
            .srgb => break :blk .r8g8b8a8_srgb,
        },
    };
    const pixels = try switch (hdr.channels) {
        .rgb => gpa.alloc(RGB, n_pixels),
        .rgba => gpa.alloc(RGBA, n_pixels),
    };
    errdefer gpa.free(pixels);

    var img: Image = .{
        .extent = .{
            .width = hdr.width,
            .height = hdr.height,
            .depth = 1,
        },
        .pixels = pixels,
        .pixels_format = pixel_formats,
    };

    var prev: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var indices = [_]RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0xFF }} ** 64;
    var i: usize = @sizeOf(Header) + Header.SIG.len; // position in data
    var j: usize = 0; // position in pixels

    const len = data.len - 8;
    while (i < len) {
        const b1 = data[i];
        i += 1;
        const byte_tag: ByteTag = @enumFromInt(b1);
        switch (byte_tag) {
            .rgb, .rgba => inline for (@tagName(byte_tag), 0..) |field_name, k| {
                @field(prev, field_name) = data[i + k];
            },
            else => {
                const bit_tag: BitTag = @enumFromInt(b1 >> 6);
                switch (bit_tag) {
                    .index => {
                        const idx: u6 = @truncate(b1);
                        prev = indices[idx];
                    },
                    .diff => {
                        prev.r = prev.r +% (b1 >> 4 & 0x03) -% 2;
                        prev.g = prev.g +% (b1 >> 2 & 0x03) -% 2;
                        prev.b = prev.b +% (b1 & 0x03) -% 2;
                    },
                    .luma => {
                        const b2 = data[i];
                        i += 1;
                        const dg = @as(i8, @intCast(b1 & 0x3F)) -% 32;
                        const dr_dg = @as(i8, @intCast(b2 >> 4)) -% 8;
                        const db_dg = @as(i8, @intCast(b2 & 0x0F)) -% 8;
                        const dr = dr_dg +% dg;
                        const db = db_dg +% dg;
                        prev.r = @bitCast(@as(i8, @bitCast(prev.r)) +% dr);
                        prev.g = @bitCast(@as(i8, @bitCast(prev.g)) +% dg);
                        prev.b = @bitCast(@as(i8, @bitCast(prev.b)) +% db);
                    },
                    .run => {
                        const run: u8 = (b1 & 0x3F) + 1;
                        std.debug.assert(j + run < n_pixels);
                        switch (img.pixels) {
                            .rgb => |px| @memset(px[j .. j + run], .{
                                .r = prev.r,
                                .g = prev.g,
                                .b = prev.b,
                            }),
                            .rgba => |px| @memset(px[j .. j + run], prev),
                        }
                        j += run;
                        continue; // skip updates to prev + indices
                    },
                }
            },
        }
        // updates
        indices[hash(prev)] = prev;
        switch (img.pixels) {
            .rgb => |px| px[j] = .{ .r = prev.r, .g = prev.g, .b = prev.b },
            .rgba => |px| px[j] = prev,
        }
        j += 1;
    }
    return img;
}

pub fn encode(img: *const Image, w: *std.Io.Writer) !void {
    const hdr: Header = .fromImage(img);
    std.debug.print("Header:\n{any}\n", .{hdr});
    try hdr.encode(w);

    const n_pixels, const overflow = @mulWithOverflow(hdr.width, hdr.height);
    if (@as(bool, overflow)) return error.InvalidDimensions;

    var prev: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var indices = [_]RGBA{prev} ** 64;

    switch (img.pixels) {
        .rgb => |pixels| {
            var i: usize = 0;
            while (i < n_pixels) : (i += 1) {
                // run
                var pix_64: @Vector(64, RGB) = @bitCast(pixels[i..][0..64].*);
                const prev_64: @Vector(64, RGB) = @splat(prev);
                var n_matches: u64 = @clz(pix_64 != prev_64);
                while (n_matches > 1) {
                    const run: u8 = @as(u8, @intFromEnum(BitTag.run)) << 6 | @as(u8, @intCast(n_matches - 1));
                    try w.writeInt(u8, run, .little);
                    i += n_matches;
                    pix_64 = @bitCast(pixels[i..][0..64].*);
                    n_matches = @clz(pix_64 != prev_64);
                }

                // index
                const px = pixels[i];
                const idx = hash(px);
                if (indices[idx].eql(px)) {
                    const index = @as(u8, @intFromEnum(BitTag.index)) << 6 | @as(u8, idx);
                    try w.writeInt(u8, index, .little);
                    i += 1;
                    prev = px;
                    continue;
                }

                // hash pixel + store
                indices[idx] = px;

                const dr = px.r - prev.r;
                const dg = px.g - prev.g;
                const db = px.b - prev.b;

                const dr_dg = dr - dg;
                const db_dg = db - db;

                if (dr >= -2 and dr <= 1 and //
                    dg >= -2 and dg <= 1 and //
                    db >= -2 and db <= 1)
                {
                    const diff = @as(u8, @intFromEnum(BitTag.diff)) << 6 |
                        @as(u8, @intCast(dr + 2)) << 4 |
                        @as(u8, @intCast(dg + 2)) << 2 |
                        @as(u8, @intCast(db + 2));
                    try w.writeInt(u8, diff, .little);
                    i += 1;
                } else if (dg >= -32 and dg <= 31 and
                    dr_dg >= -8 and dr_dg <= 7 and
                    db_dg >= -8 and db_dg <= 7)
                {
                    const luma1 = @as(u8, @intFromEnum(BitTag.luma)) << 6 | @as(u8, @intCast(dg + 32));
                    const luma2 = @as(u8, @intCast(dr_dg + 8)) << 4 | @as(u8, @intCast(db_dg + 8));
                    try w.writeInt(u8, luma1, .little);
                    try w.writeInt(u8, luma2, .little);
                    i += 2;
                } else {
                    // RGB
                    try w.writeInt(u8, @intFromEnum(ByteTag.rgb), .little);
                    try w.writeInt(u8, px.r, .little);
                    try w.writeInt(u8, px.g, .little);
                    try w.writeInt(u8, px.b, .little);
                    i += 4;
                }
                prev = px;
            }
            @memcpy(pixels[i .. i + END_MARKER.len], &END_MARKER);
            i += 8;
            std.debug.assert(i == n_pixels + 8);
        },
        else => unreachable,
    }
}

const ByteTag = enum(u8) {
    rgb = 0xFE,
    rgba = 0xFF,
    _,
};

const BitTag = enum(u2) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

fn hash(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Header = struct {
    pub const SIG = "qoif";
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: Colorspace,

    pub fn fromImage(img: *const Image) !@This() {
        var channels: Channels = undefined;
        var colorspace: Colorspace = undefined;
        switch (img.pixel_format) {
            .r8g8b8_srgb => {
                channels = .rgb;
                colorspace = .srgb;
            },
            .r8g8b8a8_srgb => {
                channels = .rgba;
                colorspace = .linear;
            },
            else => return error.UnsupportedFormat,
        }
        return .{
            .width = img.width,
            .height = img.height,
            .channels = channels,
            .colorspace = colorspace,
        };
    }

    pub fn decode(data: []const u8) !@This() {
        try isSigSame(data[0..4], SIG);
        const width = std.mem.readInt(u32, data[4..][0..4], .big);
        const height = std.mem.readInt(u32, data[8..][0..4], .big);
        if (width == 0 or height == 0) return error.InvalidDimensions;
        _, const overflow: u1 = @mulWithOverflow(width, height);
        if (@as(bool, overflow)) return error.InvalidDimensions;
        const channels = std.enums.fromInt(Channels, data[12]) orelse
            return error.InvalidChannel;
        const colorspace = std.enums.fromInt(Colorspace, data[13]) orelse
            return error.InvalidColorspace;
        return .{
            .width = width,
            .height = height,
            .channels = channels,
            .colorspace = colorspace,
        };
    }

    pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
        try w.writeAll("qoif");
        try w.writeInt(u32, self.width, .big);
        try w.writeInt(u32, self.height, .big);
        try w.writeInt(u8, @intFromEnum(self.channels), .little);
        try w.writeInt(u8, @intFromEnum(self.colorspace), .little);
    }
};
