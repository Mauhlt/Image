//! ALPH chunk: the alpha plane of a lossy WebP (WebP container spec, "Alpha").
//!
//! Header byte: reserved(2) | pre-processing(2) | filtering(2) | compression(2).
//! Compression 0 = raw bytes, 1 = a VP8L image-stream whose green channel is
//! the alpha. Filtering then predicts each value from its neighbours.
const std = @import("std");
const Error = @import("../error.zig").Error;
const vp8l = @import("decode.zig");

pub const Filter = enum(u2) { none, horizontal, vertical, gradient };

/// Decodes `chunk` (the ALPH payload) into `out` (width * height bytes).
pub fn decode(scratch: std.mem.Allocator, chunk: []const u8, width: usize, height: usize, out: []u8) !void {
    std.debug.assert(out.len == width * height);
    if (chunk.len < 1) return Error.InvalidChunkLen;
    const compression: u2 = @truncate(chunk[0]);
    const filter: Filter = @enumFromInt(@as(u2, @truncate(chunk[0] >> 2)));
    const payload = chunk[1..];
    switch (compression) {
        0 => {
            if (payload.len < out.len) return Error.UnexpectedEndOfData;
            @memcpy(out, payload[0..out.len]);
        },
        1 => {
            const argb = try scratch.alloc(u32, out.len);
            defer scratch.free(argb);
            try vp8l.decodeImageStream(scratch, payload, width, height, argb);
            for (out, argb) |*a, p| a.* = @truncate(p >> 8); // green channel
        },
        else => return Error.UnsupportedCompression,
    }
    unfilter(filter, out, width, height);
}

/// Inverts the prediction filter in place. The first pixel is predicted from
/// 0, the rest of the top row from the left, the rest of the left column from
/// above; other pixels use the filter's predictor.
pub fn unfilter(filter: Filter, a: []u8, w: usize, h: usize) void {
    if (filter == .none) return;
    for (1..w) |x| a[x] +%= a[x - 1];
    for (1..h) |y| {
        const prev = a[(y - 1) * w ..][0..w];
        const row = a[y * w ..][0..w];
        row[0] +%= prev[0];
        switch (filter) {
            .horizontal => for (1..w) |x| {
                row[x] +%= row[x - 1];
            },
            // no dependency along the row: this loop vectorizes
            .vertical => for (row[1..], prev[1..]) |*v, above| {
                v.* +%= above;
            },
            .gradient => for (1..w) |x| {
                row[x] +%= @intCast(std.math.clamp(@as(i32, row[x - 1]) + prev[x] - prev[x - 1], 0, 255));
            },
            .none => unreachable,
        }
    }
}

test "unfilter inverts each filter" {
    const w = 5;
    const h = 4;
    var orig: [w * h]u8 = undefined;
    for (&orig, 0..) |*v, i| v.* = @truncate(i * 37 + (i / w) * 11);
    for ([_]Filter{ .horizontal, .vertical, .gradient }) |f| {
        // forward filter: residual = value - predictor (predicted from original values)
        var res: [w * h]u8 = undefined;
        for (0..h) |y| for (0..w) |x| {
            const i = y * w + x;
            const pred: u8 = if (y == 0) (if (x == 0) 0 else orig[i - 1]) else if (x == 0) orig[i - w] else switch (f) {
                .horizontal => orig[i - 1],
                .vertical => orig[i - w],
                .gradient => @intCast(std.math.clamp(@as(i32, orig[i - 1]) + orig[i - w] - orig[i - w - 1], 0, 255)),
                .none => unreachable,
            };
            res[i] = orig[i] -% pred;
        };
        unfilter(f, &res, w, h);
        try std.testing.expectEqualSlices(u8, &orig, &res);
    }
}
