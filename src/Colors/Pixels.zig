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

    fn alignOf(self: PixelTag) u16 {
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
        if (@mod(data.len, pixel_tag.alignOf()) != 0 or data.len == 0) {
            std.debug.print("Mod: {}\nLen: {}\n", .{ @mod(data.len, pixel_tag.alignOf()), data.len });
            return error.InvalidDataLength;
        }
        const T = @FieldType(Pixels, @tagName(pixel_tag));
        const slice: T = @ptrCast(try gpa.dupe(u8, data));
        const pixels = @unionInit(Pixels, @tagName(pixel_tag), slice);
        return pixels;
    }

    // Assumes data is:
    //   - correct alignment (u24 vs u32)
    pub fn initOrder(
        gpa: std.mem.Allocator,
        data: []const u8,
        data_order: OrderTag,
        pixel_order: PixelTag,
    ) !@This() {
        if (data.len == 0) return error.InvalidDataLength;
        try pixel_order.modCheck(data);
        const n_bytes_per_pixel = pixel_order.alignOf();
        const len = data.len / n_bytes_per_pixel;
        switch (pixel_order) {
            inline else => {
                const DstElem = std.meta.Elem(@FieldType(Pixels, @tagName(pixel_order)));
                const slice = try gpa.alloc(DstElem, len);
                errdefer gpa.free(slice);
                for (0..len) |i| {
                    slice[i] = .initOrder(
                        data[i * n_bytes_per_pixel ..][0..n_bytes_per_pixel],
                        @enumFromInt(@intFromEnum(data_order)),
                    );
                }
            },
        }
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

        const len = src.len;
        const methodV = comptime methodVName(src_tag, dst_tag);

        const method = comptime methodName(dst_tag);
        const SrcElem = @typeInfo(@FieldType(Pixels, @tagName(src_tag))).pointer.child;

        const DstElem = @typeInfo(@FieldType(Pixels, @tagName(dst_tag))).pointer.child;
        const result: []DstElem = try gpa.alloc(DstElem, len);
        errdefer gpa.free(result);

        const srcV: []const u8 = @ptrCast(src);
        const src_step = comptime src_tag.alignOf() * misc.N;
        const src_len = srcV.len;

        const dstV: []u8 = @ptrCast(result);
        const dst_step = comptime dst_tag.alignOf() * misc.N;
        const dst_len = dstV.len;

        var i: usize = 0; // idx into src as []const u8
        var j: usize = 0; // idx into dst as []u8
        while ((i + src_step) <= src_len and (j + dst_step) <= dst_len) : ({
            i += src_step;
            j += dst_step;
        }) {
            dstV[j..][0..dst_step].* = @field(Pixels, methodV)(srcV[i..][0..src_step]);
        }

        var k: usize = i / comptime src_tag.alignOf();
        while (k < len) : (k += 1) {
            result[k] = @field(SrcElem, method)(src[k]);
        }

        return @unionInit(Pixels, @tagName(dst_tag), result);
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
        return std.simd.deinterlace(M, @as(@Vector(misc.N * M, u8), src.*));
    }

    pub fn rgbFromG(src: *const [misc.N]u8) U8_3 {
        const g: U8_1 = src.*;
        return std.simd.interlace(.{ g, g, g });
    }

    pub fn bgrFromG(src: *const [misc.N]u8) U8_3 {
        const g: U8_1 = src.*;
        return std.simd.interlace(.{ g, g, g });
    }

    pub fn ycbcrFromG(src: *const [misc.N]u8) U8_3 {
        const g: U8_1 = src.*;
        const c: U8_1 = @splat(128);
        return std.simd.interlace(.{ g, c, c });
    }

    pub fn gaFromG(src: *const [misc.N]u8) U8_2 {
        const g: U8_1 = src.*;
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, a });
    }

    pub fn rgbaFromG(src: *const [misc.N]u8) U8_4 {
        const g: U8_1 = src.*;
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, g, g, a });
    }

    pub fn bgraFromG(src: *const [misc.N]u8) U8_4 {
        const g: U8_1 = src.*;
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, g, g, a });
    }

    pub fn ycbcraFromG(src: *const [misc.N]u8) U8_4 {
        const g: U8_1 = src.*;
        const c: U8_1 = @splat(128);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, c, c, a });
    }

    pub fn gFromRgb(src: *const [misc.N * 3]u8) U8_1 {
        const rgb = splitVecs(3, src);
        return misc.lumV(rgb[0], rgb[1], rgb[2]);
    }

    pub fn bgrFromRgb(src: *const [misc.N * 3]u8) U8_3 {
        const rgb = splitVecs(3, src);
        return std.simd.interlace(.{ rgb[2], rgb[1], rgb[0] });
    }

    pub fn ycbcrFromRgb(src: *const [misc.N * 3]u8) U8_3 {
        const rgb = splitVecs(3, src);
        const y = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const cb = misc.blueChromaV(rgb[0], rgb[1], rgb[2]);
        const cr = misc.redChromaV(rgb[0], rgb[1], rgb[2]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromRgb(src: *const [misc.N * 3]u8) U8_2 {
        const rgb = splitVecs(3, src);
        const g = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, a });
    }

    pub fn rgbaFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        const rgb = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ rgb[0], rgb[1], rgb[2], a });
    }

    pub fn bgraFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        const rgb = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ rgb[2], rgb[1], rgb[0], a });
    }

    pub fn ycbcraFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        const rgb = splitVecs(3, src);
        const y = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const cb = misc.blueChromaV(rgb[0], rgb[1], rgb[2]);
        const cr = misc.redChromaV(rgb[0], rgb[1], rgb[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ y, cb, cr, a });
    }

    pub fn gFromBgr(src: *const [misc.N * 3]u8) U8_1 {
        const bgr = splitVecs(3, src);
        return misc.lumV(bgr[2], bgr[1], bgr[0]);
    }

    pub fn rgbFromBgr(src: *const [misc.N * 3]u8) U8_3 {
        const bgr = splitVecs(3, src);
        return std.simd.interlace(.{ bgr[2], bgr[1], bgr[0] });
    }

    pub fn ycbcrFromBgr(src: *const [misc.N * 3]u8) U8_3 {
        const bgr = splitVecs(3, src);
        const y = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const cb = misc.blueChromaV(bgr[2], bgr[1], bgr[0]);
        const cr = misc.redChromaV(bgr[2], bgr[1], bgr[0]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromBgr(src: *const [misc.N * 3]u8) U8_2 {
        const bgr = splitVecs(3, src);
        const g = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, a });
    }

    pub fn rgbaFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        const bgr = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ bgr[2], bgr[1], bgr[0], a });
    }

    pub fn bgraFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        const bgr = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ bgr[0], bgr[1], bgr[2], a });
    }

    pub fn ycbcraFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        const bgr = splitVecs(3, src);
        const y = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const cb = misc.blueChromaV(bgr[2], bgr[1], bgr[0]);
        const cr = misc.redChromaV(bgr[2], bgr[1], bgr[0]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ y, cb, cr, a });
    }

    pub fn gFromYcbcr(src: *const [misc.N * 3]u8) U8_1 {
        const ycbcr = splitVecs(3, src);
        return ycbcr[0];
    }

    pub fn rgbFromYcbcr(src: *const [misc.N * 3]u8) U8_3 {
        const ycbcr = splitVecs(3, src);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        return std.simd.interlace(.{ r, g, b });
    }

    pub fn bgrFromYcbcr(src: *const [misc.N * 3]u8) U8_3 {
        const ycbcr = splitVecs(3, src);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        return std.simd.interlace(.{ b, g, r });
    }

    pub fn gaFromYcbcr(src: *const [misc.N * 3]u8) U8_2 {
        const ycbcr = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ ycbcr[0], a });
    }

    pub fn rgbaFromYcbcr(src: *const [misc.N * 3]u8) U8_4 {
        const ycbcr = splitVecs(3, src);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ r, g, b, a });
    }

    pub fn bgraFromYcbcr(src: *const [misc.N * 3]u8) U8_4 {
        const ycbcr = splitVecs(3, src);
        const b = misc.blueV(ycbcr[0], ycbcr[1]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const r = misc.redV(ycbcr[0], ycbcr[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ b, g, r, a });
    }

    pub fn ycbcraFromYcbcr(src: *const [misc.N * 3]u8) U8_4 {
        const ycbcr = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ ycbcr[0], ycbcr[1], ycbcr[2], a });
    }

    pub fn gFromGa(src: *const [misc.N * 2]u8) U8_1 {
        const ga = splitVecs(2, src);
        return ga[0];
    }

    pub fn rgbFromGa(src: *const [misc.N * 2]u8) U8_3 {
        const ga = splitVecs(2, src);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0] });
    }

    pub fn bgrFromGa(src: *const [misc.N * 2]u8) U8_3 {
        const ga = splitVecs(2, src);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0] });
    }

    pub fn ycbcrFromGa(src: *const [misc.N * 2]u8) U8_3 {
        const ga = splitVecs(2, src);
        const mid: U8_1 = @splat(128);
        return std.simd.interlace(.{ ga[0], mid, mid });
    }

    pub fn rgbaFromGa(src: *const [misc.N * 2]u8) U8_4 {
        const ga = splitVecs(2, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0], a });
    }

    pub fn bgraFromGa(src: *const [misc.N * 2]u8) U8_4 {
        const ga = splitVecs(2, src);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0], ga[1] });
    }

    pub fn ycbcraFromGa(src: *const [misc.N * 2]u8) U8_4 {
        const ga = splitVecs(2, src);
        const mid: U8_1 = @splat(128);
        return std.simd.interlace(.{ ga[0], mid, mid, ga[1] });
    }

    pub fn gFromRgba(src: *const [misc.N * 4]u8) U8_1 {
        const rgba = splitVecs(4, src);
        return misc.lumV(rgba[0], rgba[1], rgba[2]);
    }

    pub fn rgbFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        return std.simd.interlace(.{ rgba[0], rgba[1], rgba[2] });
    }

    pub fn bgrFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        return std.simd.interlace(.{ rgba[2], rgba[1], rgba[0] });
    }

    pub fn ycbcrFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        const y = misc.lumV(rgba[0], rgba[1], rgba[2]);
        const cb = misc.blueChromaV(rgba[0], rgba[1], rgba[2]);
        const cr = misc.redChromaV(rgba[0], rgba[1], rgba[2]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromRgba(src: *const [misc.N * 4]u8) U8_2 {
        const rgba = splitVecs(4, src);
        const g = misc.lumV(rgba[0], rgba[1], rgba[2]);
        return std.simd.interlace(.{ g, rgba[3] });
    }

    pub fn bgraFromRgba(src: *const [misc.N * 4]u8) U8_4 {
        const rgba = splitVecs(4, src);
        return std.simd.interlace(.{ rgba[2], rgba[1], rgba[0], rgba[3] });
    }

    pub fn ycbcraFromRgba(src: *const [misc.N * 4]u8) U8_4 {
        const rgba = splitVecs(4, src);
        const y = misc.lumV(rgba[0], rgba[1], rgba[2]);
        const cb = misc.blueChromaV(rgba[0], rgba[1], rgba[2]);
        const cr = misc.redChromaV(rgba[0], rgba[1], rgba[2]);
        return std.simd.interlace(.{ y, cb, cr, rgba[3] });
    }

    pub fn gFromBgra(src: *const [misc.N * 4]u8) U8_1 {
        const bgra = splitVecs(4, src);
        return misc.lumV(bgra[2], bgra[1], bgra[0]);
    }

    pub fn rgbFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        return std.simd.interlace(.{ bgra[2], bgra[1], bgra[0] });
    }

    pub fn bgrFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        return std.simd.interlace(.{ bgra[0], bgra[1], bgra[2] });
    }

    pub fn ycbcrFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        const y = misc.lumV(bgra[2], bgra[1], bgra[0]);
        const cb = misc.blueChromaV(bgra[2], bgra[1], bgra[0]);
        const cr = misc.redChromaV(bgra[2], bgra[1], bgra[0]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    pub fn gaFromBgra(src: *const [misc.N * 4]u8) U8_2 {
        const bgra = splitVecs(4, src);
        const g = misc.lumV(bgra[2], bgra[1], bgra[0]);
        return std.simd.interlace(.{ g, bgra[3] });
    }

    pub fn rgbaFromBgra(src: *const [misc.N * 4]u8) U8_4 {
        const bgra = splitVecs(4, src);
        return std.simd.interlace(.{ bgra[2], bgra[1], bgra[0], bgra[3] });
    }

    pub fn ycbcraFromBgra(src: *const [misc.N * 4]u8) U8_4 {
        const bgra = splitVecs(4, src);
        const y = misc.lumV(bgra[2], bgra[1], bgra[0]);
        const cb = misc.blueChromaV(bgra[2], bgra[1], bgra[0]);
        const cr = misc.redChromaV(bgra[2], bgra[1], bgra[0]);
        return std.simd.interlace(.{ y, cb, cr, bgra[3] });
    }

    pub fn gFromYcbcra(src: *const [misc.N * 4]u8) U8_1 {
        const ycbcra = splitVecs(4, src);
        return ycbcra[0];
    }

    pub fn rgbFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        const r = misc.redV(ycbcra[0], ycbcra[1]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const b = misc.blueV(ycbcra[0], ycbcra[2]);
        return std.simd.interlace(.{ r, g, b });
    }

    pub fn bgrFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        const b = misc.blueV(ycbcra[0], ycbcra[1]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const r = misc.redV(ycbcra[0], ycbcra[2]);
        return std.simd.interlace(.{ b, g, r });
    }

    pub fn ycbcrFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        return std.simd.interlace(.{ ycbcra[0], ycbcra[1], ycbcra[2] });
    }

    pub fn gaFromYcbcra(src: *const [misc.N * 4]u8) U8_2 {
        const ycbcra = splitVecs(4, src);
        return std.simd.interlace(.{ ycbcra[0], ycbcra[3] });
    }

    pub fn rgbaFromYcbcra(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcra = splitVecs(4, src);
        const r = misc.redV(ycbcra[0], ycbcra[2]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const b = misc.blueV(ycbcra[0], ycbcra[1]);
        return std.simd.interlace(.{ r, g, b, ycbcra[3] });
    }

    pub fn bgraFromYcbcra(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcra = splitVecs(4, src);
        const b = misc.blueV(ycbcra[0], ycbcra[1]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const r = misc.redV(ycbcra[0], ycbcra[2]);
        return std.simd.interlace(.{ b, g, r, ycbcra[0] });
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
        try std.testing.expect(t1 < t2);
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
        try std.testing.expect(t1 < t2);
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

    // convertV for each tag
    {
        inline for (tags) |tag1| {
            const base1: Pixels = try .init(tag1, gpa, &data);
            defer base1.deinit(gpa);
            for (tags) |tag2| {
                const base2: Pixels = try base1.convertV(tag2, gpa);
                defer base2.deinit(gpa);
            }
        }
    }
}
