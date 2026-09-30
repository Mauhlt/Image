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
const U8_1 = @Vector(misc.N, u8);
const U8_2 = @Vector(misc.N * 2, u8);
const U8_3 = @Vector(misc.N * 3, u8);
const U8_4 = @Vector(misc.N * 4, u8);
const I16 = @Vector(misc.N, u16);

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
        if (@mod(data.len, pixel_tag.alignOf()) != 0 or data.len == 0) return error.InvalidDataLength;
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
        comptime other_tag: PixelTag,
        gpa: std.mem.Allocator,
    ) !@This() {
        const method = @tagName(other_tag);
        switch (self) {
            inline else => |src, tag| {
                if (tag == other_tag) return self.dupe(gpa);
                const len = src.len;
                const DstElem = std.meta.Elem(@FieldType(Pixels, @tagName(other_tag)));
                const dst = try gpa.alloc(DstElem, len);
                errdefer gpa.free(dst);
                for (src, dst) |s, *d| d.* = @field(@TypeOf(s), method)(s);
                return @unionInit(Pixels, @tagName(other_tag), dst);
            }
        }
    }

    pub fn convertV(
        self: @This(),
        tag: PixelTag,
        gpa: std.mem.Allocator,
    ) !void { // @This() {
        _ = gpa;
        switch (self) {
            inline else => |src, src_tag| {
                _ = src;
                // const len = src.len;
                // const srcV: []const u8 = @ptrCast(src);
                // const src_step = comptime src_tag.alignOf() * misc.N;
                // const src_len = srcV.len;
                switch (tag) {
                    inline else => |dst_tag| {
                        // if (src_tag == dst_tag) return self.dupe(gpa);

                        const methodV = comptime methodVName(src_tag, dst_tag);
                        const method = comptime methodName(dst_tag);
                        std.debug.print(
                            "Src: {t}\nDst: {t}\nMethodV: {s}\nMethod: {s}\n",
                            .{ src_tag, dst_tag, methodV, method },
                        );

                        // const Elem = @typeInfo(@FieldType(Pixels, @tagName(dst_tag))).pointer.child;
                        // const result: []Elem = try gpa.alloc(Elem, len);
                        // errdefer gpa.free(result);

                        // const dstV: []u8 = @ptrCast(result);
                        // const dst_step = comptime dst_tag.alignOf() * misc.N;
                        // const dst_len = dstV.len;

                        // var i: usize = 0; // src as u8s
                        // var j: usize = 0; // dst as u8s
                        // while ((i + src_step) < src_len and (j + dst_step) < dst_len) : ({
                        //     i += src_len;
                        //     j += dst_len;
                        // }) {
                        //     dstV[j..][0..dst_step].* = @field(Pixels, methodV)(srcV[i..][0..src_step]);
                        // }
                        //
                        // i /= src_step; // in original form
                        // j /= dst_step; // in orginal form
                        // while (i < src_len and j < dst_len) : ({
                        //     i += 1;
                        //     j += 1;
                        // }) {
                        //     dstV[j] = @field(Pixels, method)(src[i]);
                        // }

                        // return @unionInit(Pixels, @tagName(dst_tag), result);
                    }
                }
            }
        }
    }

    fn methodVName(comptime src: PixelTag, comptime dst: PixelTag) []const u8 {
        // rgbFromG
        const from = "From";
        const name1 = @tagName(src);
        const name2 = @tagName(dst);
        var buf: [name1.len + from.len + name2.len]u8 = undefined;
        @memcpy(buf[0..name1.len], name1);
        @memcpy(buf[name1.len .. name1.len + from.len], from[0..from.len]);
        @memcpy(buf[name1.len + from.len .. name1.len + from.len + name2.len], name2);
        buf[name1.len + from.len] = std.ascii.toUpper(name2[0]);
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
        return if (M == 1) @as(U8_1, src.*) else //
        std.simd.deinterlace(M, @as(@Vector(misc.N * M, u8), src.*));
    }

    fn rgbFromG(src: *const [misc.N]u8) U8_3 {
        const g = splitVecs(1, src);
        return std.simd.interlace(.{ g, g, g });
    }

    fn bgrFromG(src: *const [misc.N]u8) U8_3 {
        const g = splitVecs(1, src);
        return std.simd.interlace(.{ g, g, g });
    }

    fn ycbcrFromG(src: *const [misc.N]u8) U8_3 {
        const g = splitVecs(1, src);
        const c: U8_1 = @splat(128);
        return std.simd.interlace(.{ g, c, c });
    }

    fn gaFromG(src: *const [misc.N]u8) U8_2 {
        const g = splitVecs(1, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, a });
    }

    fn rgbaFromG(src: *const [misc.N]u8) U8_4 {
        const g = splitVecs(1, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, g, g, a });
    }

    fn bgraFromG(src: *const [misc.N]u8) U8_4 {
        const g = splitVecs(1, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, g, g, a });
    }

    fn ycbcraFromG(src: *const [misc.N]u8) U8_4 {
        const g = splitVecs(1, src);
        const c: U8_1 = @splat(128);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, c, c, a });
    }

    fn gFromRgb(src: *const [misc.N * 3]u8) U8_1 {
        const rgb = splitVecs(3, src);
        return misc.lumV(rgb[0], rgb[1], rgb[2]);
    }

    fn bgrFromRgb(src: *const [misc.N * 3]u8) U8_3 {
        const rgb = splitVecs(3, src);
        return std.simd.interlace(.{ rgb[2], rgb[1], rgb[0] });
    }

    fn ycbcrFromRgb(src: *const [misc.N * 3]u8) U8_3 {
        const rgb = splitVecs(3, src);
        const y = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const cb = misc.blueChromaV(rgb[0], rgb[1], rgb[2]);
        const cr = misc.redChromaV(rgb[0], rgb[1], rgb[2]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    fn gaFromRgb(src: *const [misc.N * 3]u8) U8_2 {
        const rgb = splitVecs(3, src);
        const g = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, a });
    }

    fn rgbaFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        const rgb = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ rgb[0], rgb[1], rgb[2], a });
    }

    fn bgraFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        const rgb = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ rgb[2], rgb[1], rgb[0], a });
    }

    fn ycbcraFromRgb(src: *const [misc.N * 3]u8) U8_4 {
        const rgb = splitVecs(3, src);
        const y = misc.lumV(rgb[0], rgb[1], rgb[2]);
        const cb = misc.blueChromaV(rgb[0], rgb[1], rgb[2]);
        const cr = misc.redChromaV(rgb[0], rgb[1], rgb[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ y, cb, cr, a });
    }

    fn gFromBgr(src: *const [misc.N]u8) U8_1 {
        const bgr = splitVecs(3, src);
        return misc.lumV(bgr[2], bgr[1], bgr[0]);
    }

    fn rgbFromBgr(src: *const [misc.N]u8) U8_3 {
        const bgr = splitVecs(3, src);
        return std.simd.interlace(.{ bgr[2], bgr[1], bgr[0] });
    }

    fn ycbcrFromBgr(src: *const [misc.N * 3]u8) U8_3 {
        const bgr = splitVecs(3, src);
        const y = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const cb = misc.blueChromaV(bgr[2], bgr[1], bgr[0]);
        const cr = misc.redChromaV(bgr[2], bgr[1], bgr[0]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    fn gaFromBgr(src: *const [misc.N * 2]u8) U8_2 {
        const bgr = splitVecs(3, src);
        const g = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, a });
    }

    fn rgbaFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        const bgr = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ bgr[2], bgr[1], bgr[0], a });
    }

    fn bgraFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        const bgr = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ bgr[0], bgr[1], bgr[2], a });
    }

    fn ycbcraFromBgr(src: *const [misc.N * 3]u8) U8_4 {
        const bgr = splitVecs(3, src);
        const y = misc.lumV(bgr[2], bgr[1], bgr[0]);
        const cb = misc.blueChromaV(bgr[2], bgr[1], bgr[0]);
        const cr = misc.redChromaV(bgr[2], bgr[1], bgr[0]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ y, cb, cr, a });
    }

    fn gFromYcbcr(src: *const [misc.N * 3]u8) U8_1 {
        const ycbcr = splitVecs(3, src);
        return ycbcr[0];
    }

    fn rgbFromYcbcr(src: *const [misc.N * 3]u8) U8_3 {
        const ycbcr = splitVecs(3, src);
        const r = misc.redV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const b = misc.blueV(ycbcr[0], ycbcr[1], ycbcr[2]);
        return std.simd.interlace(.{ r, g, b });
    }

    fn bgrFromYcbcr(src: *const [misc.N * 3]u8) U8_3 {
        const ycbcr = splitVecs(3, src);
        const b = misc.blueV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const r = misc.redV(ycbcr[0], ycbcr[1], ycbcr[2]);
        return std.simd.interlace(.{ b, g, r });
    }

    fn gaFromYcbcr(src: *const [misc.N * 3]u8) U8_2 {
        const ycbcr = splitVecs(3, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ ycbcr[0], a });
    }

    fn rgbaFromYcbcr(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcr = splitVecs(3, src);
        const r = misc.redV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const b = misc.blueV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ r, g, b, a });
    }

    fn bgraFromYcbcr(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcr = splitVecs(3, src);
        const b = misc.blueV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const g = misc.greenV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const r = misc.redV(ycbcr[0], ycbcr[1], ycbcr[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ b, g, r, a });
    }

    fn gFromGa(src: *const [misc.N * 2]u8) U8_1 {
        const ga = splitVecs(2, src);
        return ga[0];
    }

    fn rgbFromGa(src: *const [misc.N * 2]u8) U8_3 {
        const ga = splitVecs(2, src);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0] });
    }

    fn bgrFromGa(src: *const [misc.N * 2]u8) U8_3 {
        const ga = splitVecs(2, src);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0] });
    }

    fn ycbcrFromGa(src: *const [misc.N * 2]u8) U8_3 {
        const ga = splitVecs(2, src);
        const mid: U8_1 = @splat(128);
        return std.simd.interlace(.{ ga[0], mid, mid });
    }

    fn rgbaFromGa(src: *const [misc.N * 2]u8) U8_4 {
        const ga = splitVecs(2, src);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0], a });
    }

    fn bgraFromGa(src: *const [misc.N * 2]u8) U8_4 {
        const ga = splitVecs(2, src);
        return std.simd.interlace(.{ ga[0], ga[0], ga[0], ga[1] });
    }

    fn ycbcraFromGa(src: *const [misc.N * 2]u8) U8_4 {
        const ga = splitVecs(2, src);
        const mid: U8_1 = @splat(128);
        return std.simd.interlace(.{ ga[0], mid, mid, ga[1] });
    }

    fn gFromRgba(src: *const [misc.N * 4]u8) U8_1 {
        const rgba = splitVecs(4, src);
        return misc.lumV(rgba[0], rgba[1], rgba[2]);
    }

    fn rgbFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        return std.simd.interlace(.{ rgba[0], rgba[1], rgba[2] });
    }

    fn bgrFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        return std.simd.interlace(.{ rgba[2], rgba[1], rgba[0] });
    }

    fn ycbcrFromRgba(src: *const [misc.N * 4]u8) U8_3 {
        const rgba = splitVecs(4, src);
        const y = misc.lumV(rgba[0], rgba[1], rgba[2]);
        const cb = misc.blueChromaV(rgba[0], rgba[1], rgba[2]);
        const cr = misc.redChromaV(rgba[0], rgba[1], rgba[2]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    fn gaFromRgba(src: *const [misc.N * 4]u8) U8_2 {
        const rgba = splitVecs(4, src);
        const g = misc.lum(rgba[0], rgba[1], rgba[2]);
        const a: U8_1 = @splat(255);
        return std.simd.interlace(.{ g, a });
    }

    fn bgraFromRgba(src: *const [misc.N * 4]u8) U8_4 {
        const rgba = splitVecs(4, src);
        return std.simd.interlace(.{ rgba[2], rgba[1], rgba[0], rgba[3] });
    }

    fn ycbcraFromRgba(src: *const [misc.N * 4]u8) U8_4 {
        const rgba = splitVecs(4, src);
        const y = misc.lumV(rgba[0], rgba[1], rgba[2]);
        const cb = misc.blueChromaV(rgba[0], rgba[1], rgba[2]);
        const cr = misc.redChromaV(rgba[0], rgba[1], rgba[2]);
        return std.simd.interlace(.{ y, cb, cr, rgba[3] });
    }

    fn gFromBgra(src: *const [misc.N * 4]u8) U8_1 {
        const bgra = splitVecs(4, src);
        return misc.lumV(bgra[2], bgra[1], bgra[0]);
    }

    fn rgbFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        return std.simd.interlace(.{ bgra[2], bgra[1], bgra[0] });
    }

    fn bgrFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        return std.simd.interlace(.{ bgra[0], bgra[1], bgra[2] });
    }

    fn ycbcrFromBgra(src: *const [misc.N * 4]u8) U8_3 {
        const bgra = splitVecs(4, src);
        const y = misc.lumV(bgra[2], bgra[1], bgra[0]);
        const cb = misc.blueChromaV(bgra[2], bgra[1], bgra[0]);
        const cr = misc.redChromaV(bgra[2], bgra[1], bgra[0]);
        return std.simd.interlace(.{ y, cb, cr });
    }

    fn gaFromBgra(src: *const [misc.N * 4]u8) U8_2 {
        const bgra = splitVecs(4, src);
        const g = misc.lumV(bgra[2], bgra[1], bgra[0]);
        return std.simd.interlace(.{ g, bgra[3] });
    }

    fn ycbcraFromBgra(src: *const [misc.N * 4]u8) U8_4 {
        const bgra = splitVecs(4, src);
        const y = misc.lumV(bgra[2], bgra[1], bgra[0]);
        const cb = misc.blueChromaV(bgra[2], bgra[1], bgra[0]);
        const cr = misc.redChromaV(bgra[2], bgra[1], bgra[0]);
        return std.simd.interlace(.{ y, cb, cr, bgra[3] });
    }

    fn gFromYcbcra(src: *const [misc.N * 4]u8) U8_1 {
        const ycbcra = splitVecs(4, src);
        return ycbcra[0];
    }

    fn rgbFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        const r = misc.redV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const b = misc.blueV(ycbcra[0], ycbcra[1], ycbcra[2]);
        return std.simd.interlace(.{ r, g, b });
    }

    fn bgrFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        const b = misc.blueV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const r = misc.redV(ycbcra[0], ycbcra[1], ycbcra[2]);
        return std.simd.interlace(.{ b, g, r });
    }

    fn ycbcrFromYcbcra(src: *const [misc.N * 4]u8) U8_3 {
        const ycbcra = splitVecs(4, src);
        return std.simd.interlace(.{ ycbcra[0], ycbcra[1], ycbcra[2] });
    }

    fn gaFromYcbcra(src: *const [misc.N * 4]u8) U8_2 {
        const ycbcra = splitVecs(4, src);
        return std.simd.interlace(.{ ycbcra[0], ycbcra[3] });
    }

    fn rgbaFromYcbcra(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcra = splitVecs(4, src);
        const r = misc.redV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const b = misc.blueV(ycbcra[0], ycbcra[1], ycbcra[2]);
        return std.simd.interlace(.{ r, g, b, ycbcra[3] });
    }

    fn bgraFromYcbcra(src: *const [misc.N * 4]u8) U8_4 {
        const ycbcra = splitVecs(4, src);
        const b = misc.blueV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const g = misc.greenV(ycbcra[0], ycbcra[1], ycbcra[2]);
        const r = misc.redV(ycbcra[0], ycbcra[1], ycbcra[2]);
        return std.simd.interlace(.{ b, g, r, ycbcra[0] });
    }
};

test "Pixels" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 100, 25, 75, 175, 225 };

    const base_pxs: Pixels = try .init(.g, gpa, &data);
    defer base_pxs.deinit(gpa);

    // const io = std.testing.io;
    // var clock: std.Io.Clock = .awake;
    // const t1 = clock.now(io);
    try base_pxs.convertV(.bgra, gpa);
    // const gray_pxs = try base_pxs.convertV(.bgra, gpa);
    // defer gray_pxs.deinit(gpa);
    // const t2 = t1.untilNow(io, clock);
    // std.debug.print("{any}\n", .{t2});

    // const gray_pxs2 = try base_pxs.convert(.bgra, gpa);
    // defer gray_pxs2.deinit(gpa);

    // { // grays
    //     const gray_pxs = try base_pxs.dupe(gpa);
    //     defer gray_pxs.deinit(gpa);
    //     // grays -> rgbs
    //     const rgb_pxs = try gray_pxs.convertTo(.rgbs, gpa);
    //     defer rgb_pxs.deinit(gpa);
    //     for (0..data.len) |i| {
    //         const rgb_act = rgb_pxs.rgbs[i];
    //         const rgb_exp = RGB{
    //             .red = data[i],
    //             .green = data[i],
    //             .blue = data[i],
    //         };
    //         try std.testing.expectEqualDeep(rgb_exp, rgb_act);
    //     }
    //     // grays -> rgbas
    //     const rgba_pxs = try base_pxs.convertTo(.rgbas, gpa);
    //     defer rgba_pxs.deinit(gpa);
    //     for (0..data.len) |i| {
    //         const rgba_act = rgba_pxs.rgbas[i];
    //         const rgba_exp = RGBA{
    //             .red = data[i],
    //             .green = data[i],
    //             .blue = data[i],
    //         };
    //         try std.testing.expectEqualDeep(rgba_exp, rgba_act);
    //     }
    // }
    //
    // { // rgbs
    //     const rgb_pxs = try base_pxs.convertTo(.rgbs, gpa);
    //     defer rgb_pxs.deinit(gpa);
    //     // rgbs -> grays
    //     const gray_pxs = try rgb_pxs.convertTo(.gs, gpa);
    //     defer gray_pxs.deinit(gpa);
    //     for (0..data.len) |i| {
    //         const gray_act = gray_pxs.grays[i];
    //         const gray_exp: G = .{ .gray = data[i] };
    //         try std.testing.expectEqualDeep(gray_exp, gray_act);
    //     }
    //     // rgbs -> rgbas
    //     const rgba_pxs = try rgb_pxs.convertTo(.rgbas, gpa);
    //     defer rgba_pxs.deinit(gpa);
    //     for (0..data.len) |i| {
    //         const rgba_act = rgba_pxs.rgbas[i];
    //         const rgba_exp: RGBA = .{
    //             .red = data[i],
    //             .green = data[i],
    //             .blue = data[i],
    //         };
    //         try std.testing.expectEqualDeep(rgba_exp, rgba_act);
    //     }
    // }
    //
    // { // rgbas
    //     const rgba_pxs = try base_pxs.convertTo(.rgbas, gpa);
    //     defer rgba_pxs.deinit(gpa);
    //     // rgbas -> grays
    //     const gray_pxs = try rgba_pxs.convertTo(.gs, gpa);
    //     defer gray_pxs.deinit(gpa);
    //     for (0..data.len) |i| {
    //         const gray_act = gray_pxs.grays[i];
    //         const gray_exp: G = .{ .gray = data[i] };
    //         try std.testing.expectEqual(gray_exp, gray_act);
    //     }
    //     // rgbas -> rgbs
    //     const rgb_pxs = try rgba_pxs.convertTo(.rgbs, gpa);
    //     defer rgb_pxs.deinit(gpa);
    //     for (0..data.len) |i| {
    //         const rgb_act = rgb_pxs.rgbs[i];
    //         const rgb_exp: RGB = .{
    //             .red = data[i],
    //             .green = data[i],
    //             .blue = data[i],
    //         };
    //         try std.testing.expectEqualDeep(rgb_exp, rgb_act);
    //     }
    // }
}
