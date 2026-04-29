const std = @import("std");
pub const GRAY = u8;
pub const RGB = struct {
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
    gray: std.ArrayList(GRAY),
    rgb: std.MultiArrayList(RGB), // more memory efficient
    rgba: std.MultiArrayList(RGBA),
    pub fn deinit(self: *const Pixels, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .gray => |*gray| @constCast(gray).deinit(gpa),
            .rgb => |*rgb| @constCast(rgb).deinit(gpa),
            .rgba => |*rgba| @constCast(rgba).deinit(gpa),
        }
    }
};
