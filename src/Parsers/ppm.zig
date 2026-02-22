const std = @import("std");
const Image = @import("Image.zig").Image2D;
const isSigSame = @import("Misc.zig").isSigSame;
const testing = std.testing;

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

pub fn write(w: *std.Io.Writer, img: Image) !void {
    try w.write("P6");
    try w.write(img.width);
    try w.write(img.height);
    try w.writeAll(img.data);
}

test "PPM Writer" {
    var f1 = try std.fs.cwd().openFile("Data/BasicArt.ppm", .{});
    defer f1.close();

    var f2 = try std.fs.cwd().openFile("Data/NewArt.ppm", .{});
    defer f2.close();

    const stat1 = try f1.stat();
    const stat2 = try f2.stat();
    if (stat1.size != stat2.size) return error.MismatchFileLengths;

    var buf1: [1 * 1024 * 1024]u8 = undefined;
    var buf2: [1 * 1024 * 1024]u8 = undefined;

    var reader1 = f1.reader(&buf1);
    var reader2 = f2.reader(&buf2);

    var rbuf1: [1024]u8 = undefined;
    var rbuf2: [1024]u8 = undefined;

    var i: usize = 0;
    while (i < stat1.size) {
        const len1 = try reader1.interface.readSliceShort(&rbuf1);
        const len2 = try reader2.interface.readSliceShort(&rbuf2);
        testing.expect(len1 == len2);
        testing.expectEqual(rbuf1[0..len1], rbuf2[0..len2]);
        i += len1;
    }
}
