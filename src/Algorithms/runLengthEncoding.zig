const std = @import("std");

pub fn runLengthEncodingV1(
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

pub fn runLengthEncodingV2(
    comptime T: type,
    data: []const T,
    buffer: []T,
) ![]const T {
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Fn only accepts ints."),
    }
    var i: usize = 0;
    var k: usize = 0;
    var matches: u64 =
        @bitCast(@as(@Vector(64, T), data[i..][0..64].*) == @as(@Vector(64, T), data[i + 1 ..][0..64].*));
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

test "Hello " {
    // Encoding
    const T: type = i16;
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
    var buffer = [_]T{0} ** 64;
    const encoded_data = try runLengthEncodingV1(@TypeOf(data[0]), &data, &buffer);
    const expected_encoded_data = [_]T{ 140, 1, -14, 2, -3, 1, -1, 1, 0, 3, -10, 1, -8, 1, 14, 1, 4, 1, 2, 1, 0, 3, 14, 1, -4, 2, -1, 2, 0, 4, -2, 2, 0, 37 };
    for (encoded_data, expected_encoded_data) |ed, eed| try std.testing.expectEqual(eed, ed);
    var buffer1 = [_]T{0} ** 64;
    const decode_data = try runLengthDecodingV1(@TypeOf(encoded_data[0]), encoded_data, &buffer1);
    for (data, decode_data) |d, dd| try expectEqual(d, dd);
}
