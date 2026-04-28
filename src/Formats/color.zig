const std = @import("std");
const MultiArrayList = std.MultiArrayList;
const GRAY = u8;
const RGB = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};
pub const RGBA = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0xFF,
};
pub const Pixels = union(enum) {
    gray: *std.ArrayList(GRAY),
    rgb: *std.ArrayList(RGB),
    rgba: *std.ArrayList(RGBA),

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            .gray => |tag| tag.*.deinit(gpa),
            .rgb => |tag| tag.*.deinit(gpa),
            .rgba => |tag| tag.*.deinit(gpa),
        }
    }
};
