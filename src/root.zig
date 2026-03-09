const std = @import("std");
const Image = @import("Io/Image.zig");

pub inline fn read(
    io: std.Io,
    allo: std.mem.Allocator,
    filepath: []const u8,
) !Image {
    return .read(io, &allo, filepath);
}

pub inline fn write(
    io: std.Io,
    allo: std.mem.Allocator,
    image: *const Image,
    filepath: []const u8,
) !void {
    try image.write(io, &allo, filepath);
}
