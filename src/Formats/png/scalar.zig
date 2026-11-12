//! Test oracle: the original straightforward, one-sample-at-a-time defilter and row
//! expansion. The SIMD paths in filter.zig and expand.zig must match it byte for byte.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Header = @import("header.zig");
const FilterMethod = Header.FilterMethod;
const paethPredictor = @import("filter.zig").paethPredictor;

/// Same interface as filter.zig's `defilterPass`, one row at a time.
pub fn defilterPass(raw: []u8, row_bytes: usize, h: usize, bpp: usize, zero_row: []const u8, sink: anytype) !void {
    var prev: []const u8 = zero_row[0..row_bytes];
    for (0..h) |y| {
        const line = raw[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        const method = std.enums.fromInt(FilterMethod, line[0]) orelse return Error.UnsupportedFilterMethod;
        defilterRow(method, line[1..], prev, bpp);
        sink.row(y, line[1..]);
        prev = line[1..];
    }
}

pub fn defilterRow(filter: FilterMethod, row: []u8, prev: []const u8, bpp: usize) void {
    switch (filter) {
        .none => {},
        .sub => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        .up => for (row, prev) |*r, p| {
            r.* +%= p;
        },
        .avg => {
            for (0..bpp) |i| row[i] +%= prev[i] / 2;
            for (bpp..row.len) |i| row[i] +%= @intCast((@as(u16, row[i - bpp]) + prev[i]) / 2);
        },
        .paeth => {
            for (0..bpp) |i| row[i] +%= prev[i]; // paeth(0, b, 0) == b
            for (bpp..row.len) |i| row[i] +%= paethPredictor(row[i - bpp], prev[i], prev[i - bpp]);
        },
    }
}

/// Same interface as expand.zig's `Expander`.
pub const Expander = struct {
    hdr: *const Header,
    palette: []const u8,
    trns: []const u8,

    pub fn init(hdr: *const Header, palette: []const u8, trns: []const u8) Expander {
        return .{ .hdr = hdr, .palette = palette, .trns = trns };
    }

    /// Converts one defiltered scanline of `width` pixels into 8-bit output pixels,
    /// `stride` bytes apart in `out`.
    pub fn expand(p: *const Expander, row: []const u8, width: usize, out: []u8, stride: usize) void {
        const hdr = p.hdr;
        const depth: usize = @intFromEnum(hdr.bit_depth);
        const channels = hdr.color_type.channels();

        if (depth == 8 and hdr.color_type != .i and p.trns.len == 0 and stride == channels) {
            @memcpy(out, row[0..out.len]);
            return;
        }

        for (0..width) |x| {
            var o = x * stride;
            var s: [4]u16 = undefined;
            for (0..channels) |c| s[c] = sample(row, x * channels + c, depth);
            switch (hdr.color_type) {
                .i => {
                    const idx: usize = s[0];
                    const pal = if (idx * 3 + 3 <= p.palette.len) p.palette[idx * 3 ..][0..3].* else [3]u8{ 0, 0, 0 };
                    out[o..][0..3].* = pal;
                    o += 3;
                    if (p.trns.len > 0) {
                        out[o] = if (idx < p.trns.len) p.trns[idx] else 255;
                        o += 1;
                    }
                },
                .g => if (depth == 16 and p.trns.len < 2) {
                    // `.g16`: the sample, native endian
                    std.mem.writeInt(u16, out[o..][0..2], s[0], @import("builtin").cpu.arch.endian());
                } else {
                    const raw = s[0];
                    out[o] = scale8(raw, depth);
                    o += 1;
                    if (p.trns.len >= 2) {
                        const key = std.mem.readInt(u16, p.trns[0..2], .big);
                        out[o] = if (raw == key) 0 else 255;
                        o += 1;
                    }
                },
                .rgb => {
                    for (0..3) |c| out[o + c] = scale8(s[c], depth);
                    o += 3;
                    if (p.trns.len >= 6) {
                        const match = s[0] == std.mem.readInt(u16, p.trns[0..2], .big) and
                            s[1] == std.mem.readInt(u16, p.trns[2..4], .big) and
                            s[2] == std.mem.readInt(u16, p.trns[4..6], .big);
                        out[o] = if (match) 0 else 255;
                        o += 1;
                    }
                },
                .ga, .rgba => {
                    for (0..channels) |c| out[o + c] = scale8(s[c], depth);
                    o += channels;
                },
            }
        }
    }
};

/// Reads sample `i` of `depth` bits from a big-endian, MSB-first packed row.
fn sample(row: []const u8, i: usize, depth: usize) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        8 => row[i],
        else => blk: {
            const bit = i * depth;
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            break :blk (row[bit / 8] >> shift) & mask;
        },
    };
}

fn scale8(v: u16, depth: usize) u8 {
    return switch (depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        4 => @intCast(v * 0x11),
        2 => @intCast(v * 0x55),
        1 => @intCast(v * 0xFF),
        else => unreachable,
    };
}

test "png sub-byte samples" {
    // 4-bit row: 0xAB 0xC0 -> samples A, B, C
    const row = [_]u8{ 0xAB, 0xC0 };
    try std.testing.expectEqual(@as(u16, 0xA), sample(&row, 0, 4));
    try std.testing.expectEqual(@as(u16, 0xB), sample(&row, 1, 4));
    try std.testing.expectEqual(@as(u16, 0xC), sample(&row, 2, 4));
    try std.testing.expectEqual(@as(u8, 0xFF), scale8(1, 1));
}
