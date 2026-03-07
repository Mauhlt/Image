const std = @import("std");
const ImageFile = @import("Io/IMageLoader.zig").ImageFile;

pub inline fn read(
    io: std.Io,
    allo: *const std.mem.Allocator,
    filepath: []const u8,
) !ImageFile {
    return .read(io, &allo, filepath);
}

pub inline fn write(
    io: std.Io,
    allo: *const std.mem.Allocator,
    image: *const ImageFile,
    filepath: []const u8,
) !void {
    try image.write(io, &allo, filepath);
}
