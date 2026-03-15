r: u8,
g: u8,
b: u8,

pub fn diff(self: @This(), other: @This()) @This() {
    return .{
        .r = self.r - other.r,
        .g = self.g - other.g,
        .b = self.b - other.b,
    };
}
