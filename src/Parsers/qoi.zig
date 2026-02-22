const std = @import("std");
const Image = @import("Image.zig").Image2D;
const Color = @typeInfo(Image).@"struct".fields[3];
const DecodeError = @import("Error.zig").DecodeError;

const QOI = @This();

// Neil Postman - Amusing Ourselves To Death
// Upton Sinclair - Jungle (meat-packing gross), brass tacks (newspaper expose)

pub fn read(r: *std.Io.Reader) !void { // !Image
    // get signature
    const sig = r.take(4);
    const exp_sig = "qoif";
    if (!std.mem.eql(u8, sig, exp_sig))
        return DecodeError.InvalidSignature;

    const hdr = try Header.read(r);
    std.debug.print("Hdr: {any}\n", .{hdr});
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
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

pub fn write(w: *std.Io.Writer) !void {}
