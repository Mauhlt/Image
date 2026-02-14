const std = @import("std");
// do performance testing

pub fn runLengthDecodingV1(
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

test "Decoding" {
    var buffer1 = [_]T{0} ** 64;
    const decode_data = try runLengthDecodingV1(@TypeOf(encoded_data[0]), encoded_data, &buffer1);
    for (data, decode_data) |d, dd| try expectEqual(d, dd);
}
