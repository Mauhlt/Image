const std = @import("std");

const Header = struct {
    // magic: [4]u8, // qoif
    width: u32, // width in pixels
    height: u32, // height in pixels
    channels: u8, // 3 = rgb, 4 = rgba
    colorspace: u8, // 0 = srgb + linear alpha, 1 = all channels linear
};

// encoded left to right, top to bottom
// run of previous pixel

fn indexPosition(rgba: RGBA) u64 {
    return @mod(rgba.r * 3 + rgba.g * 5 + rgba.b * 7 + rgba.a * 11, 64);
}

const RGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

fn read32(bytes: []const u8, p: *i32) u32 {
    _ = bytes;
    _ = p;
    return 0;
}

fn write32(file: std.fs.File, v: RGBA) !void {
    const data = [_]u32{
        (0xff000000 & v) >> 24,
        (0x00ff0000 & v) >> 16,
        (0x0000ff00 & v) >> 8,
        0x000000ff & v,
    };
    try file.write(&data);
}

fn encode(file: std.fs.File) !void {}

fn decode(file: std.fs.File) !void {}

const OP = enum(u32) {
    index = 0x00,
    diff = 0x40,
    luma = 0x80,
    run = 0xc0,
    rgb = 0xfe,
    rgba = 0xff,
    mask = 0xc0,
};
fn color_hash(color: RGBA) u32 {
    return @mod(color.r * 3 + color.g * 5 + color.b * 7 + color.a * 11, 64);
}

fn magic() u32 {
    return @as(u32, q << 24 | o << 16 | i << 8 | f);
}

const header_size = 14;
const max_pixels: u32 = 400000000;
