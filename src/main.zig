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

    // memory grabs the data then parses it - it works!
    const img = try Image.read(io, gpa, "src/Data/BasicArt.bmp");
    defer img.deinit(gpa);
    // std.debug.print("Img:\n\t{} x {} x {}", .{ img.extent.width, img.extent.height, img.extent.depth });
    // std.debug.print("\n\t{}\n\t{}\n", .{ img.pixels.rgb[0], img.pixels.rgb[img.extent.width * img.extent.height - 1] });
}
