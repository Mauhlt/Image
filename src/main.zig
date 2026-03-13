const std = @import("std");
const Io = std.Io;

const Image = @import("root.zig");

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    defer std.debug.assert(.ok == debug_allocator.deinit());

    // var img = try Image.read(io, gpa, "src/Data/BasicArt.bmp");
    // defer img.deinit(gpa);
    //
    // std.debug.print("{f}", .{img});

    const data = try Image.read(io, gpa, "src/Data/BasicArt.bmp", .{ .n_threads = 4 });
    defer gpa.free(data);
}
