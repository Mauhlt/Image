const std = @import("std");
const RGBA = @import("Image.zig").RGBA;
const Image = @import("Image.zig").Image2D;
const isSigSame = @import("Misc.zig").isSigSame;
const PNG = @This();

interface: IntrusiveInterface,

pub fn read() void {}

pub fn write() void {}

pub fn init() @This() {
    return .{
        .interface = .{
            .vtable = &.{
                .read = read,
                .write = write,
            },
        },
    };
}
