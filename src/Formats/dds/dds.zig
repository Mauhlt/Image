//! DirectDraw Surface. Reads legacy FourCC (DXT1-5, ATI1/2) and DX10 headers:
//! BC1-7, RGBA8/BGRA8/R8/RG8, mipmaps, arrays, cube maps.
//! Writes the DX10 header (keeps sRGB + array info).
//! DDS stores layer-major (all mips of layer 0, then layer 1, ...); `Texture` is
//! level-major, so data is reordered on the way in / out.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Texture = @import("../../texture.zig");
const Header = @import("header.zig");

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Texture {
    const hdr: Header = try .decode(data);
    if (Texture.layoutOf(hdr.fmt) == null) return Error.UnsupportedColorspace;
    var tex: Texture = .{
        .fmt = hdr.fmt,
        .width = hdr.width,
        .height = hdr.height,
        .levels = hdr.levels,
        .layers = hdr.layers,
        .faces = hdr.faces,
        .data = &.{},
    };
    tex.data = try gpa.alloc(u8, tex.totalLen());
    errdefer gpa.free(tex.data);

    var pos = hdr.data_offset;
    for (0..tex.layers) |layer| for (0..tex.faces) |face| for (0..tex.levels) |level| {
        const dst = tex.slice(@intCast(level), @intCast(layer), @intCast(face));
        if (pos + dst.len > data.len) return Error.UnexpectedEndOfData;
        @memcpy(dst, data[pos..][0..dst.len]);
        pos += dst.len;
    };
    return tex;
}

pub fn encode(tex: *const Texture, w: *std.Io.Writer) !void {
    const dxgi = Header.vkToDxgi(tex.fmt) orelse return Error.UnsupportedColorspace;
    var h: [Header.HEADER_SIZE]u8 = @splat(0);
    const F = Header.Flags;
    const compressed = Texture.layoutOf(tex.fmt).?.block_dim == 4;
    std.mem.writeInt(u32, h[0..4], Header.HEADER_SIZE, .little);
    std.mem.writeInt(u32, h[4..8], F.caps | F.height | F.width | F.pixel_format | F.mip_count | F.linear_size, .little);
    std.mem.writeInt(u32, h[8..12], tex.height, .little);
    std.mem.writeInt(u32, h[12..16], tex.width, .little);
    const level0: u32 = @intCast(Texture.imageLen(tex.fmt, tex.width, tex.height));
    std.mem.writeInt(u32, h[16..20], if (compressed) level0 else level0 / tex.height, .little);
    std.mem.writeInt(u32, h[24..28], tex.levels, .little);
    // pixel format -> "DX10"
    std.mem.writeInt(u32, h[72..76], 32, .little);
    std.mem.writeInt(u32, h[76..80], Header.PF_FOURCC, .little);
    h[80..84].* = "DX10".*;
    var caps: u32 = Header.CAPS_TEXTURE;
    if (tex.levels > 1) caps |= Header.CAPS_MIPMAP | Header.CAPS_COMPLEX;
    if (tex.faces == 6) caps |= Header.CAPS_COMPLEX;
    std.mem.writeInt(u32, h[104..108], caps, .little);
    std.mem.writeInt(u32, h[108..112], if (tex.faces == 6) Header.CAPS2_CUBEMAP_ALL else 0, .little);

    try w.writeAll(Header.MAGIC);
    try w.writeAll(&h);
    try w.writeInt(u32, dxgi, .little);
    try w.writeInt(u32, 3, .little); // TEXTURE2D
    try w.writeInt(u32, if (tex.faces == 6) Header.MISC_TEXTURECUBE else 0, .little);
    try w.writeInt(u32, tex.layers, .little);
    try w.writeInt(u32, 0, .little); // alpha mode unknown

    for (0..tex.layers) |layer| for (0..tex.faces) |face| for (0..tex.levels) |level| {
        try w.writeAll(tex.slice(@intCast(level), @intCast(layer), @intCast(face)));
    };
}
