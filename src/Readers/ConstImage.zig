const std = @import("std");
const Image = @import("Image.zig");

/// Assume packed RGBA
width: u32,
bit_depth: u8,
data: []const u8,

fn widthBytes(self: *const @This()) usize {
    return self.width * 4 * self.bit_depth;
}

pub fn calcHeight(self: *const @This()) u32 {
    std.debug.assert(self.width > 0 and self.data.len > 0 and self.bit_depth > 0);
    return self.data.len / self.width;
}
