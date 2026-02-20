const std = @import("std");

pub fn readPng(r: *std.Io.Reader) !void {
    const sig = try r.take(8);
    const expected_sig = &.{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (std.mem.eql(u8, sig, expected_sig))
        return DecodeError.UnexpectedSignature;
}
