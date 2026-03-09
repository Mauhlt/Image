const std = @import("std");
const Io = std.Io;

const Image = @import("Image");

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    defer std.debug.assert(.ok == debug_allocator.deinit());

    // this works here!
    var img = try Image.read(io, gpa, "src/Data/BasicArt.bmp");
    defer img.deinit(gpa);

    switch (img.pixels) {
        inline else => |data| {
            std.debug.print("{}\n", .{data[0]});
            std.debug.print("{}\n", .{data[img.width * img.height - 1]});
        },
    }
}
