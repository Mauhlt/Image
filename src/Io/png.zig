const std = @import("std");
const Image = @import("Image.zig").Image2D;
const IntrusiveInterface = @import("IntrusiveInterface.zig");
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
