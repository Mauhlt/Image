const std = @import("std");
const Header = @import("header.zig");
const Image = @import("../../root.zig");
const Error = @import("../error.zig");
const Pixels = @import("../../Colors/Pixels.zig");
const misc = @import("misc.zig");

/// Decodes P3 + P6
pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    var i: usize = 0;
    const hdr: Header = try .decode(data, &i);
    const n_pixels = @as(u32, hdr.width) * @as(u32, hdr.height);
    const rgbs = try gpa.alloc(@FieldType(Pixels, "rgbs"), n_pixels);
    errdefer gpa.free(rgbs);
    const bpc = if (hdr.max_value > 255) 2 else 1; // bytes per channel
    if (bpc == 2) return Error.Decode.UnsupportedBitsPerPixel;
    switch (hdr.sig) {
        .P3 => {
            var j: usize = 0;
            while (i < data.len) {
                var nums: [3]u8 = undefined;
                for (0..3) |_| {
                    const num = try misc.getNum(data[i..]);
                    i += num.index;
                    if (num.value > 255) return Error.Decode.InvalidNum;
                    nums[i] = @truncate(num.value);
                    i += misc.skipNonNumeric(data[i..]);
                }
                rgbs[j] = .{
                    .red = nums[0],
                    .green = nums[1],
                    .blue = nums[2],
                };
                j += 1;
            }
            if (j != n_pixels) return Error.Decode.InvalidDataLen;
        },
        .P6 => {
            if (((data.len - i) / 3) != n_pixels) return Error.Decode.InvalidDataLen;
            while (i < data.len) : (i += 3) {
                rgbs[i] = .{
                    .red = data[i],
                    .green = data[i + 1],
                    .blue = data[i + 2],
                };
            }
        },
    }
    return .{
        .width = hdr.width,
        .height = hdr.height,
        .fmt = .r8g8b8_srgb,
        .pixels = .{ .rgbs = rgbs },
    };
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
