//! Test oracle: the original op-at-a-time QOI decoders, every op bounds-checked.
//! qoi.zig's `decodeOps` must give the same pixels and the same errors.
const Error = @import("../error.zig").Error;
const qoi = @import("qoi.zig");
const ByteTags = qoi.ByteTags;
const BitTags = qoi.BitTags;
const hashRGB = qoi.hashRGB;
const hashRGBA = qoi.hashRGBA;
const RGB = @import("../../Colors/rgb.zig").RGB;
const RGBA = @import("../../Colors/rgba.zig").RGBA;

pub fn decodeRgb(data: []const u8, out: []RGB) !void {
    const n_pixels = out.len;
    var prev: RGB = .{ .r = 0, .g = 0, .b = 0 };
    var px: RGB = .{ .r = 0, .g = 0, .b = 0 };
    var table: [64]RGB = @splat(.{ .r = 0, .g = 0, .b = 0 });
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
            },
        }
        prev = px;
        table[hashRGB(px)] = px;
        if (j >= n_pixels) return Error.OutOfBounds;
        out[j] = px;
        j += 1;
    }
    if (j != n_pixels) return Error.InvalidNumOfPixels;
}

pub fn decodeRgba(data: []const u8, out: []RGBA) !void {
    const n_pixels = out.len;
    var prev: RGBA = .{ .r = 0, .g = 0, .b = 0 };
    var px: RGBA = .{ .r = 0, .g = 0, .b = 0 };
    var table: [64]RGBA = @splat(.{ .r = 0, .g = 0, .b = 0 });
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
            },
        }
        prev = px;
        table[hashRGBA(px)] = px;
        if (j >= n_pixels) return Error.OutOfBounds;
        out[j] = px;
        j += 1;
    }
    if (j != n_pixels) return Error.InvalidNumOfPixels;
}
