//! Chroma upsampling: turns rows of a (possibly subsampled) component plane into
//! full-resolution rows, matching libjpeg's "fancy" (triangle filter) upsampling.
//!
//! The reference is bilinear interpolation in f32 (`Taps`). For the common 2x
//! factors every weight is 0, 1/4 or 3/4, so those float lerps are exact and the
//! result is round(n / 16) for an integer n (n / 4 when only one axis is halved);
//! `half` computes the same n with u16 vectors, `V` samples at a time, and rounds
//! with (n + 8) >> 4 (or (n + 2) >> 2).
const std = @import("std");
const Plane = @import("jpg.zig").Plane;

/// Lanes per vector: one register of u16 (16 with AVX2, 8 with SSE/NEON, 32 with
/// AVX-512). Plane rows (`jpg.decodeInto`) and the rows handed out here are readable
/// this far past their meaningful width, so loops never need a scalar tail.
pub const V = @import("../../Colors/misc.zig").N / 2;

const U8x = @Vector(V, u8);
const U16x = @Vector(V, u16);

pub const Upsampler = struct {
    plane: Plane,
    width: usize,
    /// one full-resolution row, with slack for whole-vector stores
    row: []u8,
    mode: union(enum) {
        /// the plane is already full resolution
        full,
        /// each axis is at full or half resolution (exact integer path)
        half: struct { x: bool, y: bool, cols: []u16 },
        /// any other ratio: float bilinear taps
        taps: struct { x: ?Taps, y: ?Taps },
    },

    /// `h`/`v` are the component's sampling factors, `h_max`/`v_max` the frame's.
    pub fn init(scratch: std.mem.Allocator, plane: Plane, width: usize, height: usize, h: u8, h_max: u8, v: u8, v_max: u8) !Upsampler {
        var self: Upsampler = .{
            .plane = plane,
            .width = width,
            .row = try scratch.alloc(u8, std.mem.alignForward(usize, width, 2 * V) + 2 * V),
            .mode = .full,
        };
        if (h == h_max and v == v_max) return self;
        if ((h == h_max or 2 * h == h_max) and (v == v_max or 2 * v == v_max)) {
            // one replicated sample on each side of the plane row, plus vector slack
            const cols = try scratch.alloc(u16, std.mem.alignForward(usize, plane.w, V) + 2);
            // the slot past the vector slack is never written; keep it a valid sample
            @memset(cols, 0);
            self.mode = .{ .half = .{ .x = h != h_max, .y = v != v_max, .cols = cols } };
            return self;
        }
        self.mode = .{ .taps = .{
            .x = if (h != h_max) try .init(scratch, width, plane.w, h, h_max) else null,
            .y = if (v != v_max) try .init(scratch, height, plane.h, v, v_max) else null,
        } };
        return self;
    }

    /// Full-resolution row `y`; at least `width` bytes, readable up to a whole vector past it.
    pub fn rowAt(self: *Upsampler, y: usize) []const u8 {
        const p = self.plane;
        switch (self.mode) {
            .full => return p.data[y * p.stride ..][0 .. std.mem.alignForward(usize, self.width, V)],
            .half => |m| {
                // Vertical: 4x-scaled rows. Output row 2j+1 is 3/4 row j + 1/4 row j+1,
                // row 2j is 3/4 row j + 1/4 row j-1, clamped to the plane's real rows.
                const cols = m.cols;
                const near_y = if (m.y) y / 2 else y;
                const far_y = if (!m.y) y else if (y % 2 == 1) @min(near_y + 1, p.h - 1) else near_y -| 1;
                const near = p.data[near_y * p.stride ..];
                const far = p.data[far_y * p.stride ..];
                var x: usize = 0;
                while (x < p.w) : (x += V) {
                    const n: U16x = near[x..][0..V].*;
                    const f: U16x = far[x..][0..V].*;
                    cols[1 + x ..][0..V].* = n * @as(U16x, @splat(3)) + f;
                }
                cols[0] = cols[1];
                cols[1 + p.w] = cols[p.w];

                if (!m.x) {
                    x = 0;
                    while (x < self.width) : (x += V) {
                        const c: U16x = cols[1 + x ..][0..V].*;
                        const out: U8x = @intCast((c + @as(U16x, @splat(2))) >> @splat(2));
                        self.row[x..][0..V].* = out;
                    }
                    return self.row;
                }
                // Horizontal: output 2i is 3/4 col i + 1/4 col i-1, output 2i+1 is 3/4 col i + 1/4 col i+1.
                x = 0;
                while (x < p.w) : (x += V) {
                    const c = @as(U16x, cols[1 + x ..][0..V].*) * @as(U16x, @splat(3)) + @as(U16x, @splat(8));
                    const even: U8x = @intCast((c + @as(U16x, cols[x..][0..V].*)) >> @splat(4));
                    const odd: U8x = @intCast((c + @as(U16x, cols[2 + x ..][0..V].*)) >> @splat(4));
                    self.row[2 * x ..][0 .. 2 * V].* = @shuffle(u8, even, odd, INTERLEAVE);
                }
                return self.row;
            },
            .taps => |t| {
                const y0, const y1, const wy = if (t.y) |ty| .{ ty.i0[y], ty.i1[y], ty.w[y] } else .{ y, y, @as(f32, 0) };
                const r0 = p.data[y0 * p.stride ..][0..p.w];
                const r1 = p.data[y1 * p.stride ..][0..p.w];
                for (self.row[0..self.width], 0..) |*out, x| {
                    var a0: f32 = undefined;
                    var a1: f32 = undefined;
                    if (t.x) |tx| {
                        const wx = tx.w[x];
                        a0 = std.math.lerp(@as(f32, @floatFromInt(r0[tx.i0[x]])), @as(f32, @floatFromInt(r0[tx.i1[x]])), wx);
                        a1 = std.math.lerp(@as(f32, @floatFromInt(r1[tx.i0[x]])), @as(f32, @floatFromInt(r1[tx.i1[x]])), wx);
                    } else {
                        a0 = @floatFromInt(r0[x]);
                        a1 = @floatFromInt(r1[x]);
                    }
                    out.* = @intFromFloat(@round(std.math.lerp(a0, a1, wy)));
                }
                return self.row;
            },
        }
    }
};

/// even[0], odd[0], even[1], odd[1], ...
const INTERLEAVE: [2 * V]i32 = blk: {
    var m: [2 * V]i32 = undefined;
    for (0..V) |i| {
        m[2 * i] = i;
        m[2 * i + 1] = ~@as(i32, i);
    }
    break :blk m;
};

/// Bilinear sampling positions along one axis.
const Taps = struct {
    i0: []u32,
    i1: []u32,
    w: []f32,

    fn init(scratch: std.mem.Allocator, n_out: usize, n_in: usize, factor: u8, max: u8) !Taps {
        const t: Taps = .{
            .i0 = try scratch.alloc(u32, n_out),
            .i1 = try scratch.alloc(u32, n_out),
            .w = try scratch.alloc(f32, n_out),
        };
        const ratio = @as(f32, @floatFromInt(factor)) / @as(f32, @floatFromInt(max));
        const last: f32 = @floatFromInt(n_in - 1);
        for (0..n_out) |i| {
            const pos = @min(@max((@as(f32, @floatFromInt(i)) + 0.5) * ratio - 0.5, 0), last);
            const p0 = @floor(pos);
            t.i0[i] = @intFromFloat(p0);
            t.i1[i] = @intFromFloat(@min(p0 + 1, last));
            t.w[i] = pos - p0;
        }
        return t;
    }
};

test "integer 2x upsampling matches the float taps exactly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();

    // odd and even sizes, narrower and wider than a vector, every 1x/2x combination
    for ([_]usize{ 1, 2, 3, 7, 15, 16, 17, 31, 32, 33, 65, 70, 127, V - 1, V, V + 1, 2 * V + 1, 4 * V + 3 }) |width| for ([_]usize{ 1, 2, 5, 8 }) |height| {
        for ([_][2]u8{ .{ 1, 2 }, .{ 2, 2 } }) |hf| for ([_][2]u8{ .{ 1, 2 }, .{ 2, 2 } }) |vf| {
            if (hf[0] == hf[1] and vf[0] == vf[1]) continue;
            const pw = std.math.divCeil(usize, width * hf[0], hf[1]) catch unreachable;
            const ph = std.math.divCeil(usize, height * vf[0], vf[1]) catch unreachable;
            const stride = std.mem.alignForward(usize, pw, 8);
            const plane: Plane = .{ .data = try scratch.alloc(u8, stride * ph + V), .stride = stride, .w = pw, .h = ph };
            random.bytes(plane.data);

            var fast: Upsampler = try .init(scratch, plane, width, height, hf[0], hf[1], vf[0], vf[1]);
            try std.testing.expect(fast.mode == .half);
            var ref = fast;
            ref.row = try scratch.alloc(u8, fast.row.len);
            ref.mode = .{ .taps = .{
                .x = if (hf[0] != hf[1]) try .init(scratch, width, pw, hf[0], hf[1]) else null,
                .y = if (vf[0] != vf[1]) try .init(scratch, height, ph, vf[0], vf[1]) else null,
            } };
            for (0..height) |y| try std.testing.expectEqualSlices(u8, ref.rowAt(y)[0..width], fast.rowAt(y)[0..width]);
        };
    };
}
