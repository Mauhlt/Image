r: u8,
g: u8,
b: u8,
a: u8,

pub fn flip(self: @This()) @This() {
    return .{
        .r = self.a,
        .g = self.b,
        .b = self.g,
        .a = self.r,
    };
}
