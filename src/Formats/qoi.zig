const std = @import("std");
const Format = @import("Vulkan").Format;
const Image = @import("img.zig");
const RGBA = @import("color.zig").RGBA;
const Pixels = @import("color.zig").Pixels;
const isSigSame = @import("Misc.zig").isSigSame;

// TODO:
// - track number of pixels - make sure it matches n_pixels
// - track amount of data left - do not go over

const SIG = "QOIF";
// const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

fn hash(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void {
    const hdr: Header = try .decode(data);
    std.debug.print("{f}", .{hdr});
    // check end bytes
    std.debug.assert(std.mem.eql(u8, data[data.len - 8 ..], [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }));

    const pixels_slice = data[14..];
    const n_pixels = hdr.width * hdr.height;
    std.debug.print("# of Pixels: {}\nPixel Slice Len: {}\n", .{ n_pixels, pixels_slice.len });
    const pixels = blk: {
        var pixels: Pixels = undefined;
        switch (hdr.channel) {
            .rgb => {
                pixels = .{ .rgb = try .initCapacity(gpa, n_pixels) };
                break :blk pixels;
            },
            .rgba => {
                pixels = .{ .rgba = try .initCapacity(gpa, n_pixels) };
                break :blk pixels;
            },
        }
        break :blk pixels;
    };
    defer pixels.deinit(gpa);

    var i: usize = 0;
    var prev_pixel: RGBA = .{};
    var indices: [64]RGBA = undefined;
    indices[0] = 1;
    while (i < pixels_slice.len) : (i += 1) {
        switch (pixels_slice[i]) {
            0xFE => { // RGB
                prev_pixel = .{
                    .r = pixels_slice[i + 1],
                    .g = pixels_slice[i + 2],
                    .b = pixels_slice[i + 3],
                };
                i += 3;
            },
            0xFF => { // RGBA
                prev_pixel = .{
                    .r = pixels_slice[i + 1],
                    .g = pixels_slice[i + 2],
                    .b = pixels_slice[i + 3],
                    .a = pixels_slice[i + 4],
                };
                i += 4;
            },
            else => {
                const byte = pixels_slice[i];
                const bit_tag: BitTags = @enumFromInt(byte >> 6);
                switch (bit_tag) {
                    .index => {
                        prev_pixel = indices[byte & 0b0011_1111];
                    },
                    .diff => {
                        const dr = (byte >> 4) & 0x03;
                        const dg = (byte >> 2) & 0x03;
                        const db = byte & 0x03;
                        prev_pixel.r = prev_pixel.r +% dr -% 2;
                        prev_pixel.g = prev_pixel.g +% dg -% 2;
                        prev_pixel.b = prev_pixel.b +% db -% 2;
                    },
                    .luma => {
                        i += 1;
                        const byte2 = pixels_slice[i];
                        const diff_green = byte & 0x3F; // -32:31
                        const drdg = byte2 >> 4; // -8:7
                        const dbdg = byte2 & 0x3F; // -8:7
                        prev_pixel.g = prev_pixel.g +% diff_green -% 32;
                        prev_pixel.r = prev_pixel.r +% drdg +% diff_green -% 8;
                        prev_pixel.b = prev_pixel.b +% dbdg +% diff_green -% 8;
                    },
                    .run => {
                        const run = byte & 0x3F +% 1;
                        for (0..run) |_| {
                            switch (pixels) {
                                .rgb => |rgb| rgb.appendAssumeCapacity(.{
                                    .r = prev_pixel.r,
                                    .g = prev_pixel.g,
                                    .b = prev_pixel.b,
                                }),
                                .rgba => |rgba| rgba.appendAssumeCapacity(.{
                                    .r = prev_pixel.r,
                                    .g = prev_pixel.g,
                                    .b = prev_pixel.b,
                                    .a = prev_pixel.a,
                                }),
                                else => unreachable,
                            }
                        }
                        continue;
                    },
                }
            },
        }
        switch (pixels) {
            .rgb => |rgb| rgb.appendAssumeCapacity(.{
                .r = prev_pixel.r,
                .g = prev_pixel.g,
                .b = prev_pixel.b,
            }),
            .rgba => |rgba| rgba.appendAssumeCapacity(prev_pixel),
            else => unreachable,
        }
    }

    const slice = switch (pixels) {
        .rgb => |rgb| rgb.slice(),
        .rgba => |rgba| rgba.slice(),
        else => unreachable,
    };
    std.debug.print("Img:\n", .{});
    std.debug.print("Reds: {}\n", .{slice.ptrs[0][0..slice.len]});
    std.debug.print("Greens: {}\n", .{slice.ptrs[1][0..slice.len]});
    std.debug.print("Blues: {}\n", .{slice.ptrs[2][0..slice.len]});
}

const BitTags = enum(u8) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

pub fn encode() void {}

const Header = struct {
    width: u32,
    height: u32,
    channel: Channel,
    colorspace: Colorspace,

    pub fn fromImage() @This() {}

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
            return error.InvalidChannelValue;
        i += 1;
        const colorspace = std.enums.fromInt(Colorspace, data[i]) orelse
            return error.InvalidColorspaceValue;
        return .{
            .width = width,
            .height = height,
            .channel = channel,
            .colorpace = colorspace,
        };
    }

    pub fn encode() void {}

    pub fn format(self: @This(), w: *std.Io.Writer) void {
        try w.print("Width: {}\n", .{self.width});
        try w.print("Height: {}\n", .{self.height});
        try w.print("Colorspace: {t}\n", .{self.colorspace});
        try w.print("Channels: {t}\n", .{self.channel});
    }
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};
