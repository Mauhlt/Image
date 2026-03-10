r: u8,
g: u8,
b: u8,

pub fn bgr(self: *const @This()) @This() {
    return .{
        .r = self.b,
        .g = self.g,
        .b = self.r,
    };
}
