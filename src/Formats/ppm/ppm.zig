const std = @import("std");
const Header = @import("header.zig");
const Image = @import("../../root.zig");
const Error = @import("../error.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;
const misc = @import("misc.zig");

const BPC = enum(u8) { // Bytes Per Channel
    one = 0,
    two = 1,
};

/// Decodes P3 + P6
pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    _ = gpa;
    var i: usize = 0;
    const hdr: Header = try .decode(data, &i);
    const n_pixels = @as(u32, hdr.width) * @as(u32, hdr.height);
    _ = n_pixels;
    const T = @typeInfo(@FieldType(Pixels, "rgbs")).pointer.child;
    std.debug.print("{}\n", .{T});
    return error.Incomplete;
    // const rgbs = try gpa.alloc(@typeInfo(@FieldType(Pixels, "rgbs")).pointer.child, n_pixels);
    // errdefer gpa.free(rgbs);
    // const bpc: BPC = if (hdr.max_value > 255) .two else .one;
    // if (bpc == .two) return Error.Decode.UnsupportedBitsPerPixel;
    // switch (hdr.sig) {
    //     .P3 => {
    //         var j: usize = 0;
    //         while (i < data.len) : (j += 1) {
    //             var nums: [3]u8 = undefined;
    //             for (0..3) |_| {
    //                 const num = try misc.getNum(data[i..]);
    //                 i += num.index;
    //                 if (num.value > 255) return Error.Decode.InvalidNum;
    //                 nums[i] = @truncate(num.value);
    //                 i += misc.skipNonNumeric(data[i..]);
    //             }
    //             rgbs[j] = .{
    //                 .red = nums[0],
    //                 .green = nums[1],
    //                 .blue = nums[2],
    //             };
    //         }
    //         if (j != n_pixels) return Error.Decode.InvalidDataLen;
    //     },
    //     .P6 => {
    //         if (((data.len - i) / 3) != n_pixels) return Error.Decode.InvalidDataLen;
    //         while (i < data.len) : (i += 3) {
    //             rgbs[i] = .{
    //                 .red = data[i],
    //                 .green = data[i + 1],
    //                 .blue = data[i + 2],
    //             };
    //         }
    //     },
    // }
    // return .{
    //     .width = hdr.width,
    //     .height = hdr.height,
    //     .fmt = .r8g8b8_srgb,
    //     .pixels = .{ .rgbs = rgbs },
    // };
}

/// Only encodes P6
pub fn encode(img: *const Image, w: *std.Io.Writer) !void {
    const hdr: Header = try .fromImage(img);
    try hdr.encode(w);
    switch (img.pixels) {
        .rgbs => |rgbs| {
            try w.writeAll(@as([]const u8, @ptrCast(rgbs)));
        },
        .bgrs => |bgrs| {
            for (bgrs) |bgr| {
                try w.writeByte(bgr.red);
                try w.writeByte(bgr.green);
                try w.writeByte(bgr.blue);
            }
        },
        else => return Error.Encode.InvalidColorspace,
    }
}

fn skip() usize {}
