const std = @import("std");

pub const RGB = extern struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.r == other.r and //
            self.g == other.g and //
            self.b == other.b;
    }

    pub fn diff(self: @This(), other: @This()) @This() {
        return .{
            .r = self.r - other.r,
            .g = self.g - other.g,
            .b = self.b - other.b,
        };
    }

    pub fn rgba(self: @This()) RGBA {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }
};

pub const RGBA = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.r == other.r and //
            self.g == other.g and //
            self.b == other.b and //
            self.a == other.a;
    }

    pub fn diff(self: @This(), other: @This()) @This() {
        return .{
            .r = self.r - other.r,
            .g = self.g - other.g,
            .b = self.b - other.b,
            .a = self.a - other.a,
        };
    }

    pub fn rgb(self: @This()) RGB {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }
};
