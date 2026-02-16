const std = @import("std");

const DecodeError = error{
    InvalidSignature,
};

const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0xFF,
};

const Decoder = struct {
    previous_pixel: Color,
    previously_seen_pixels: [64]Color = [_]Color{.{}} ** 64,
    diff_pixel: Color,
    full_pixel: Color,
};

fn hash(c: Color) u8 {
    return (c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11) & 0b111111;
}

fn readQoi(r: *std.Io.Reader) !void {
    const hdr = try r.take(14);
    if (!std.mem.eql(u8, hdr[0..4], "qoif")) return DecodeError.InvalidSignature;

    const width = @as(u32, hdr[4..8]);
    const height = @as(u32, hdr[8..12]);
    const channels = std.enums.fromInt(Channels, hdr[12]);
    const colorspace = std.enums.fromInt(Colorspace, hdr[13]);

    std.debug.print("{}x{}\n{t}\n{t}\n", .{ width, height, channels, colorspace });
}
