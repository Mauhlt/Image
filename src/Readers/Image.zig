const std = @import("std");

width: u32,
bit_depth: u8,
// assume packed rgba
data: []u8,

fn widthBytes(self: *const @This()) usize {
    return self.width * 4 * self.bit_depth;
}

fn calcHeight(self: *const @This()) u32 {
    std.debug.assert(self.data.len > 0 and self.width > 0 and self.bit_depth > 0);
    return self.data.len / self.width / (self.bit_depth / 8);
}
