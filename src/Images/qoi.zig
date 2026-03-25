const std = @import("std");
const Image = @import("img.zig");
const RGB = @import("Color.zig").RGB;
const RGBA = @import("Color.zig").RGBA;

const HEADER_SIZE = 14;
const END_SIZE = 8;
const SIGNATURE = "qoif";
const END_SIGNATURE = [8]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < HEADER_SIZE + END_SIZE)
        return error.IncorrectHeader;
    if (!std.mem.eql(u8, data[0..HEADER_SIZE], SIGNATURE))
        return error.IncorrectSignature;

    const width = std.mem.readInt(u32, data[4..][0..4], .big);
    const height = std.mem.readInt(u32, data[8..][0..4], .big);
    const n_pixels, const overflow = @mulWithOverflow(width, height);
    if (overflow == 1) return error.InvalidDimensions;
    // const channel = std.enums.fromInt(Channels, data[12]) orelse
    //     return error.UnsupportedChannel;
    // const colorspace = std.enums.fromInt(Colorspace, data[13]) orelse
    //     return error.UnsupportedColorspace;

    const pixels = try gpa.alloc(u8, n_pixels);
    errdefer gpa.free(pixels);

    var prev_px: RGBA = .{};
    var px_indices = [_]RGBA{.{}} ** 64;

    const len = data.len - HEADER_SIZE - END_SIZE;
    var i: usize = HEADER_SIZE; // position in data
    var j: usize = 0; // position in pixels
    while (i < len) : (i += 1) {
        const symbol = data[i];
        const byte_symbol: ByteSymbols = @enumFromInt(symbol);
        switch (byte_symbol) {
            .rgb => {
                prev_px.r = data[i + 1];
                prev_px.g = data[i + 2];
                prev_px.b = data[i + 3];
            },
            .rgba => {
                prev_px.r = data[i + 1];
                prev_px.g = data[i + 2];
                prev_px.b = data[i + 3];
                prev_px.a = data[i + 4];
            },
            else => {
                const rem: u8 = symbol & 0x3F;
                const bit_symbol: BitSymbols = @enumFromInt((symbol >> 6) & 0x03);
                switch (bit_symbol) {
                    .index => prev_px = px_indices[rem],
                    .diff => {
                        const dr: u8 = (rem >> 4) & 0x03;
                        const dg: u8 = (rem >> 2) & 0x03;
                        const db: u8 = rem & 0x03;
                        prev_px.r = prev_px.r +% dr -% 2;
                        prev_px.g = prev_px.g +% dg -% 2;
                        prev_px.b = prev_px.b +% db -% 2;
                    },
                    .luma => {
                        const dg = rem; // +32 bias
                        const drdg = ((data[i + 1] >> 4) & 0x07); // +8 bias
                        const dbdg = (data[i + 1] & 0x07); // +8 bias
                        prev_px.r = prev_px.r +% drdg +% dg -% 40;
                        prev_px.g = prev_px.g +% dg -% 32;
                        prev_px.b = prev_px.b +% dbdg +% dg -% 40;
                    },
                    .run => { // rem = run length = best b/c it knocks out many
                        const run = rem;
                        std.debug.assert(j + run < pixels.len);
                        @memset(pixels[j..][0..run], prev_px);
                        j += run;
                        continue;
                    },
                }
            },
        }
        pixels[j] = prev_px;
        j += 1;
    }
    return Image{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

pub fn encode(w: *std.Io.Writer, img: *const Image) !void {
    try w.writeAll(SIGNATURE);
    try w.writeInt(u32, img.width, .big);
    try w.writeInt(u32, img.height, .big);
    try w.writeByte(@intFromEnum(Channels.rgba));
    try w.writeByte(@intFromEnum(Colorspace.srgb));

    const prev_px: RGBA = .{};
    const px_indices = [_]RGBA{.{}} ** 64;

    var i: usize = 0;
    while (i < img.pixels) : (i += 1) {
        // in terms of priority
        // run -> luma -> diff -> index -> rgb -> rgba
        const curr: u32 = @bitCast(img.pixels[i..][0..4]);
        const potential_matches: [64]u32 = @bitCast(img.pixels[i..][0..64].*);
        const matches: u64 = @as(@Vector(64, u32), potential_matches) == @as(@Vector(64, u32), @splat(curr));
        const n_matches = @clz(matches);
        if (n_matches > 1) {
            const n_allowed_matches: u8 = @min(62, n_matches);
            const byte = (@as(u8, 3) << 6) + n_allowed_matches;
            prev_px.r = img.pixels[i];
            prev_px.g = img.pixels[i + 1];
            prev_px.b = img.pixels[i + 2];
            prev_px.a = img.pixels[i + 3];
            try w.writeInt(u8, byte, .little);
        }

        if 
    }

    try w.writeAll(&END_SIGNATURE);
}

const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const ByteSymbols = enum(u8) {
    rgba = 0xFF,
    rgb = 0xFE,
    _,
};

const BitSymbols = enum(u8) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

fn hash(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}
