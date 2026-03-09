r: u8,
g: u8,
b: u8,

pub fn flip(self: @This()) @This() {
    return .{
        .r = self.b,
        .g = self.g,
        .b = self.r,
    };
}
