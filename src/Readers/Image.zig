const std = @import("std");
const ConstImage = @import("ConstImage.zig");

/// assume packed RGBA
width: u32,
height: u32,
bit_depth: u8,
data: []u8,

fn widthBytes(self: *const @This()) usize {
    // 4 = rgba
    return self.width * 4 * self.bit_depth / 8;
}

fn toConstImage(self: *const @This()) ConstImage {
    return .{
        .width = self.width,
        .height = self.height,
        .bit_depth = self.bit_depth,
        .data = self.data,
    };
}
