//! Block compression (BCn) for GPU textures.
//! The GPU decodes these natively while sampling, so a compressed texture goes from disk
//! to `vkCmdCopyBufferToImage` with NO CPU decode, and uses 4-8x less VRAM/bandwidth.
//!
//!   format | bytes/4x4 | channels            | typical use
//!   bc1    |   8       | RGB (1-bit alpha)   | opaque color
//!   bc2    |  16       | RGB + 4-bit alpha   | legacy sharp alpha
//!   bc3    |  16       | RGB + smooth alpha  | color + alpha
//!   bc4    |   8       | R                   | masks, roughness, height
//!   bc5    |  16       | RG                  | tangent-space normal maps
//!   bc6h   |  16       | RGB half-float      | HDR (upload only, no CPU codec)
//!   bc7    |  16       | RGBA high quality   | best quality color (+alpha)
const std = @import("std");
const vk = @import("Vulkan");
const bc1 = @import("bc1.zig");
const bc4 = @import("bc4.zig");
const bc7 = @import("bc7.zig");
const Block = bc1.Block;

pub const Format = enum {
    bc1,
    bc2,
    bc3,
    bc4,
    bc5,
    bc6h,
    bc7,

    pub fn blockBytes(self: Format) usize {
        return switch (self) {
            .bc1, .bc4 => 8,
            else => 16,
        };
    }

    pub fn vkFormat(self: Format, srgb: bool) vk.Format {
        return switch (self) {
            .bc1 => if (srgb) .bc1_rgba_srgb_block else .bc1_rgba_unorm_block,
            .bc2 => if (srgb) .bc2_srgb_block else .bc2_unorm_block,
            .bc3 => if (srgb) .bc3_srgb_block else .bc3_unorm_block,
            .bc4 => .bc4_unorm_block,
            .bc5 => .bc5_unorm_block,
            .bc6h => .bc6h_ufloat_block,
            .bc7 => if (srgb) .bc7_srgb_block else .bc7_unorm_block,
        };
    }

    pub fn fromVk(f: vk.Format) ?struct { Format, bool } {
        return switch (f) {
            .bc1_rgb_unorm_block, .bc1_rgba_unorm_block => .{ .bc1, false },
            .bc1_rgb_srgb_block, .bc1_rgba_srgb_block => .{ .bc1, true },
            .bc2_unorm_block => .{ .bc2, false },
            .bc2_srgb_block => .{ .bc2, true },
            .bc3_unorm_block => .{ .bc3, false },
            .bc3_srgb_block => .{ .bc3, true },
            .bc4_unorm_block, .bc4_snorm_block => .{ .bc4, false },
            .bc5_unorm_block, .bc5_snorm_block => .{ .bc5, false },
            .bc6h_ufloat_block, .bc6h_sfloat_block => .{ .bc6h, false },
            .bc7_unorm_block => .{ .bc7, false },
            .bc7_srgb_block => .{ .bc7, true },
            else => null,
        };
    }

    pub fn canEncode(self: Format) bool {
        return self != .bc6h;
    }
};

pub fn blocksX(width: usize) usize {
    return (width + 3) / 4;
}

pub fn encodedLen(f: Format, width: usize, height: usize) usize {
    return blocksX(width) * blocksX(height) * f.blockBytes();
}

/// Gathers a 4x4 tile from an RGBA image, clamping at the edges.
fn loadTile(rgba: []const u8, width: usize, height: usize, bx: usize, by: usize) Block {
    var t: Block = undefined;
    for (0..4) |y| for (0..4) |x| {
        const sx = @min(bx * 4 + x, width - 1);
        const sy = @min(by * 4 + y, height - 1);
        t[y * 4 + x] = rgba[(sy * width + sx) * 4 ..][0..4].*;
    };
    return t;
}

fn storeTile(t: *const Block, rgba: []u8, width: usize, height: usize, bx: usize, by: usize) void {
    for (0..4) |y| for (0..4) |x| {
        const dx = bx * 4 + x;
        const dy = by * 4 + y;
        if (dx < width and dy < height) rgba[(dy * width + dx) * 4 ..][0..4].* = t[y * 4 + x];
    };
}

pub fn encodeBlock(f: Format, t: *const Block, out: []u8) void {
    switch (f) {
        .bc1 => bc1.encodeBlock(t, out[0..8]),
        .bc2 => {
            var a: u64 = 0;
            for (t, 0..) |p, i| a |= @as(u64, (@as(u32, p[3]) * 15 + 127) / 255) << @intCast(i * 4);
            std.mem.writeInt(u64, out[0..8], a, .little);
            bc1.encodeBlock(t, out[8..16]);
        },
        .bc3 => {
            var a: [16]u8 = undefined;
            for (t, &a) |p, *v| v.* = p[3];
            bc4.encodeBlock(&a, out[0..8]);
            bc1.encodeBlock(t, out[8..16]);
        },
        .bc4 => {
            var r: [16]u8 = undefined;
            for (t, &r) |p, *v| v.* = p[0];
            bc4.encodeBlock(&r, out[0..8]);
        },
        .bc5 => {
            var r: [16]u8 = undefined;
            var g: [16]u8 = undefined;
            for (t, &r, &g) |p, *x, *y| {
                x.* = p[0];
                y.* = p[1];
            }
            bc4.encodeBlock(&r, out[0..8]);
            bc4.encodeBlock(&g, out[8..16]);
        },
        .bc7 => bc7.encodeBlock(t, out[0..16]),
        .bc6h => unreachable,
    }
}

pub fn decodeBlock(f: Format, src: []const u8, t: *Block) !void {
    switch (f) {
        .bc1 => bc1.decodeBlock(src[0..8], t),
        .bc2 => {
            const a = std.mem.readInt(u64, src[0..8], .little);
            bc1.decodeColorOnly(src[8..16], t);
            for (t, 0..) |*p, i| p[3] = @as(u8, @intCast((a >> @intCast(i * 4)) & 0xF)) * 17;
        },
        .bc3 => {
            var a: [16]u8 = undefined;
            bc4.decodeBlock(src[0..8], &a);
            bc1.decodeColorOnly(src[8..16], t);
            for (t, a) |*p, v| p[3] = v;
        },
        .bc4 => {
            var r: [16]u8 = undefined;
            bc4.decodeBlock(src[0..8], &r);
            for (t, r) |*p, v| p.* = .{ v, 0, 0, 255 }; // what the GPU returns: (r, 0, 0, 1)
        },
        .bc5 => {
            var r: [16]u8 = undefined;
            var g: [16]u8 = undefined;
            bc4.decodeBlock(src[0..8], &r);
            bc4.decodeBlock(src[8..16], &g);
            for (t, r, g) |*p, x, y| p.* = .{ x, y, 0, 255 };
        },
        .bc7 => try bc7.decodeBlock(src[0..16], t),
        .bc6h => return error.UnsupportedFeature,
    }
}

/// RGBA8 image -> blocks. `out.len` must be `encodedLen(f, width, height)`.
pub fn encodeImage(f: Format, rgba: []const u8, width: usize, height: usize, out: []u8) void {
    const bw = blocksX(width);
    const bb = f.blockBytes();
    for (0..blocksX(height)) |by| for (0..bw) |bx| {
        const t = loadTile(rgba, width, height, bx, by);
        encodeBlock(f, &t, out[(by * bw + bx) * bb ..][0..bb]);
    };
}

/// blocks -> RGBA8 image (CPU fallback / previews; the GPU normally does this).
pub fn decodeImage(f: Format, blocks: []const u8, width: usize, height: usize, rgba: []u8) !void {
    const bw = blocksX(width);
    const bb = f.blockBytes();
    if (blocks.len < encodedLen(f, width, height)) return error.UnexpectedEndOfData;
    for (0..blocksX(height)) |by| for (0..bw) |bx| {
        var t: Block = undefined;
        try decodeBlock(f, blocks[(by * bw + bx) * bb ..][0..bb], &t);
        storeTile(&t, rgba, width, height, bx, by);
    };
}

test {
    _ = bc1;
    _ = bc4;
    _ = bc7;
}

test "bc encode/decode every format on a gradient" {
    const gpa = std.testing.allocator;
    const W = 13;
    const H = 9; // not multiples of 4
    var rgba: [W * H * 4]u8 = undefined;
    for (0..W * H) |i| rgba[i * 4 ..][0..4].* = .{ @intCast(i * 2), @intCast(255 - i), @intCast(i), @intCast(i * 2) };
    for ([_]Format{ .bc1, .bc2, .bc3, .bc4, .bc5, .bc7 }) |f| {
        const blocks = try gpa.alloc(u8, encodedLen(f, W, H));
        defer gpa.free(blocks);
        encodeImage(f, &rgba, W, H, blocks);
        var out: [W * H * 4]u8 = undefined;
        try decodeImage(f, blocks, W, H, &out);
        var total: u64 = 0;
        var n: u64 = 0;
        for (0..W * H) |i| {
            const channels: usize = switch (f) {
                .bc1 => 3,
                .bc4 => 1,
                .bc5 => 2,
                else => 4,
            };
            for (0..channels) |c| {
                total += @abs(@as(i32, rgba[i * 4 + c]) - out[i * 4 + c]);
                n += 1;
            }
        }
        const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(n));
        std.testing.expect(mean < 12) catch |err| {
            std.debug.print("{t}: mean err {d:.2}\n", .{ f, mean });
            return err;
        };
    }
}
