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
    gray: []GRAY,
    rgb: []RGB,
    rgba: []RGBA,
    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            inline else => |tag| gpa.free(tag),
        }
    }
};
