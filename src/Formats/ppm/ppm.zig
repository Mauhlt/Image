const std = @import("std");
const Header = @import("header.zig");
const Image = @import("../../root.zig");
const Error = @import("../error.zig");

const RGB = @import("../../Colors/pixel_format.zig").RGB;
const Pixels = @import("../../Colors/Pixels.zig");
// https://netpbm.sourceforge.net/doc/ppm.html

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    const hdr: Header = try .decode(data);
    const n_pixels = hdr.width * hdr.height;
    var img: Image = undefined;
    img.width = hdr.width;
    img.height = hdr.height;
    img.pixels.rgbs = try gpa.alloc(RGB, n_pixels);
    if (hdr.max_value > 255) {
        if (data.len - hdr.i_pos != n_pixels * 3) return Error.Decode.InvalidDimensions;
        @memcpy(img.pixels.rgbs, data[hdr.i_pos..]);
    } else {
        if (data.len - hdr.i_pos != (n_pixels * 6)) return Error.Decode.InvalidDimensions;
        @memcpy(img.pixels.rgbs16, data[hdr.i_pos..]);
    }
}

pub fn encode(img: *const Image, w: *std.Io.Writer) !void {
    const hdr: Header = try .fromImage(img);
    try hdr.encode(w);
    switch (img.pixels) {
        .rgbs => |rgbs| {
            try w.writeAll(@as([]const u8, @ptrCast(rgbs)));
        },
        else => return Error.Encode.InvalidColorspace,
    }
}
