const std = @import("std");

pub fn main(filepath: []const u8) !void {
    const f = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer f.close();

    var read_buffer: [4096]u8 = undefined;
    var reader = f.reader(&read_buffer);

    try readQoi(&reader.interface);
}
