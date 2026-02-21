const std = @import("std");
const Image = @import("Image.zig").Image2D;
const isSigSame = @import("Misc.zig").isSigSame;

const PPM = @This();

/// Reads a PPM File
pub fn read(allo: std.mem.Allocator, r: *std.Io.Reader) !Image {
    const sig = r.take(2);
    try isSigSame(sig, "P6");

    const hdr = Header.read(r);
    const size = hdr.width * hdr.height;

    var data = try allo.alloc(size, u8);
    try r.readSliceAll(&data);

    return .{
        .width = hdr.width,
        .height = hdr.height,
        .bit_depth = 8,
        .data = data,
    };
}

const Header = struct {
    width: u32,
    height: u32,

    pub fn read(r: *std.Io.Reader) @This() {
        return .{
            .width = r.takeInt(u32, .little),
            .height = r.takeInt(u32, .little),
        };
    }
};
