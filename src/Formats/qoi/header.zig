const std = @import("std");
const Image = @import("../../root.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const Error = @import("../error.zig").Error;

// Misc
const Channel = @import("misc.zig").Channel;
const Colorspace = @import("misc.zig").Colorspace;
const SIG = @import("misc.zig").SIG;

pub const SIZE = 14;

width: u32,
height: u32,
channel: Channel,
colorspace: Colorspace,

pub fn fromImage(img: *const Image, tag: PixelTag) !@This() {
    if (img.width == 0 or img.height == 0) return Error.InvalidDimensions;
    _, const overflow = @mulWithOverflow(img.width, img.height);
    if (overflow > 0) return Error.InvalidDimensions;
    const channel: Channel = switch (tag) {
        .rgb => .rgb,
        .rgba => .rgba,
        else => return Error.InvalidChannels,
    };
    // anything not explicitly sRGB is written as linear
    const colorspace: Colorspace = if (std.mem.endsWith(u8, @tagName(img.fmt), "srgb")) .srgb else .linear;
    return .{
        .width = img.width,
        .height = img.height,
        .channel = channel,
        .colorspace = colorspace,
    };
}

pub fn decode(data: []const u8) !@This() {
    if (data.len < SIZE) return Error.InvalidDataLen;
    var i: usize = 0;
    if (!std.mem.startsWith(u8, data[i..], SIG)) //
        return Error.UnexpectedSignature;
    i = SIG.len;
    const width = std.mem.readInt(u32, data[i..][0..4], .big);
    i += @sizeOf(u32);
    const height = std.mem.readInt(u32, data[i..][0..4], .big);
    i += @sizeOf(u32);
    _, const overflow: u1 = @mulWithOverflow(width, height);
    if (overflow > 0) return Error.InvalidDimensions;
    const channel = std.enums.fromInt(Channel, data[i]) orelse
        return Error.InvalidChannels;
    i += @sizeOf(u8);
    const colorspace = std.enums.fromInt(Colorspace, data[i]) orelse
        return Error.InvalidColorspace;
    i += @sizeOf(u8);
    return .{
        .width = width,
        .height = height,
        .channel = channel,
        .colorspace = colorspace,
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
