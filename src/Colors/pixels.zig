const std = @import("std");

const Position = @import("position.zig");

const OrderTag = @import("order.zig").OrderTag;

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

const misc = @import("misc.zig");
const simd = @import("simd.zig");
const U8_1 = @Vector(misc.N, u8); // mult of U8_I
const U8_2 = @Vector(misc.N * 2, u8);
const U8_3 = @Vector(misc.N * 3, u8);
const U8_4 = @Vector(misc.N * 4, u8);

pub const PixelTag = enum(u8) {
    g,
    rgb,
    bgr,
    ycbcr,
    ga,
    rgba,
    bgra,
    ycbcra,

    pub fn bytesPerPixel(self: PixelTag) u16 {
        return switch (self) {
            .g => 1,
            .ga => 2,
            .rgb, .bgr, .ycbcr => 3,
            .rgba, .bgra, .ycbcra => 4,
        };
    }
};

pub const Pixels = union(PixelTag) {
    g: []G,
    rgb: []RGB,
    bgr: []BGR,
    ycbcr: []YCbCr,

    ga: []GA,
    rgba: []RGBA,
    bgra: []BGRA,
    ycbcra: []YCbCrA,

    /// Assumes data is:
    ///     - correct alignment (u24 vs u32)
    ///     - correct order (rgb vs bgr)
    pub fn init(
        comptime pixel_tag: PixelTag,
        gpa: std.mem.Allocator,
        data: []const u8,
    ) !Pixels {
        if (@mod(data.len, pixel_tag.bytesPerPixel()) != 0 or data.len == 0) //
            return error.InvalidDataLength;
        return fromBytes(pixel_tag, try gpa.dupe(u8, data));
    }

    /// Reinterprets `bytes` as pixels of `tag` without copying.
    /// Every pixel struct is an `extern struct` of u8s (align 1), so any byte slice
    /// whose length is a multiple of `tag.bytesPerPixel()` is valid.
    /// Ownership of `bytes` moves to the returned value (free with `deinit`).
    pub fn fromBytes(tag: PixelTag, bytes: []u8) Pixels {
        std.debug.assert(bytes.len % tag.bytesPerPixel() == 0);
        return switch (tag) {
            inline else => |t| @unionInit(Pixels, @tagName(t), @ptrCast(bytes)),
        };
    }

    /// Raw byte view of the pixel data (no copy).
    pub fn asBytes(self: Pixels) []u8 {
        return switch (self) {
            inline else => |data| std.mem.sliceAsBytes(data),
        };
    }

    pub fn count(self: Pixels) usize {
        return switch (self) {
            inline else => |data| data.len,
        };
    }

    /// Builds pixels of `pixel_tag` from `data` whose channels are stored in `data_order`
    /// (e.g. `.bgr` data into `.rgb` pixels).
    pub fn initOrder(
        comptime pixel_tag: PixelTag,
        gpa: std.mem.Allocator,
        data: []const u8,
        data_order: OrderTag,
    ) !Pixels {
        const bpp = comptime pixel_tag.bytesPerPixel();
        if (data.len == 0 or data.len % bpp != 0) return error.InvalidDataLength;
        if (bpp == 1) return init(pixel_tag, gpa, data);
        const Elem = std.meta.Elem(@FieldType(Pixels, @tagName(pixel_tag)));
        const Order = @typeInfo(@TypeOf(Elem.initOrder)).@"fn".params[1].type.?;
        const order = std.enums.fromInt(Order, @intFromEnum(data_order)) orelse //
            return error.InvalidOrder;
        const n = data.len / bpp;
        const slice = try gpa.alloc(Elem, n);
        for (slice, 0..) |*px, i| px.* = .initOrder(data[i * bpp ..][0..bpp], order);
        return @unionInit(Pixels, @tagName(pixel_tag), slice);
    }

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            inline else => |data| gpa.free(data),
        }
    }

    pub fn dupe(self: @This(), gpa: std.mem.Allocator) !@This() {
        switch (self) {
            inline else => |data, tag| {
                const slice = try gpa.dupe(@TypeOf(data[0]), data);
                return @unionInit(Pixels, @tagName(tag), slice);
            },
        }
    }

    /// Elegant but not fast
    pub fn convert(
        self: @This(),
        tag: PixelTag,
        gpa: std.mem.Allocator,
    ) !@This() {
        switch (self) {
            inline else => |src, src_tag| {
                switch (tag) {
                    inline else => |other_tag| {
                        if (src_tag == other_tag) return self.dupe(gpa);
                        const method = comptime methodName(other_tag);
                        const len = src.len;
                        const DstElem = std.meta.Elem(@FieldType(Pixels, @tagName(other_tag)));
                        const dst = try gpa.alloc(DstElem, len);
                        errdefer gpa.free(dst);
                        for (src, dst) |s, *d| d.* = @field(@TypeOf(s), method)(s);
                        return @unionInit(Pixels, @tagName(other_tag), dst);
                    }
                }
            }
        }
    }

    pub fn convertV(
        self: @This(),
        tag: PixelTag,
        gpa: std.mem.Allocator,
        // ) !void {
    ) !@This() {
        // _ = gpa;
        switch (self) {
            inline else => |src, src_tag| {
                // _ = src;
                // std.debug.print("Len: {}\nSrc Step: {}\nSrc Len: {}\nMod: {}\n", .{ len, src_step, src_len, @mod(src_len, src_step) == 0 });
                switch (tag) {
                    inline else => |dst_tag| {
                        return if (src_tag == dst_tag) self.dupe(gpa) //
                        else convertDistinct(src_tag, dst_tag, gpa, src);
                    }
                }
            }
        }
    }

    fn convertDistinct(
        comptime src_tag: PixelTag,
        comptime dst_tag: PixelTag,
        gpa: std.mem.Allocator,
        src: []const @typeInfo(@FieldType(Pixels, @tagName(src_tag))).pointer.child,
    ) !@This() {
        comptime std.debug.assert(src_tag != dst_tag);
        const DstElem = @typeInfo(@FieldType(Pixels, @tagName(dst_tag))).pointer.child;
        const result: []DstElem = try gpa.alloc(DstElem, src.len);
        convertRow(src_tag, dst_tag, @ptrCast(src), @ptrCast(result));
        return @unionInit(Pixels, @tagName(dst_tag), result);
    }

    /// Converts the pixels in `src` (bytes of whole `src_tag` pixels) into `dst`, which
    /// holds as many `dst_tag` pixels: vector kernels on whole chunks, then the scalar
    /// conversion for the rest. Formats use it on rows of decoded pixels.
    pub fn convertRow(comptime src_tag: PixelTag, comptime dst_tag: PixelTag, src: []const u8, dst: []u8) void {
        comptime std.debug.assert(src_tag != dst_tag);
        const SrcElem = @typeInfo(@FieldType(Pixels, @tagName(src_tag))).pointer.child;
        const DstElem = @typeInfo(@FieldType(Pixels, @tagName(dst_tag))).pointer.child;
        const src_px: []const SrcElem = @ptrCast(src);
        const dst_px: []DstElem = @ptrCast(dst);
        std.debug.assert(src_px.len == dst_px.len);

        const kernel = @field(Pixels, methodVName(src_tag, dst_tag));
        const src_step = comptime src_tag.bytesPerPixel() * misc.N;
        const dst_step = comptime dst_tag.bytesPerPixel() * misc.N;
        var k: usize = 0; // pixels done
        while (k + misc.N <= src_px.len) : (k += misc.N) {
            dst[k / misc.N * dst_step ..][0..dst_step].* = kernel(src[k / misc.N * src_step ..][0..src_step]);
        }
        const method = comptime methodName(dst_tag);
        for (src_px[k..], dst_px[k..]) |s, *d| d.* = @field(SrcElem, method)(s);
    }

    fn methodVName(comptime src: PixelTag, comptime dst: PixelTag) []const u8 {
        const from = "From";
        const name1 = @tagName(src);
        const name2 = @tagName(dst);
        var buf: [name2.len + from.len + name1.len]u8 = undefined;
        @memcpy(buf[0..name2.len], name2);
        @memcpy(buf[name2.len .. name2.len + from.len], from[0..from.len]);
        @memcpy(buf[name2.len + from.len .. name2.len + from.len + name1.len], name1);
        buf[name2.len + from.len] = std.ascii.toUpper(name1[0]);
        const final = buf;
        return &final;
    }

    fn methodName(comptime dst: PixelTag) []const u8 {
        const to = "to";
        const name = @tagName(dst);
        var buf: [to.len + name.len]u8 = undefined;
        @memcpy(buf[0..to.len], to);
        @memcpy(buf[to.len .. to.len + name.len], name[0..name.len]);
        buf[to.len] = std.ascii.toUpper(name[0]);
        const final = buf;
        return &final;
    }

    inline fn splitVecs(comptime M: usize, src: *const [misc.N * M]u8) [M]U8_1 {
        // M > 1
        return simd.deinterlace(M, @as(@Vector(misc.N * M, u8), src.*));
    }

    /// `simd.permute` for one chunk of the vector kernels: output byte c of a pixel is
    /// input byte `map[c]`, or `fill[c]` where that is null.
    inline fn moveBytes(
        comptime in_bpp: usize,
        comptime out_bpp: usize,
        comptime map: [out_bpp]?u8,
        comptime fill: [out_bpp]u8,
        src: *const [misc.N * in_bpp]u8,
    ) @Vector(misc.N * out_bpp, u8) {
        return simd.permute(misc.N, in_bpp, out_bpp, map, fill, src);
    }

    /// Interlaces computed channels with an opaque alpha. A constant lane in the
    /// interlace makes LLVM store bytes one at a time, so alpha is or-ed in afterwards.
    inline fn withOpaqueAlpha(comptime bpp: usize, channels: [bpp - 1]U8_1) @Vector(misc.N * bpp, u8) {
        const alpha = comptime blk: {
            var a: [misc.N * bpp]u8 = @splat(0);
            for (0..misc.N) |p| a[p * bpp + bpp - 1] = 255;
            break :blk a;
        };
        const zero: U8_1 = @splat(0);
        return simd.interlace(channels ++ .{zero}) | @as(@Vector(misc.N * bpp, u8), alpha);
    }

    pub fn rgbFromG(src: *const [misc.N]u8) U8_3 {
        return moveBytes(1, 3, .{ 0, 0, 0 }, @splat(0), src);
    }

    pub fn bgrFromG(src: *const [misc.N]u8) U8_3 {
        return moveBytes(1, 3, .{ 0, 0, 0 }, @splat(0), src);
    }

    pub fn ycbcrFromG(src: *const [misc.N]u8) U8_3 {
        return moveBytes(1, 3, .{ 0, null, null }, .{ 0, 128, 128 }, src);
    }

    pub fn gaFromG(src: *const [misc.N]u8) U8_2 {
        return moveBytes(1, 2, .{ 0, null }, .{ 0, 255 }, src);
    }

    pub fn rgbaFromG(src: *const [misc.N]u8) U8_4 {
        return moveBytes(1, 4, .{ 0, 0, 0, null }, .{ 0, 0, 0, 255 }, src);
    }

    pub fn bgraFromG(src: *const [misc.N]u8) U8_4 {
        return moveBytes(1, 4, .{ 0, 0, 0, null }, .{ 0, 0, 0, 255 }, src);
    }

    pub fn ycbcraFromG(src: *const [misc.N]u8) U8_4 {
        return moveBytes(1, 4, .{ 0, null, null, null }, .{ 0, 128, 128, 255 }, src);
    }

    pub fn gFromRgb(src: *const [misc.N * 3]u8) U8_1 {
        const rgb = splitVecs(3, src);
        return misc.lumV(rgb[0], rgb[1], rgb[2]);
    }

    pub fn bgrFromRgb(src: *const [misc.N * 3]u8) U8_3 {
        const rgb = splitVecs(3, src);
        return simd.interlace(.{ rgb[2], rgb[1], rgb[0] });
    }

    pub fn ycbcrFromRgb(src: *const [misc.N * 3]u8) U8_3 {
        const rgb = splitVecs(3, src);
        const y = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const cb = misc.blueChromaV(rgb[0], rgb[1], rgb[2]);
        const cr = misc.redChromaV(rgb[0], rgb[1], rgb[2]);
        return simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromRgb(src: *const [misc.N * 3]u8) U8_2 {
        const rgb = splitVecs(3, src);
        return withOpaqueAlpha(2, .{misc.lumV(rgb[0], rgb[1], rgb[2])});
    }

    pub fn rgbaFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        return moveBytes(3, 4, .{ 0, 1, 2, null }, .{ 0, 0, 0, 255 }, src);
    }

    pub fn bgraFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        return moveBytes(3, 4, .{ 2, 1, 0, null }, .{ 0, 0, 0, 255 }, src);
    }

    pub fn ycbcraFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        const rgb = splitVecs(3, src);
        const y = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const cb = misc.blueChromaV(rgb[0], rgb[1], rgb[2]);
        const cr = misc.redChromaV(rgb[0], rgb[1], rgb[2]);
        return withOpaqueAlpha(4, .{ y, cb, cr });
    }

    pub fn gFromBgr(src: *const [misc.N * 3]u8) U8_1 {
        const bgr = splitVecs(3, src);
        return misc.lumV(bgr[2], bgr[1], bgr[0]);
    }

    pub fn rgbFromBgr(src: *const [misc.N * 3]u8) U8_3 {
        const bgr = splitVecs(3, src);
        return simd.interlace(.{ bgr[2], bgr[1], bgr[0] });
    }

    pub fn ycbcrFromBgr(src: *const [misc.N * 3]u8) U8_3 {
        const bgr = splitVecs(3, src);
        const y = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const cb = misc.blueChromaV(bgr[2], bgr[1], bgr[0]);
        const cr = misc.redChromaV(bgr[2], bgr[1], bgr[0]);
        return simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromBgr(src: *const [misc.N * 3]u8) U8_2 {
        const bgr = splitVecs(3, src);
        return withOpaqueAlpha(2, .{misc.lumV(bgr[2], bgr[1], bgr[0])});
    }

    pub fn rgbaFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        return moveBytes(3, 4, .{ 2, 1, 0, null }, .{ 0, 0, 0, 255 }, src);
    }

    pub fn bgraFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        return moveBytes(3, 4, .{ 0, 1, 2, null }, .{ 0, 0, 0, 255 }, src);
    }

    pub fn ycbcraFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        const bgr = splitVecs(3, src);
        const y = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const cb = misc.blueChromaV(bgr[2], bgr[1], bgr[0]);
        const cr = misc.redChromaV(bgr[2], bgr[1], bgr[0]);
        return withOpaqueAlpha(4, .{ y, cb, cr });
    }

    pub fn gFromYcbcr(src: *const [misc.N * 3]u8) U8_1 {
        return splitVecs(3, src)[0];
    }

    pub fn rgbFromYcbcr(src: *const [misc.N * 3]u8) U8_3 {
        const ycbcr = splitVecs(3, src);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        return simd.interlace(.{ r, g, b });
    }

    pub fn bgrFromYcbcr(src: *const [misc.N * 3]u8) U8_3 {
        const ycbcr = splitVecs(3, src);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        return simd.interlace(.{ b, g, r });
    }

    pub fn gaFromYcbcr(src: *const [misc.N * 3]u8) U8_2 {
        return withOpaqueAlpha(2, .{splitVecs(3, src)[0]});
    }

    pub fn rgbaFromYcbcr(src: *const [misc.N * 3]u8) U8_4 {
        const ycbcr = splitVecs(3, src);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        return withOpaqueAlpha(4, .{ r, g, b });
    }

    pub fn bgraFromYcbcr(src: *const [misc.N * 3]u8) U8_4 {
        const ycbcr = splitVecs(3, src);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        return withOpaqueAlpha(4, .{ b, g, r });
    }

    pub fn ycbcraFromYcbcr(src: *const [misc.N * 3]u8) U8_4 {
        return moveBytes(3, 4, .{ 0, 1, 2, null }, .{ 0, 0, 0, 255 }, src);
    }

    pub fn gFromGa(src: *const [misc.N * 2]u8) U8_1 {
        return splitVecs(2, src)[0];
    }

    pub fn rgbFromGa(src: *const [misc.N * 2]u8) U8_3 {
        return moveBytes(2, 3, .{ 0, 0, 0 }, @splat(0), src);
    }

    pub fn bgrFromGa(src: *const [misc.N * 2]u8) U8_3 {
        return moveBytes(2, 3, .{ 0, 0, 0 }, @splat(0), src);
    }

    pub fn ycbcrFromGa(src: *const [misc.N * 2]u8) U8_3 {
        return moveBytes(2, 3, .{ 0, null, null }, .{ 0, 128, 128 }, src);
    }

    pub fn rgbaFromGa(src: *const [misc.N * 2]u8) U8_4 {
        return moveBytes(2, 4, .{ 0, 0, 0, 1 }, @splat(0), src);
    }

    pub fn bgraFromGa(src: *const [misc.N * 2]u8) U8_4 {
        return moveBytes(2, 4, .{ 0, 0, 0, 1 }, @splat(0), src);
    }

    pub fn ycbcraFromGa(src: *const [misc.N * 2]u8) U8_4 {
        return moveBytes(2, 4, .{ 0, null, null, 1 }, .{ 0, 128, 128, 0 }, src);
    }

    pub fn gFromRgba(src: *const [misc.N * 4]u8) U8_1 {
        const rgba = splitVecs(4, src);
        return misc.lumV(rgba[0], rgba[1], rgba[2]);
    }

    pub fn rgbFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        return simd.interlace(.{ rgba[0], rgba[1], rgba[2] });
    }

    pub fn bgrFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        return simd.interlace(.{ rgba[2], rgba[1], rgba[0] });
    }

    pub fn ycbcrFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        const y = misc.lumV(rgba[0], rgba[1], rgba[2]);
        const cb = misc.blueChromaV(rgba[0], rgba[1], rgba[2]);
        const cr = misc.redChromaV(rgba[0], rgba[1], rgba[2]);
        return simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromRgba(src: *const [misc.N * 4]u8) U8_2 {
        const rgba = splitVecs(4, src);
        const g = misc.lumV(rgba[0], rgba[1], rgba[2]);
        return simd.interlace(.{ g, rgba[3] });
    }

    pub fn bgraFromRgba(src: *const [misc.N * 4]u8) U8_4 {
        return moveBytes(4, 4, .{ 2, 1, 0, 3 }, @splat(0), src);
    }

    pub fn ycbcraFromRgba(src: *const [misc.N * 4]u8) U8_4 {
        const rgba = splitVecs(4, src);
        const y = misc.lumV(rgba[0], rgba[1], rgba[2]);
        const cb = misc.blueChromaV(rgba[0], rgba[1], rgba[2]);
        const cr = misc.redChromaV(rgba[0], rgba[1], rgba[2]);
        return simd.interlace(.{ y, cb, cr, rgba[3] });
    }

    pub fn gFromBgra(src: *const [misc.N * 4]u8) U8_1 {
        const bgra = splitVecs(4, src);
        return misc.lumV(bgra[2], bgra[1], bgra[0]);
    }

    pub fn rgbFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        return simd.interlace(.{ bgra[2], bgra[1], bgra[0] });
    }

    pub fn bgrFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        return simd.interlace(.{ bgra[0], bgra[1], bgra[2] });
    }

    pub fn ycbcrFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        const y = misc.lumV(bgra[2], bgra[1], bgra[0]);
        const cb = misc.blueChromaV(bgra[2], bgra[1], bgra[0]);
        const cr = misc.redChromaV(bgra[2], bgra[1], bgra[0]);
        return simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromBgra(src: *const [misc.N * 4]u8) U8_2 {
        const bgra = splitVecs(4, src);
        const g = misc.lumV(bgra[2], bgra[1], bgra[0]);
        return simd.interlace(.{ g, bgra[3] });
    }

    pub fn rgbaFromBgra(src: *const [misc.N * 4]u8) U8_4 {
        return moveBytes(4, 4, .{ 2, 1, 0, 3 }, @splat(0), src);
    }

    pub fn ycbcraFromBgra(src: *const [misc.N * 4]u8) U8_4 {
        const bgra = splitVecs(4, src);
        const y = misc.lumV(bgra[2], bgra[1], bgra[0]);
        const cb = misc.blueChromaV(bgra[2], bgra[1], bgra[0]);
        const cr = misc.redChromaV(bgra[2], bgra[1], bgra[0]);
        return simd.interlace(.{ y, cb, cr, bgra[3] });
    }

    pub fn gFromYcbcra(src: *const [misc.N * 4]u8) U8_1 {
        return splitVecs(4, src)[0];
    }

    pub fn rgbFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        const r = misc.redV(ycbcra[0], ycbcra[2]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const b = misc.blueV(ycbcra[0], ycbcra[1]);
        return simd.interlace(.{ r, g, b });
    }

    pub fn bgrFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        const b = misc.blueV(ycbcra[0], ycbcra[1]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const r = misc.redV(ycbcra[0], ycbcra[2]);
        return simd.interlace(.{ b, g, r });
    }

    pub fn ycbcrFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        return simd.interlace(.{ ycbcra[0], ycbcra[1], ycbcra[2] });
    }

    pub fn gaFromYcbcra(src: *const [misc.N * 4]u8) U8_2 {
        const ycbcra = splitVecs(4, src);
        return simd.interlace(.{ ycbcra[0], ycbcra[3] });
    }

    pub fn rgbaFromYcbcra(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcra = splitVecs(4, src);
        const r = misc.redV(ycbcra[0], ycbcra[2]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const b = misc.blueV(ycbcra[0], ycbcra[1]);
        return simd.interlace(.{ r, g, b, ycbcra[3] });
    }

    pub fn bgraFromYcbcra(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcra = splitVecs(4, src);
        const b = misc.blueV(ycbcra[0], ycbcra[1]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const r = misc.redV(ycbcra[0], ycbcra[2]);
        return simd.interlace(.{ b, g, r, ycbcra[3] });
    }
};

test "Pixels" {
    const gpa = std.testing.allocator;
    var data = [_]u8{ // 3 * 4 * 8 = fits reqs: > 64, mult of 12, tests all tags, short enough for vectors to be too slow
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
    };

    var data2 = [_]u8{ // large, mult of 12, >64, long enough for vectors to matter
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,

        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
        1, 3, 7, 15, 31, 63, 127, 255,
    };

    var prng = std.Random.DefaultPrng.init(1010);
    for (0..data.len) |i| {
        data[i] = data[i] +% @as(u8, @truncate(prng.next()));
    }
    for (0..data2.len) |i| {
        data2[i] = data2[i] +% @as(u8, @truncate(prng.next()));
    }

    const io = std.testing.io;
    var clock: std.Io.Clock = .awake;

    var n1: std.Io.Timestamp = undefined;
    var n2: std.Io.Duration = undefined;
    { // computing conversion for data
        const base_pxs: Pixels = try .init(.g, gpa, &data);
        defer base_pxs.deinit(gpa);

        n1 = clock.now(io);
        const bgra2 = try base_pxs.convert(.bgra, gpa);
        defer bgra2.deinit(gpa);
        n2 = n1.untilNow(io, clock);
        const t2 = n2.nanoseconds;

        n1 = clock.now(io);
        const bgra1 = try base_pxs.convertV(.bgra, gpa); // so much work to only be slightly faster lol
        defer bgra1.deinit(gpa);
        n2 = n1.untilNow(io, clock);
        const t1 = n2.nanoseconds;
        // timing is informational only (noisy in Debug / under load)
        if (t1 >= t2) std.log.debug("convertV not faster: {} ns vs {} ns", .{ t1, t2 });
        try std.testing.expectEqualSlices(u8, bgra2.asBytes(), bgra1.asBytes());
    }

    { // computing conversion for data2
        const base_pxs: Pixels = try .init(.g, gpa, &data2);
        defer base_pxs.deinit(gpa);

        n1 = clock.now(io);
        const bgra2 = try base_pxs.convert(.bgra, gpa);
        defer bgra2.deinit(gpa);
        n2 = n1.untilNow(io, clock);
        const t2 = n2.nanoseconds;

        n1 = clock.now(io);
        const bgra1 = try base_pxs.convertV(.bgra, gpa); // so much work to only be slightly faster lol
        defer bgra1.deinit(gpa);
        n2 = n1.untilNow(io, clock);
        const t1 = n2.nanoseconds;
        // timing is informational only (noisy in Debug / under load)
        if (t1 >= t2) std.log.debug("convertV not faster: {} ns vs {} ns", .{ t1, t2 });
        try std.testing.expectEqualSlices(u8, bgra2.asBytes(), bgra1.asBytes());
    }

    const tags = [_]PixelTag{ .g, .rgb, .bgr, .ycbcr, .ga, .rgba, .bgra, .ycbcra };
    { // convert for each tag
        inline for (tags) |tag1| {
            const base1: Pixels = try .init(tag1, gpa, &data);
            defer base1.deinit(gpa);
            for (tags) |tag2| {
                const base2: Pixels = try base1.convert(tag2, gpa);
                defer base2.deinit(gpa);
            }
        }
    }

    // convertV (SIMD) must match convert (scalar) for every pair
    for ([_][]const u8{ &data, &data2 }) |bytes| {
        inline for (tags) |tag1| {
            const base1: Pixels = try .init(tag1, gpa, bytes);
            defer base1.deinit(gpa);
            for (tags) |tag2| {
                const scalar: Pixels = try base1.convert(tag2, gpa);
                defer scalar.deinit(gpa);
                const vector: Pixels = try base1.convertV(tag2, gpa);
                defer vector.deinit(gpa);
                std.testing.expectEqualSlices(u8, scalar.asBytes(), vector.asBytes()) catch |err| {
                    std.debug.print("convertV mismatch: {t} -> {t}\n", .{ tag1, tag2 });
                    return err;
                };
            }
        }
    }
}

test "convertV matches convert for every pair and pixel count" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0102);
    var bytes: [4 * 200]u8 = undefined;
    prng.random().bytes(&bytes);
    const tags = std.enums.values(PixelTag);
    // short ones (tail only), around one and several vector chunks, and odd counts
    for ([_]usize{ 1, 2, 3, 5, 15, 16, 17, 31, 32, 33, 63, 64, 65, 97, 127, 128, 129, 200 }) |n| {
        inline for (tags) |from| {
            const src: Pixels = try .init(from, gpa, bytes[0 .. n * from.bytesPerPixel()]);
            defer src.deinit(gpa);
            for (tags) |to| {
                const scalar = try src.convert(to, gpa);
                defer scalar.deinit(gpa);
                const vector = try src.convertV(to, gpa);
                defer vector.deinit(gpa);
                std.testing.expectEqualSlices(u8, scalar.asBytes(), vector.asBytes()) catch |err| {
                    std.debug.print("convertV mismatch: {t} -> {t}, {} pixels\n", .{ from, to, n });
                    return err;
                };
            }
        }
    }
}
