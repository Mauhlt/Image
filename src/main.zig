const std = @import("std");
const Io = std.Io;

const Image = @import("root.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    defer std.debug.assert(.ok == debug_allocator.deinit());

    // still slower on mt mode - why?
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    // memory grabs the data then parses it
    try Image.read(io, gpa, "src/Data/BasicArt.bmp");
}
