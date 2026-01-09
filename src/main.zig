const std = @import("std");
const rle = @import("algos.zig").run_length_encoding_v2;

pub fn main() void {
    const T: type = i16;
    var buffer: [128]T = undefined;
    const data = [64]T{
        140, -14, -14, -3, -1, 0, 0, 0,
        -10, -8,  14,  4,  2,  0, 0, 0,
        14,  -4,  -4,  -1, -1, 0, 0, 0,
        0,   -2,  -2,  0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
    };
    const output = rle(T, &data, &buffer);
    std.debug.print("Output: {}\n", .{output});
}

test "All Tests" {
    _ = @import("algos.zig");
}
