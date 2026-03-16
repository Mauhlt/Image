const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const Image = @import("Image.zig");
const RGBA = @import("RGBA.zig");

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void { // !Image {
    _ = gpa;
    var i: usize = 0;
    const SIG = &.{ 137, 80, 78, 71, 13, 10, 26, 10 };
    try isSigSame(SIG, data[0..SIG.len]);
    i += SIG.len;

    while (true) {
        const chunk: ChunkHeader = try .decode(data[i..]);
        std.debug.print("{f}\n", .{chunk});
        i += @sizeOf(@TypeOf(chunk.len)) + @sizeOf(ChunkTypeEnums);
        i += chunk.len;
        i += 4; // crc = 4 bytes
        if (chunk.type == .IEND) break;
    }

    // return Image{
    //     .extent = .{
    //         .width = hdr.width,
    //         .height = hdr.height,
    //         .depth = 1,
    //     },
    //     .pixel_format = .r8g8b8a8_srgb,
    //     .pixels = undefined,
    // };
}

pub fn encode(
    self: *const @This(),
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    img: *const Image,
) !void {
    _ = gpa;
    _ = img;
    try self.hdr.write(w);
    try self.body.write(w);
}

const ColorType = enum(u8) {
    gray = 0,
    true = 1,
    index = 3,
    gray_alpha = 4,
    true_alpha = 6,
};

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    interlace: u8,

    pub fn decode(gpa: std.mem.Allocator, data: []const u8) !@This() {
        _ = data;
        _ = gpa;

        return .{
            .width = 0,
            .height = 0,
            .bit_depth = 0,
            .color_type = .true,
            .interlace = 0,
        };
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        return w.print("{}\n", .{self});
    }
};

const ChunkHeader = struct {
    len: u32,
    type: ChunkType,

    pub fn decode(data: []const u8) !@This() {
        const len: u32 = std.mem.readInt(u32, data[0..][0..4], .big);
        const _type: ChunkTypeEnums = std.meta.stringToEnum(ChunkTypeEnums, data[4..][0..4]) orelse //
            .unsupported;
        return .{
            .len = len,
            .type = switch (_type) {
                .unsupported => .{ .unsupported = data[4..][0..4] },
                inline else => |tag| @unionInit(ChunkType, @tagName(tag), {}),
            },
        };
    }

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        return switch (self.type) {
            .unsupported => w.print("{s}?: {d}\n", .{ self.type.unsupported, self.len }),
            else => w.print("{t}: {d}\n", .{ self.type, self.len }),
        };
    }
};

const ChunkType = union(enum(u32)) {
    unsupported: []const u8,
    IHDR,
    IDAT,
    IEND,
};
const ChunkTypeEnums = @typeInfo(ChunkType).@"union".tag_type.?;
