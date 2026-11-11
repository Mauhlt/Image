//! BC1 (DXT1): 8 bytes per 4x4 block. Two RGB565 endpoints + 2-bit indices.
//! Encoder: principal-axis endpoint fit, then nearest-of-4 index selection.
const std = @import("std");

pub const BLOCK_BYTES = 8;
pub const Block = [16][4]u8; // RGBA, row-major

pub fn to565(c: [3]f32) u16 {
    const r: u16 = @intFromFloat(@round(std.math.clamp(c[0], 0, 255) * 31.0 / 255.0));
    const g: u16 = @intFromFloat(@round(std.math.clamp(c[1], 0, 255) * 63.0 / 255.0));
    const b: u16 = @intFromFloat(@round(std.math.clamp(c[2], 0, 255) * 31.0 / 255.0));
    return (r << 11) | (g << 5) | b;
}

pub fn from565(c: u16) [3]u8 {
    const r: u8 = @intCast((c >> 11) & 31);
    const g: u8 = @intCast((c >> 5) & 63);
    const b: u8 = @intCast(c & 31);
    return .{ (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2) };
}

/// 4-entry palette; `four_color` = (c0 > c1) mode
pub fn palette(c0: u16, c1: u16, four_color: bool) [4][4]u8 {
    const a = from565(c0);
    const b = from565(c1);
    var p: [4][4]u8 = undefined;
    p[0] = .{ a[0], a[1], a[2], 255 };
    p[1] = .{ b[0], b[1], b[2], 255 };
    for (0..3) |i| {
        const x: u16 = a[i];
        const y: u16 = b[i];
        if (four_color) {
            p[2][i] = @intCast((2 * x + y) / 3);
            p[3][i] = @intCast((x + 2 * y) / 3);
        } else {
            p[2][i] = @intCast((x + y) / 2);
            p[3][i] = 0;
        }
    }
    p[2][3] = 255;
    p[3][3] = if (four_color) 255 else 0;
    return p;
}

pub fn decodeBlock(src: *const [8]u8, out: *Block) void {
    const c0 = std.mem.readInt(u16, src[0..2], .little);
    const c1 = std.mem.readInt(u16, src[2..4], .little);
    const idx = std.mem.readInt(u32, src[4..8], .little);
    const p = palette(c0, c1, c0 > c1);
    for (out, 0..) |*px, i| px.* = p[(idx >> @intCast(i * 2)) & 3];
}

/// Decoding for BC2/BC3 color halves: always 4-color mode.
pub fn decodeColorOnly(src: *const [8]u8, out: *Block) void {
    const c0 = std.mem.readInt(u16, src[0..2], .little);
    const c1 = std.mem.readInt(u16, src[2..4], .little);
    const idx = std.mem.readInt(u32, src[4..8], .little);
    const p = palette(c0, c1, true);
    for (out, 0..) |*px, i| {
        const c = p[(idx >> @intCast(i * 2)) & 3];
        px[0..3].* = c[0..3].*;
    }
}

fn dist2(a: [4]u8, b: [4]u8) u32 {
    var d: u32 = 0;
    for (0..3) |i| {
        const x = @as(i32, a[i]) - b[i];
        d += @intCast(x * x);
    }
    return d;
}

/// Encodes RGB (alpha ignored) in 4-color mode.
pub fn encodeBlock(px: *const Block, out: *[8]u8) void {
    // mean + principal axis (power iteration on the covariance)
    var mean: [3]f32 = @splat(0);
    for (px) |p| for (0..3) |i| {
        mean[i] += @floatFromInt(p[i]);
    };
    for (&mean) |*m| m.* /= 16;
    var cov: [6]f32 = @splat(0); // rr rg rb gg gb bb
    for (px) |p| {
        const r = @as(f32, @floatFromInt(p[0])) - mean[0];
        const g = @as(f32, @floatFromInt(p[1])) - mean[1];
        const b = @as(f32, @floatFromInt(p[2])) - mean[2];
        cov[0] += r * r;
        cov[1] += r * g;
        cov[2] += r * b;
        cov[3] += g * g;
        cov[4] += g * b;
        cov[5] += b * b;
    }
    // seed with the covariance column of the highest-variance channel: a fixed seed
    // like (1,1,1) can be orthogonal to the principal axis and never converge
    const diag = [3]f32{ cov[0], cov[3], cov[5] };
    const k = std.mem.indexOfMax(f32, &diag);
    var axis: [3]f32 = switch (k) {
        0 => .{ cov[0], cov[1], cov[2] },
        1 => .{ cov[1], cov[3], cov[4] },
        else => .{ cov[2], cov[4], cov[5] },
    };
    if (diag[k] < 1e-6) axis = .{ 1, 1, 1 };
    for (0..8) |_| {
        const x = cov[0] * axis[0] + cov[1] * axis[1] + cov[2] * axis[2];
        const y = cov[1] * axis[0] + cov[3] * axis[1] + cov[4] * axis[2];
        const z = cov[2] * axis[0] + cov[4] * axis[1] + cov[5] * axis[2];
        const len = @sqrt(x * x + y * y + z * z);
        if (len < 1e-6) break;
        axis = .{ x / len, y / len, z / len };
    }
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    for (px) |p| {
        var t: f32 = 0;
        for (0..3) |i| t += (@as(f32, @floatFromInt(p[i])) - mean[i]) * axis[i];
        lo = @min(lo, t);
        hi = @max(hi, t);
    }
    var e0: [3]f32 = undefined;
    var e1: [3]f32 = undefined;
    for (0..3) |i| {
        e0[i] = mean[i] + axis[i] * hi;
        e1[i] = mean[i] + axis[i] * lo;
    }
    var c0 = to565(e0);
    var c1 = to565(e1);
    if (c0 < c1) std.mem.swap(u16, &c0, &c1);

    var indices: u32 = 0;
    if (c0 != c1) {
        const p = palette(c0, c1, true);
        for (px, 0..) |q, i| {
            var best: u32 = 0;
            var best_d: u32 = std.math.maxInt(u32);
            for (p, 0..) |c, j| {
                const d = dist2(q, c);
                if (d < best_d) {
                    best_d = d;
                    best = @intCast(j);
                }
            }
            indices |= best << @intCast(i * 2);
        }
    }
    std.mem.writeInt(u16, out[0..2], c0, .little);
    std.mem.writeInt(u16, out[2..4], c1, .little);
    std.mem.writeInt(u32, out[4..8], indices, .little);
}

test "bc1 solid + gradient" {
    var px: Block = undefined;
    for (&px) |*p| p.* = .{ 200, 100, 50, 255 };
    var blk: [8]u8 = undefined;
    encodeBlock(&px, &blk);
    var out: Block = undefined;
    decodeBlock(&blk, &out);
    for (out) |p| for (0..3) |i| try std.testing.expect(@abs(@as(i32, p[i]) - px[0][i]) <= 4);

    for (&px, 0..) |*p, i| p.* = .{ @intCast(i * 16), @intCast(255 - i * 16), 128, 255 };
    encodeBlock(&px, &blk);
    decodeBlock(&blk, &out);
    // 16 evenly spaced values -> 4 palette levels 80 apart: worst case ~40 per channel
    for (out, px) |a, b| for (0..3) |i| try std.testing.expect(@abs(@as(i32, a[i]) - b[i]) <= 44);
}
