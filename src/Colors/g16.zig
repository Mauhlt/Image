const std = @import("std");
const misc = @import("misc.zig");

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

/// 16-bit gray, native endian. `align(1)` keeps every pixel struct byte-aligned, so
/// `Pixels.fromBytes` can view any byte slice (e.g. inside a `Batch`) as `[]G16`.
/// To the 8-bit layouts: round(v / 257), see `misc.to8`; from them: v * 257.
pub const G16 = extern struct {
    g: u16 align(1),

    pub fn init(data: u16) G16 {
        return .{ .g = data };
    }

    pub fn toG(self: G16) G {
        return .{ .g = misc.to8(self.g) };
    }

    pub fn toRgb(self: G16) RGB {
        return self.toG().toRgb();
    }

    pub fn toBgr(self: G16) BGR {
        return self.toG().toBgr();
    }

    pub fn toYcbcr(self: G16) YCbCr {
        return self.toG().toYcbcr();
    }

    pub fn toGa(self: G16) GA {
        return self.toG().toGa();
    }

    pub fn toRgba(self: G16) RGBA {
        return self.toG().toRgba();
    }

    pub fn toBgra(self: G16) BGRA {
        return self.toG().toBgra();
    }

    pub fn toYcbcra(self: G16) YCbCrA {
        return self.toG().toYcbcra();
    }

    pub fn eql(self: G16, other: G16) bool {
        return self.g == other.g;
    }
};

test "G16" {
    try std.testing.expectEqual(1, @alignOf(G16));
    try std.testing.expectEqual(2, @sizeOf(G16));
    const g: G16 = .init(65535);
    try std.testing.expectEqualDeep(RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 }, g.toRgba());
    try std.testing.expectEqual(@as(u8, 0), G16.init(128).toG().g); // 128 / 257 = 0.498
    try std.testing.expectEqual(@as(u8, 1), G16.init(129).toG().g);
    try std.testing.expectEqual(@as(u16, 0x8080), (G{ .g = 0x80 }).toG16().g);
    try std.testing.expect(g.eql(g));
}

test "to8 is round(v / 257) for every sample, and inverts from8" {
    var v: u32 = 0;
    while (v <= 0xFFFF) : (v += 1) {
        try std.testing.expectEqual(@as(u8, @intCast((v * 255 + 32767) / 65535)), misc.to8(@intCast(v)));
    }
    for (0..256) |x| try std.testing.expectEqual(@as(u8, @intCast(x)), misc.to8(misc.from8(@intCast(x))));
}
