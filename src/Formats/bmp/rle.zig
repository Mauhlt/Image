//! BI_RLE8 / BI_RLE4 decoding into one palette index per pixel.
//!
//! The stream is a sequence of 2-byte codes:
//!   n v     (n > 0)  run of n pixels; RLE4 alternates v's high and low nibble
//!   0 0              end of line
//!   0 1              end of bitmap
//!   0 2 dx dy        move right dx, up dy (rows are stored bottom-up)
//!   0 n ...          (n >= 3) n literal pixels, padded to a 16-bit boundary
//! Pixels the stream never writes (delta, early end of line/bitmap) stay 0 in
//! `written`; the caller paints them black, as Windows' decoder does. Pixels
//! past the right edge are dropped; anything past the last row ends decoding.
const std = @import("std");
const Error = @import("../error.zig").Error;

pub const Kind = enum { rle4, rle8 };

/// `out` holds `width * height` indices, row 0 = first row in the file.
/// `written`, if given (same size, zero-filled), gets 1 for every pixel the stream sets.
pub fn decode(kind: Kind, src: []const u8, width: usize, height: usize, out: []u8, written: ?[]u8) Error!void {
    std.debug.assert(out.len == width * height);
    var x: usize = 0;
    var y: usize = 0;
    var i: usize = 0;
    while (y < height) {
        if (i + 2 > src.len) return Error.UnexpectedEndOfData;
        const n = src[i];
        const v = src[i + 1];
        i += 2;
        const row = out[y * width ..][0..width];
        if (n > 0) {
            // a delta may already have moved x past the right edge
            const start = @min(x, width);
            const end = @min(x + n, width);
            switch (kind) {
                .rle8 => @memset(row[start..end], v),
                .rle4 => for (start..end, 0..) |px, k| {
                    row[px] = if (k % 2 == 0) v >> 4 else v & 0xF;
                },
            }
            if (written) |w| @memset(w[y * width + start .. y * width + end], 1);
            x += n;
            continue;
        }
        switch (v) {
            0 => {
                x = 0;
                y += 1;
            },
            1 => return,
            2 => {
                if (i + 2 > src.len) return Error.UnexpectedEndOfData;
                x += src[i];
                y += src[i + 1];
                i += 2;
            },
            else => {
                const n_bytes: usize = switch (kind) {
                    .rle8 => v,
                    .rle4 => (@as(usize, v) + 1) / 2,
                };
                if (i + n_bytes > src.len) return Error.UnexpectedEndOfData;
                const lit = src[i..][0..n_bytes];
                for (0..v) |k| {
                    if (x + k >= width) break;
                    if (written) |w| w[y * width + x + k] = 1;
                    row[x + k] = switch (kind) {
                        .rle8 => lit[k],
                        .rle4 => if (k % 2 == 0) lit[k / 2] >> 4 else lit[k / 2] & 0xF,
                    };
                }
                x += v;
                i += n_bytes + (n_bytes & 1);
            },
        }
    }
}

test "rle8 runs, literals, delta and early end of line" {
    // 4x3, row 0 is the bottom row in the file
    const src = [_]u8{
        2, 7, 0, 3, 1, 2, 3, 0, // run, then 3 literals + pad byte (clipped to width)
        0, 0, // end of line
        0, 2, 1, 1, // delta (+1, +1): row 1 untouched from x=1 on, lands on row 2
        1, 9, // one pixel at (1, 2)
        0, 1, // end of bitmap
    };
    var out: [12]u8 = @splat(0);
    try decode(.rle8, &src, 4, 3, &out, null);
    try std.testing.expectEqualSlices(u8, &.{
        7, 7, 1, 2,
        0, 0, 0, 0,
        0, 9, 0, 0,
    }, &out);
}

test "rle4 alternates nibbles in runs and literals" {
    const src = [_]u8{
        3, 0x12, // 1 2 1
        0, 3, 0xAB, 0xC0, // literal A B C (2 bytes, already word aligned)
        0, 1,
    };
    var out: [6]u8 = @splat(0);
    try decode(.rle4, &src, 6, 1, &out, null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1, 0xA, 0xB, 0xC }, &out);

    // 5 literals = 3 bytes, padded to 4
    const src2 = [_]u8{ 0, 5, 0x12, 0x34, 0x50, 0xFF, 1, 0x70, 0, 1 };
    var out2: [6]u8 = @splat(0);
    try decode(.rle4, &src2, 6, 1, &out2, null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 7 }, &out2);
}

test "rle truncated stream is an error, oversized runs are clipped" {
    var out: [4]u8 = @splat(0);
    try std.testing.expectError(Error.UnexpectedEndOfData, decode(.rle8, &.{ 2, 1 }, 2, 2, &out, null));
    try std.testing.expectError(Error.UnexpectedEndOfData, decode(.rle8, &.{ 0, 5, 1, 2 }, 2, 2, &out, null));
    @memset(&out, 0);
    try decode(.rle8, &.{ 255, 3, 0, 0, 0, 2, 200, 200 }, 2, 2, &out, null);
    try std.testing.expectEqualSlices(u8, &.{ 3, 3, 0, 0 }, &out);
    // a run that starts past the right edge writes nothing
    @memset(&out, 0);
    try decode(.rle8, &.{ 0, 2, 5, 0, 2, 4, 0, 1 }, 2, 2, &out, null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &out);
}
