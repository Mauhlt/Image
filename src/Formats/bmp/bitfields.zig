//! 16/32-bit BMP pixels: each channel is a contiguous run of bits given by a mask.
//! Channels narrower than 8 bits are rescaled with rounding, so e.g. 5-bit 31
//! becomes 255 (not 248) and 2-bit 1 becomes 85; wider ones keep their top 8 bits.
const std = @import("std");
const Error = @import("../error.zig").Error;

pub const Masks = struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32 = 0,

    /// BI_RGB 16-bit: X1R5G5B5
    pub const rgb_555: Masks = .{ .r = 0x7C00, .g = 0x03E0, .b = 0x001F };
    /// BI_RGB 32-bit: X8R8G8B8 (the top byte is unused, not alpha)
    pub const rgb_888: Masks = .{ .r = 0xFF0000, .g = 0x00FF00, .b = 0x0000FF };
};

pub const Channel = struct {
    mask: u32,
    shift: u5,
    /// for channels wider than 8 bits: how many low bits to drop
    narrow: u5,
    /// raw value -> 8 bits, used when the channel has at most 8 bits
    lut: [256]u8,

    pub fn init(mask: u32) Error!Channel {
        var c: Channel = .{ .mask = mask, .shift = 0, .narrow = 0, .lut = @splat(0) };
        if (mask == 0) return c;
        c.shift = @intCast(@ctz(mask));
        const max = mask >> c.shift;
        // a mask with holes has no meaningful scale
        if (max & (max +% 1) != 0) return Error.InvalidHeader;
        const bits = 32 - @clz(max);
        if (bits > 8) {
            // keep the top 8 bits: equal-sized input ranges per output level,
            // like Windows' decoder
            c.narrow = @intCast(bits - 8);
        } else {
            // widen by rounding v * 255 / max, so the maximum maps to 255
            for (0..max + 1) |v| c.lut[v] = @intCast((v * 255 + max / 2) / max);
        }
        return c;
    }

    pub fn get(c: *const Channel, px: u32) u8 {
        const v = (px & c.mask) >> c.shift;
        return if (c.narrow == 0) c.lut[v] else @intCast(v >> c.narrow);
    }
};

/// Channels in output (BGRA) order.
pub const Bitfields = struct {
    b: Channel,
    g: Channel,
    r: Channel,
    a: Channel,

    pub fn init(m: Masks) Error!Bitfields {
        return .{
            .b = try .init(m.b),
            .g = try .init(m.g),
            .r = try .init(m.r),
            .a = try .init(m.a),
        };
    }

    /// Unpacks one row of `width` little-endian pixels into BGR (3 bytes) or BGRA (4 bytes).
    pub fn decodeRow(
        self: *const Bitfields,
        comptime T: type,
        src: []const u8,
        dst: []u8,
        width: usize,
        out_bpp: usize,
    ) void {
        const n = @sizeOf(T);
        for (0..width) |x| {
            const px: u32 = std.mem.readInt(T, src[x * n ..][0..n], .little);
            const d = dst[x * out_bpp ..];
            d[0] = self.b.get(px);
            d[1] = self.g.get(px);
            d[2] = self.r.get(px);
            if (out_bpp == 4) d[3] = self.a.get(px);
        }
    }
};

test "bitfields scale to the full 0..255 range" {
    const c565: Bitfields = try .init(.{ .r = 0xF800, .g = 0x07E0, .b = 0x001F });
    var out: [3]u8 = undefined;
    c565.decodeRow(u16, &.{ 0xFF, 0xFF }, &out, 1, 3);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, &out);
    // r = 16/31, g = 32/63, b = 1/31
    c565.decodeRow(u16, &.{ 0x01, 0x84 }, &out, 1, 3);
    try std.testing.expectEqualSlices(u8, &.{ 8, 130, 132 }, &out);

    // narrow channels are rounded, wide ones keep their top bits
    const two: Channel = try .init(0b1100);
    try std.testing.expectEqual(@as(u8, 85), two.get(0b0100));
    try std.testing.expectEqual(@as(u8, 170), two.get(0b1000));
    const ten: Channel = try .init(0x3FF << 20);
    try std.testing.expectEqual(@as(u8, 127), ten.get(511 << 20)); // top 8 bits, not round(124.6)
    try std.testing.expectEqual(@as(u8, 255), ten.get(0x3FF << 20));

    // an absent channel reads 0
    const none: Channel = try .init(0);
    try std.testing.expectEqual(@as(u8, 0), none.get(0xFFFF_FFFF));

    try std.testing.expectError(Error.InvalidHeader, Channel.init(0b101));
}
