//! BC7: 16 bytes per 4x4 RGBA block. 8 modes exist; this implements MODE 6
//! (1 subset, RGBA 7.7.7.7 endpoints + per-endpoint p-bit, 4-bit indices),
//! which handles any RGBA block well. GPUs decode every mode, so files produced
//! elsewhere still upload fine; only CPU-side decoding is limited to mode 6.
const std = @import("std");
const Block = @import("bc1.zig").Block;

pub const BLOCK_BYTES = 16;
const WEIGHTS4 = [16]u32{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

inline fn interp(e0: u8, e1: u8, w: u32) u8 {
    return @intCast(((64 - w) * e0 + w * e1 + 32) >> 6);
}

const BitWriter = struct {
    v: u128 = 0,
    pos: u8 = 0,
    fn put(self: *@This(), value: u32, n: u7) void {
        self.v |= @as(u128, value & ((@as(u32, 1) << @intCast(n)) - 1)) << @intCast(self.pos);
        self.pos += n;
    }
};

const BitReader = struct {
    v: u128,
    pos: u8 = 0,
    fn get(self: *@This(), n: u7) u32 {
        const r: u32 = @intCast((self.v >> @intCast(self.pos)) & ((@as(u128, 1) << n) - 1));
        self.pos += n;
        return r;
    }
};

pub const Error = error{UnsupportedBc7Mode};

pub fn decodeBlock(src: *const [16]u8, out: *Block) Error!void {
    var br: BitReader = .{ .v = std.mem.readInt(u128, src, .little) };
    if (@ctz(br.v) != 6) return Error.UnsupportedBc7Mode;
    br.pos = 7;
    var e: [2][4]u8 = undefined;
    for (0..4) |c| for (0..2) |k| {
        e[k][c] = @intCast(br.get(7) << 1);
    };
    const p0: u8 = @intCast(br.get(1));
    const p1: u8 = @intCast(br.get(1));
    for (0..4) |c| {
        e[0][c] |= p0;
        e[1][c] |= p1;
    }
    for (out, 0..) |*px, i| {
        const idx = br.get(if (i == 0) 3 else 4);
        for (0..4) |c| px[c] = interp(e[0][c], e[1][c], WEIGHTS4[idx]);
    }
}

fn err4(a: [4]u8, b: [4]u8) u32 {
    var d: u32 = 0;
    for (0..4) |i| {
        const x = @as(i32, a[i]) - b[i];
        d += @intCast(x * x);
    }
    return d;
}

pub fn encodeBlock(px: *const Block, out: *[16]u8) void {
    // principal axis in RGBA
    var mean: [4]f32 = @splat(0);
    for (px) |p| for (0..4) |c| {
        mean[c] += @floatFromInt(p[c]);
    };
    for (&mean) |*m| m.* /= 16;
    var cov: [4][4]f32 = @splat(@splat(0));
    for (px) |p| {
        var d: [4]f32 = undefined;
        for (0..4) |c| d[c] = @as(f32, @floatFromInt(p[c])) - mean[c];
        for (0..4) |r| for (0..4) |c| {
            cov[r][c] += d[r] * d[c];
        };
    }
    // seed with the covariance column of the highest-variance channel (see bc1.zig)
    const diag = [4]f32{ cov[0][0], cov[1][1], cov[2][2], cov[3][3] };
    const kmax = std.mem.indexOfMax(f32, &diag);
    var axis: [4]f32 = cov[kmax];
    if (diag[kmax] < 1e-6) axis = .{ 1, 1, 1, 1 };
    for (0..8) |_| {
        var n: [4]f32 = @splat(0);
        for (0..4) |r| for (0..4) |c| {
            n[r] += cov[r][c] * axis[c];
        };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2] + n[3] * n[3]);
        if (len < 1e-6) break;
        for (0..4) |c| axis[c] = n[c] / len;
    }
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    for (px) |p| {
        var t: f32 = 0;
        for (0..4) |c| t += (@as(f32, @floatFromInt(p[c])) - mean[c]) * axis[c];
        lo = @min(lo, t);
        hi = @max(hi, t);
    }

    // try each p-bit pair, keep the lowest error
    var best_err: u32 = std.math.maxInt(u32);
    var best: [16]u8 = undefined;
    for (0..4) |pbits| {
        const p = [2]u8{ @intCast(pbits & 1), @intCast(pbits >> 1) };
        var q: [2][4]u8 = undefined; // 7-bit values
        var e: [2][4]u8 = undefined; // expanded 8-bit endpoints
        for (0..4) |c| {
            const ends = [2]f32{ mean[c] + axis[c] * lo, mean[c] + axis[c] * hi };
            for (0..2) |k| {
                const v = std.math.clamp((ends[k] - @as(f32, @floatFromInt(p[k]))) / 2.0, 0, 127);
                q[k][c] = @intFromFloat(@round(v));
                e[k][c] = (q[k][c] << 1) | p[k];
            }
        }
        var pal: [16][4]u8 = undefined;
        for (&pal, WEIGHTS4) |*c, w| for (0..4) |ch| {
            c[ch] = interp(e[0][ch], e[1][ch], w);
        };
        var idx: [16]u8 = undefined;
        var total: u32 = 0;
        for (px, &idx) |pxl, *ix| {
            var bd: u32 = std.math.maxInt(u32);
            for (pal, 0..) |c, j| {
                const d = err4(pxl, c);
                if (d < bd) {
                    bd = d;
                    ix.* = @intCast(j);
                }
            }
            total += bd;
        }
        if (total >= best_err) continue;
        best_err = total;

        // anchor index (pixel 0) must have MSB 0: swap endpoints if needed
        var ep = q;
        var pb = p;
        if (idx[0] >= 8) {
            std.mem.swap([4]u8, &ep[0], &ep[1]);
            std.mem.swap(u8, &pb[0], &pb[1]);
            for (&idx) |*ix| ix.* = 15 - ix.*;
        }
        var bw: BitWriter = .{};
        bw.put(1 << 6, 7); // mode 6
        for (0..4) |c| for (0..2) |k| bw.put(ep[k][c], 7);
        bw.put(pb[0], 1);
        bw.put(pb[1], 1);
        for (idx, 0..) |ix, i| bw.put(ix, if (i == 0) 3 else 4);
        std.debug.assert(bw.pos == 128);
        std.mem.writeInt(u128, &best, bw.v, .little);
    }
    out.* = best;
}

test "bc7 mode 6 round trip" {
    var px: Block = undefined;
    for (&px, 0..) |*p, i| p.* = .{ @intCast(i * 15), 80, @intCast(255 - i * 15), @intCast(i * 16) };
    var blk: [16]u8 = undefined;
    encodeBlock(&px, &blk);
    var out: Block = undefined;
    try decodeBlock(&blk, &out);
    for (px, out) |a, b| for (0..4) |c| try std.testing.expect(@abs(@as(i32, a[c]) - b[c]) <= 6);
}
