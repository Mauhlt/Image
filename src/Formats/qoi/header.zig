const std = @import("std");
const Image = @import("../../root.zig"); // TODO: fix this
const Error = @import("../error.zig");
const isSigSame = @import("../misc.zig").isSigSame;

// Misc
const Channel = @import("misc.zig").Channel;
const Colorspace = @import("misc.zig").Colorspace;
const SIG = @import("misc.zig").SIG;

width: u32,
height: u32,
channel: Channel,
colorspace: Colorspace,

pub fn fromImage(img: *const Image) !@This() {
    if (img.width == 0 or img.height == 0) return Error.Encode.InvalidDimensions;
    _, const overflow = @mulWithOverflow(img.width, img.height);
    if (overflow > 0) return Error.Encode.InvalidDimensions;
    const channel: Channel = switch (img.pixels) {
        .rgb => .rgb,
        .rgba => .rgba,
        else => return Error.Encode.InvalidColorspace,
    };
    const colorspace = blk: {
        const tagname = @tagName(img.fmt);
        var colorspace: Colorspace = undefined;
        if (std.mem.endsWith(u8, tagname, "srgb")) {
            colorspace = .srgb;
        } else if (std.mem.endsWith(u8, tagname, "unorm")) {
            colorspace = .linear;
        } else {
            return Error.Encode.InvalidColorspace;
        }
        break :blk colorspace;
    };
    return .{
        .width = img.width,
        .height = img.height,
        .channel = channel,
        .colorspace = colorspace,
    };
}

pub fn decode(data: []const u8) !@This() {
    std.debug.assert(data.len > 14);
    var i: usize = 0;
    try isSigSame(SIG, data[i..][0..SIG.LEN]);
    i += SIG.LEN;
    const width = std.mem.readInt(u32, data[i..][0..4], .big);
    i += 4;
    const height = std.mem.readInt(u32, data[i..][0..4], .big);
    _, const overflow: u1 = @mulWithOverflow(width, height);
    if (overflow > 0) return error.InvalidDimensions;
    const channel = std.enums.fromInt(Channel, data[i]) orelse
        return error.InvalidChannels;
    i += 1;
    const colorspace = std.enums.fromInt(Colorspace, data[i]) orelse
        return error.InvalidColorspace;
    return .{
        .width = width,
        .height = height,
        .channel = channel,
        .colorpace = colorspace,
    };
}

pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
    try w.writeAll(SIG);
    try w.writeInt(u32, self.width, .big);
    try w.writeInt(u32, self.height, .big);
    try w.writeByte(@intFromEnum(self.channel));
    try w.writeByte(@intFromEnum(self.colorspace));
}

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    try w.print("Width: {}\n", .{self.width});
    try w.print("Height: {}\n", .{self.height});
    try w.print("Colorspace: {t}\n", .{self.colorspace});
    try w.print("Channels: {t}\n", .{self.channel});
}
