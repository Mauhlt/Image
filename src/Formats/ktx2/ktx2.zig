//! KTX 2.0 - the Khronos texture container. Stores the VkFormat directly, so loading is:
//! read header -> (optionally inflate each level) -> copy levels -> upload.
//! Reads: any VkFormat this library knows the layout of, mipmaps, arrays, cube maps,
//!        supercompression none / zstd / zlib. (BasisLZ / UASTC transcoding: unsupported.)
//! Writes: no supercompression, with a valid Data Format Descriptor.
const std = @import("std");
const vk = @import("Vulkan");
const Error = @import("../error.zig").Error;
const Texture = @import("../../texture.zig");
const Header = @import("header.zig");

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Texture {
    const hdr: Header = try .decode(data);
    const fmt: vk.Format = std.enums.fromInt(vk.Format, hdr.vk_format) orelse return Error.UnsupportedColorspace;
    if (Texture.layoutOf(fmt) == null) return Error.UnsupportedColorspace;
    switch (hdr.supercompression) {
        .none, .zstd, .zlib => {},
        else => return Error.UnsupportedCompression,
    }
    var tex: Texture = .{
        .fmt = fmt,
        .width = hdr.width,
        .height = @max(1, hdr.height),
        .levels = @max(1, hdr.levels),
        .layers = @max(1, hdr.layers),
        .faces = hdr.faces,
        .data = &.{},
    };
    tex.data = try gpa.alloc(u8, tex.totalLen());
    errdefer gpa.free(tex.data);

    // zstd needs a large window buffer; allocate once for all levels
    var window: []u8 = &.{};
    defer gpa.free(window);
    if (hdr.supercompression == .zstd)
        window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    if (hdr.supercompression == .zlib)
        window = try gpa.alloc(u8, std.compress.flate.max_window_len);

    for (0..tex.levels) |l| {
        const lvl = Header.level(data, l);
        if (lvl.offset + lvl.len > data.len) return Error.UnexpectedEndOfData;
        const src = data[@intCast(lvl.offset)..][0..@intCast(lvl.len)];
        // level-major with layers/faces inside: identical to Texture's layout
        const dst = tex.data[tex.offsetOf(@intCast(l), 0, 0)..][0..tex.levelLen(@intCast(l))];
        switch (hdr.supercompression) {
            .none => {
                if (src.len != dst.len) return Error.InvalidDataLen;
                @memcpy(dst, src);
            },
            .zstd => {
                var r: std.Io.Reader = .fixed(src);
                var z: std.compress.zstd.Decompress = .init(&r, window, .{});
                z.reader.readSliceAll(dst) catch return Error.DecompressionFailed;
            },
            .zlib => {
                var r: std.Io.Reader = .fixed(src);
                var z: std.compress.flate.Decompress = .init(&r, .zlib, window);
                z.reader.readSliceAll(dst) catch return Error.DecompressionFailed;
            },
            else => unreachable,
        }
    }
    return tex;
}

pub fn encode(tex: *const Texture, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const layout = Texture.layoutOf(tex.fmt) orelse return Error.UnsupportedColorspace;
    var dfd: std.ArrayList(u8) = .empty;
    defer dfd.deinit(gpa);
    try Header.writeDfd(tex.fmt, &dfd, gpa);

    const dfd_offset: u32 = @intCast(Header.HEADER_SIZE + tex.levels * Header.LEVEL_ENTRY_SIZE);
    // level data aligned to lcm(block bytes, 4); levels stored smallest first (spec recommendation)
    const alignment: u64 = std.math.lcm(@as(u64, layout.block_bytes), 4);
    var offsets: [32]u64 = undefined;
    var pos: u64 = dfd_offset + dfd.items.len;
    var l = tex.levels;
    while (l > 0) {
        l -= 1;
        pos = std.mem.alignForward(u64, pos, alignment);
        offsets[l] = pos;
        pos += tex.levelLen(l);
    }

    try w.writeAll(&Header.IDENTIFIER);
    for ([_]u32{
        @intFromEnum(tex.fmt),
        if (layout.block_dim == 4) 1 else 1, // typeSize: 1 for block-compressed and 8-bit formats
        tex.width,
        tex.height,
        0, // depth
        if (tex.layers > 1) tex.layers else 0,
        tex.faces,
        tex.levels,
        @intFromEnum(Header.Supercompression.none),
        dfd_offset,
        @intCast(dfd.items.len),
        0, // kvd offset
        0, // kvd len
    }) |v| try w.writeInt(u32, v, .little);
    try w.writeInt(u64, 0, .little); // sgd offset
    try w.writeInt(u64, 0, .little); // sgd len
    for (0..tex.levels) |i| {
        const len = tex.levelLen(@intCast(i));
        try w.writeInt(u64, offsets[i], .little);
        try w.writeInt(u64, len, .little);
        try w.writeInt(u64, len, .little);
    }
    try w.writeAll(dfd.items);

    var written: u64 = dfd_offset + dfd.items.len;
    l = tex.levels;
    while (l > 0) {
        l -= 1;
        while (written < offsets[l]) : (written += 1) try w.writeByte(0);
        const bytes = tex.data[tex.offsetOf(l, 0, 0)..][0..tex.levelLen(l)];
        try w.writeAll(bytes);
        written += bytes.len;
    }
}

test "ktx2 zstd/zlib level" {
    // a 1-level 4x4 RGBA8 texture, level data zlib-compressed
    const gpa = std.testing.allocator;
    var pixels: [64]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i);
    var comp_aw: std.Io.Writer.Allocating = try .initCapacity(gpa, 256); // Compress needs > 8 bytes of output buffer
    defer comp_aw.deinit();
    {
        const hist = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(hist);
        var c: std.compress.flate.Compress = try .init(&comp_aw.writer, hist, .zlib, .default);
        try c.writer.writeAll(&pixels);
        try c.finish();
    }
    const level = comp_aw.written();
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    const w = &file.writer;
    try w.writeAll(&Header.IDENTIFIER);
    for ([_]u32{ @intFromEnum(vk.Format.r8g8b8a8_unorm), 1, 4, 4, 0, 0, 1, 1, 3, 0, 0, 0, 0 }) |v| try w.writeInt(u32, v, .little);
    try w.writeInt(u64, 0, .little);
    try w.writeInt(u64, 0, .little);
    try w.writeInt(u64, Header.HEADER_SIZE + Header.LEVEL_ENTRY_SIZE, .little);
    try w.writeInt(u64, level.len, .little);
    try w.writeInt(u64, 64, .little);
    try w.writeAll(level);
    const tex = try decode(gpa, file.written());
    defer tex.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &pixels, tex.data);
}
