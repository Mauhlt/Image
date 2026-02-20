const std = @import("std");
const Image = @import("Image.zig").Image2D;

// Neil Postman - Amusing Ourselves To Death
// Upton Sinclair - Jungle (meat-packing gross), brass tacks (newspaper expose)

pub fn readQoi(r: *std.Io.Reader) !void { // !Image
    // get signature
    const sig = r.take(4);
    const exp_sig = "qoif";
    if (!std.mem.eql(u8, sig, exp_sig))
        return DecodeError.InvalidSignature;

    const hdr = try Header.read(r);
    std.debug.print("Hdr: {any}\n", .{hdr});
}

const DecodeError = error{
    InavlidSignature,
};

const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Header = struct {
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: Colorspace,

    pub fn read(r: *std.Io.Reader) @This() {
        const hdr = r.take(10);

        const width: u32 = @bitCast(hdr[0..4].*);
        const height: u32 = @bitCast(hdr[4..8].*);
        const channels: Channels = @enumFromInt(hdr[8]);
        const colorspace: Colorspace = @enumFromInt(hdr[9]);

        return @This(){
            .width = width,
            .height = height,
            .channels = channels,
            .colorspace = colorspace,
        };
    }
};

pub fn hash(c: Color) u6 {
    return @truncate(r *% 3 +% g *% 5 +% b *% 7 +% a *% 11);
}
