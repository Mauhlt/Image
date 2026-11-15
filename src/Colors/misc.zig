const std = @import("std");

/// SIMD tuning width in bytes (u8 lanes): the target's suggested vector length, or the
/// `-Dvector-bytes` build option. Kernels whose width is only a performance choice
/// derive it from this; widths the algorithm dictates stay literal.
pub const N: usize = switch (@import("build_options").vector_bytes) {
    0 => std.simd.suggestVectorLength(u8) orelse 64,
    else => |n| n,
};
comptime {
    if (N < 16 or !std.math.isPowerOfTwo(N)) @compileError("vector width must be a power of two >= 16 bytes");
}
const U8 = @Vector(N, u8); // based on NI
const T: type = i32;
const TV: type = @Vector(N, T);

const U16 = @Vector(N, u16);
const U32 = @Vector(N, u32);

/// 16-bit gray -> 8 bits: round(v / 257) = round(v * 255 / 65535), exactly, so
/// `to8(from8(x)) == x`. (t - t / 256) / 256 with t = v + 128 is that quotient
/// without a division (checked against it for all 65536 inputs in the tests).
pub fn to8(v: u16) u8 {
    const t: u32 = @as(u32, v) + 128;
    return @intCast((t - (t >> 8)) >> 8);
}

/// 8-bit gray -> 16 bits: v * 257 (0 -> 0, 255 -> 65535; both bytes = v).
pub fn from8(v: u8) u16 {
    return @as(u16, v) * 257;
}

/// `to8` on N samples (u32 lanes: t reaches 65663).
pub fn to8V(v: U16) U8 {
    const t = @as(U32, v) + @as(U32, @splat(128));
    return @intCast((t - (t >> @splat(8))) >> @splat(8));
}

/// `from8` on N samples.
pub fn from8V(v: U8) U16 {
    return @as(U16, v) * @as(U16, @splat(257));
}

inline fn clamp(v: T) u8 {
    return @intCast(@min(@max(@as(T, @intCast(v)), @as(T, 0)), @as(T, 255)));
}

inline fn clampV(v: TV) U8 {
    return @intCast(@min(@max(@as(TV, @intCast(v)), @as(TV, @splat(0))), @as(TV, @splat(255))));
}

pub fn red(y: u8, cr: u8) u8 {
    const yi: T = @intCast(y);
    const cri: T = @intCast(cr);
    return clamp(yi + ((@as(T, 91881) * (cri - @as(T, 128)) + @as(T, 32768)) >> @as(T, 16)));
}

pub fn blue(y: u8, cb: u8) u8 {
    const yi: T = @intCast(y);
    const cbi: T = @intCast(cb);
    return clamp(yi + ((@as(T, 116130) * (cbi - @as(T, 128)) + @as(T, 32768)) >> @as(T, 16)));
}

pub fn green(y: u8, cb: u8, cr: u8) u8 {
    const yi: T = @intCast(y);
    const cbi: T = @intCast(cb);
    const cri: T = @intCast(cr);
    return clamp(yi + ((@as(T, 32768) - @as(T, 22554) * (cbi - @as(T, 128)) - @as(T, 46802) * (cri - @as(T, 128))) >> @as(T, 16)));
}

pub fn lum(r: u8, g: u8, b: u8) u8 {
    const ri: T = @intCast(r);
    const gi: T = @intCast(g);
    const bi: T = @intCast(b);
    return clamp((@as(T, 19595) * ri + @as(T, 38470) * gi + @as(T, 7471) * bi + @as(T, 32768)) >> @as(T, 16));
}

pub fn blueChroma(r: u8, g: u8, b: u8) u8 {
    const ri: T = @intCast(r);
    const gi: T = @intCast(g);
    const bi: T = @intCast(b);
    return clamp(@as(T, 128) + ((@as(T, 32768) - @as(T, 11058) * ri - @as(T, 21710) * gi + @as(T, 32768) * bi) >> @as(T, 16)));
}

pub fn redChroma(r: u8, g: u8, b: u8) u8 {
    const ri: T = @intCast(r);
    const gi: T = @intCast(g);
    const bi: T = @intCast(b);
    return clamp(@as(T, 128) + ((@as(T, 32768) + @as(T, 32768) * ri - @as(T, 27439) * gi - @as(T, 5329) * bi) >> @as(T, 16)));
}

pub fn redV(y: U8, cr: U8) U8 {
    const yi: TV = @intCast(y);
    const cri: TV = @intCast(cr);
    return clampV(yi + ((@as(TV, @splat(91881)) * (cri - @as(TV, @splat(128))) + @as(TV, @splat(32768))) >> @as(TV, @splat(16))));
}

pub fn blueV(y: U8, cb: U8) U8 {
    const yi: TV = @intCast(y);
    const cbi: TV = @intCast(cb);
    return clampV(yi + ((@as(TV, @splat(116130)) * (cbi - @as(TV, @splat(128))) + @as(TV, @splat(32768))) >> @as(TV, @splat(16))));
}

pub fn greenV(y: U8, cb: U8, cr: U8) U8 {
    const yi: TV = @intCast(y);
    const cbi: TV = @intCast(cb);
    const cri: TV = @intCast(cr);
    return clampV(yi + ((@as(TV, @splat(32768)) - @as(TV, @splat(22554)) * (cbi - @as(TV, @splat(128))) - @as(TV, @splat(46802)) * (cri - @as(TV, @splat(128)))) >> @as(TV, @splat(16))));
}

pub fn lumV(r: U8, g: U8, b: U8) U8 {
    const ri: TV = @intCast(r);
    const gi: TV = @intCast(g);
    const bi: TV = @intCast(b);
    return clampV((@as(TV, @splat(19595)) * ri + @as(TV, @splat(38470)) * gi + @as(TV, @splat(7471)) * bi + @as(TV, @splat(32768))) >> @as(TV, @splat(16)));
}

pub fn blueChromaV(r: U8, g: U8, b: U8) U8 {
    const ri: TV = @intCast(r);
    const gi: TV = @intCast(g);
    const bi: TV = @intCast(b);
    return clampV(@as(TV, @splat(128)) + ((@as(TV, @splat(32768)) - @as(TV, @splat(11058)) * ri - @as(TV, @splat(21710)) * gi + @as(TV, @splat(32768)) * bi) >> @as(TV, @splat(16))));
}

pub fn redChromaV(r: U8, g: U8, b: U8) U8 {
    const ri: TV = @intCast(r);
    const gi: TV = @intCast(g);
    const bi: TV = @intCast(b);
    return clampV(@as(TV, @splat(128)) + ((@as(TV, @splat(32768)) + @as(TV, @splat(32768)) * ri - @as(TV, @splat(27439)) * gi - @as(TV, @splat(5329)) * bi) >> @as(TV, @splat(16))));
}
