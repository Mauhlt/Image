const std = @import("std");
const Error = @import("Error.zig");

pub fn isSigSame(sig: []const u8, exp_sig: []const u8) !void {
    if (!std.mem.eql(u8, sig, exp_sig))
        return Error.Decode.UnexpectedSignature;
}
