const std = @import("std");
const DecodeError = @import("Error.zig").DecodeError;

pub fn isSigSame(sig: []const u8, exp_sig: []const u8) !void {
    if (!std.mem.eql(u8, sig, exp_sig))
        return DecodeError.UnexpectedSignature;
}
