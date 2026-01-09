const std = @import("std");
const expectEqual = std.testing.expectEqual;

pub fn run_length_encoding_v1(
    comptime T: type,
    data: []const T,
    buffer: []T,
) ![]const T {
    // first value = data
    // second value = amt of data
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Fn only accepts ints."),
    }
    const sign = @typeInfo(T).int.signedness;
    const is_smaller = @typeInfo(T).int.bits < 64;
    var i: usize = 0;
    var k: usize = 0;
    const len = data.len;
    while (i < len) : (i += 1) {
        var j: usize = 1;
        while (i + j < data.len and data[i + j] == data[i]) : (j += 1) {}
        buffer[k] = data[i];
        i += j - 1;
        k += 1;
        if (k >= buffer.len) return error.FoundTooManyUniqueSymbols;
        switch (sign) {
            .signed => buffer[k] = @intCast(j),
            .unsigned => switch (is_smaller) {
                true => buffer[k] = @truncate(j),
                false => buffer[k] = j,
            }
        }
        k += 1;
        if (k >= buffer.len) return error.FoundTooManyUniqueSymbols;
    }
    return buffer[0..k];
}

pub fn run_length_decoding_v1(
    comptime T: type,
    data: []const T,
    buffer: []T,
) ![]const T {
    // performs run length decoding
    // assumes length is greater than 0
    // safety check: pre-compute full length
    var i: usize = 1;
    const len = data.len;
    var total_len: usize = 0;
    while (i < len) : (i += 2) {
        switch (@typeInfo(T).int.signedness) {
            .signed => total_len += @intCast(data[i]),
            .unsigned => total_len += data[i],
        }
    }
    if (total_len > buffer.len) return error.BufferTooSmall;
    // decode
    var k: usize = 0;
    i = 0;
    while (i < len) {
        var curr_len: usize = 0;
        switch (@typeInfo(T).int.signedness) {
            .signed => curr_len = @intCast(data[i + 1]),
            .unsigned => curr_len = data[i + 1],
        }
        @memset(buffer[k .. k + curr_len], data[i]);
        k += curr_len;
        i += 2;
    }
    return buffer[0..k];
}

pub fn run_length_encoding_v2(
    comptime T: type,
    data: []const T,
    buffer: []T,
) ![]const T {
    // use vector to speed up
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Fn only accepts ints."),
    }
    var i: usize = 0;
    var k: usize = 0;
    var matches: u64 = @bitCast(@as(@Vector(64, T), data[i..][0..64].*) == @as(@Vector(64, T), data[i + 1 ..][0..64].*));
    matches = ~matches;
    var total_matches: usize = 0;
    var n_matches: usize = 0;
    while (matches > 0) {
        n_matches = @ctz(matches) + 1;
        buffer[k] = data[i];
        k += 1;
        buffer[k] = switch (@typeInfo(T).int.signedness) {
            .signed => @intCast(n_matches),
            .unsigned => n_matches,
        };
        k += 1;
        matches = matches >> @truncate(n_matches);
        i += n_matches;
        total_matches += n_matches;
    }
    if (total_matches != 64) {
        buffer[k] = data[i];
        k += 1;
        const diff = 64 - total_matches + 1;
        buffer[k] = switch (@typeInfo(T).int.signedness) {
            .signed => @intCast(diff),
            .unsigned => diff,
        };
        k += 1;
    }
    return buffer[0..k];
}

test "Run Length Encoding/Decoding" {
    // // Encoding
    // const T: type = i16;
    // const data = [64]T{
    //     140, -14, -14, -3, -1, 0, 0, 0,
    //     -10, -8,  14,  4,  2,  0, 0, 0,
    //     14,  -4,  -4,  -1, -1, 0, 0, 0,
    //     0,   -2,  -2,  0,  0,  0, 0, 0,
    //     0,   0,   0,   0,  0,  0, 0, 0,
    //     0,   0,   0,   0,  0,  0, 0, 0,
    //     0,   0,   0,   0,  0,  0, 0, 0,
    //     0,   0,   0,   0,  0,  0, 0, 0,
    // };
    // var buffer = [_]T{0} ** 64;
    // const encoded_data = try run_length_encoding_v1(@TypeOf(data[0]), &data, &buffer);
    // const expected_encoded_data = [_]T{ 140, 1, -14, 2, -3, 1, -1, 1, 0, 3, -10, 1, -8, 1, 14, 1, 4, 1, 2, 1, 0, 3, 14, 1, -4, 2, -1, 2, 0, 4, -2, 2, 0, 37 };
    // for (encoded_data, expected_encoded_data) |ed, eed| try expectEqual(eed, ed);
    // var buffer1 = [_]T{0} ** 64;
    // const decode_data = try run_length_decoding_v1(@TypeOf(encoded_data[0]), encoded_data, &buffer1);
    // for (data, decode_data) |d, dd| try expectEqual(d, dd);
    //
    // const data2 = [_]u8{ 'A', 'A', 'A', 'A', 'B', 'B', 'B', 'C', 'C', 'D', 'A', 'A' };
    // var buffer2 = [_]u8{0} ** 64;
    // const encoded_data_2 = try run_length_encoding_v1(@TypeOf(data2[0]), &data2, &buffer2);
    // const expected_encoded_data_2 = [_]u8{ 'A', 4, 'B', 3, 'C', 2, 'D', 1, 'A', 2 };
    // for (expected_encoded_data_2, encoded_data_2) |eed, ed| try expectEqual(eed, ed);
    // var buffer3 = [_]u8{0} ** 64;
    // const decode_data_2 = try run_length_decoding_v1(@TypeOf(encoded_data_2[0]), encoded_data_2, &buffer3);
    // for (data2, decode_data_2) |d, dd| try expectEqual(d, dd);

    // run length encoding v2
    const data = [65]i16{
        140, -14, -14, -3, -1, 0, 0, 0,
        -10, -8,  14,  4,  2,  0, 0, 0,
        14,  -4,  -4,  -1, -1, 0, 0, 0,
        0,   -2,  -2,  0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,
    };
    var buffer4 = [_]i16{0} ** 64;
    const output = try run_length_encoding_v2(@TypeOf(data[0]), &data, &buffer4);
    var i: usize = 0;
    while (i < output.len) : (i += 2) {
        std.debug.print("{}:{}\n", .{ output[i], output[i + 1] });
    }
}

pub fn zigZag() void {
    // 1. go right
    // 2. go downleft until left col or bot row
    // 3a. if bot row, go right
    // 3b. if left col, go down
    // 4. go upright until top row or right col
    // 5a. if top row, go right
    // 5b. if right col, go down
    // 6. if row 7, col 7, break
    // works!
    // for optimization: store indices as an array instead

    var i: usize = 0; // inc from [0-63]
    var s: SubIndex = .{ .row = 0, .col = 0 }; // guaranteed at top left
    var j: usize = s.subindex2Index(); // current pixel in 8x8 block = should be 0

    outer: switch (ZigZagDir.right) {
        .upright => {
            i += 1;
            // list_of_actions[i] = .upright;
            s.row -= 1;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .right;
            } else if (s.col == 7) {
                continue :outer .down;
            } else {
                continue :outer .upright;
            }
            unreachable;
        },
        .right => {
            i += 1;
            // list_of_actions[i] = .right;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .downleft;
            } else if (s.row == 7 and s.col != 7) {
                continue :outer .upright;
            } else break :outer;
            unreachable;
        },
        .downleft => {
            i += 1;
            // list_of_actions[i] = .downleft;
            s.row += 1;
            s.col -= 1;
            j = s.subindex2Index();
            if (s.row == 7) {
                continue :outer .right;
            } else if (s.col == 0) {
                continue :outer .down;
            } else {
                continue :outer .downleft;
            }
            unreachable;
        },
        .down => {
            i += 1;
            // list_of_actions[i] = .down;
            s.row += 1;
            j = s.subindex2Index();
            if (s.col == 0) {
                continue :outer .upright;
            } else if (s.col == 7) {
                continue :outer .downleft;
            }
            unreachable;
        },
        .up, .left => unreachable,
    }
}

pub fn undoZigZag() void {
    // 1. go left
    // 2. go upright until top row or right col
    // 3a. if top row, go left
    // 3b. if right col, go up
    // 4. go downleft until left col or bot row
    // 5a. if left col, go up
    // 5b. if bot row, go left
    // 6. if row 0, col 0, break!
    // works!
    // for optimization: store indices as an array instead

    var i: usize = 63; // inc from [63-0]
    var s: SubIndex = .{ .row = 7, .col = 7 }; // guaranteed at top left
    var j: usize = s.subindex2Index(); // current pixel in 8x8 block = should be 0

    outer: switch (ZigZagDir.left) {
        .upright => {
            i -= 1;
            // list_of_actions[i] = .upright;
            s.row -= 1;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .left;
            } else if (s.col == 7) {
                continue :outer .up;
            } else {
                continue :outer .upright;
            }
            unreachable;
        },
        .left => {
            i -= 1;
            // list_of_actions[i] = .right;
            s.col -= 1;
            j = s.subindex2Index();
            if (s.row == 7) {
                continue :outer .upright;
            } else if (s.row == 0 and s.col != 0) {
                continue :outer .downleft;
            } else break :outer;
            unreachable;
        },
        .downleft => {
            i -= 1;
            // list_of_actions[i] = .downleft;
            s.row += 1;
            s.col -= 1;
            j = s.subindex2Index();
            if (s.row == 7) {
                continue :outer .left;
            } else if (s.col == 0) {
                continue :outer .up;
            } else {
                continue :outer .downleft;
            }
            unreachable;
        },
        .up => {
            i -= 1;
            // list_of_actions[i] = .down;
            s.row -= 1;
            j = s.subindex2Index();
            if (s.col == 7) {
                continue :outer .downleft;
            } else if (s.col == 0) {
                continue :outer .upright;
            }
            unreachable;
        },
        .down, .right => unreachable,
    }
}

const ZigZagDir = enum(u8) {
    upright,
    right,
    downleft,
    down,
    up,
    left,
};

const SubIndex = struct {
    row: usize = 0,
    col: usize = 0,

    fn subindex2Index(s: *const SubIndex) usize {
        return s.row * 8 + s.col;
    }
};

fn index2Subindex(i: u8) SubIndex {
    const col = @mod(i, 8);
    const row = (i - col) / 8; // need checks here
    return .{
        .row = row,
        .col = col,
    };
}

test "Sub 2 Index or Index 2 Sub" {
    // index2Subindex(i: u8);
}

fn huffmanEncoding(
    comptime T: type,
    allo: std.mem.Allocator,
    data: []const T,
    buffer: []T,
) !void {
    var map = std.AutoArrayHashMap(T, T).init(allo);
    defer map.deinit();
    for (data) |ch| {
        if (map.get(ch)) |value| {} else {}
    }
}
fn huffmanDecoding() void {}
