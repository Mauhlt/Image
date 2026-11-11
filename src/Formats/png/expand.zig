//! Converts defiltered PNG scanlines into 8-bit output pixels.
//! The layout is decided once per image (`init`), so the per-row work is a tight
//! loop specialised at comptime for its bit depth and pixel size:
//!   copy     8-bit samples that need no change: memcpy, or a per-pixel copy for Adam7
//!   reduce16 16-bit samples without tRNS: keep the high byte, 16 samples per shuffle
//!   lookup   palette and gray up to 8 bits: one table load per pixel, which also
//!            does bit unpacking's scaling and tRNS alpha
//!   key      rgb (8/16-bit) and 16-bit gray with a tRNS color key: compare + alpha
const std = @import("std");
const Header = @import("header.zig");

pub const Expander = struct {
    kind: Kind,
    depth: u8,
    /// samples per input pixel
    channels: u8,
    out_bpp: u8,
    /// `.lookup`: sample value -> output pixel (only the first `out_bpp` bytes are used)
    lut: [256][4]u8 = undefined,
    /// `.key`: the tRNS color (one sample for gray, three for rgb)
    key: [3]u16 = undefined,

    const Kind = enum { copy, reduce16, lookup, key };

    /// `trns` must already be validated against the color type (see png.zig's `parse`).
    pub fn init(hdr: *const Header, palette: []const u8, trns: []const u8) Expander {
        const depth: u8 = @intFromEnum(hdr.bit_depth);
        const channels = hdr.color_type.channels();
        const has_trns = trns.len > 0;
        var e: Expander = .{
            .kind = undefined,
            .depth = depth,
            .channels = channels,
            .out_bpp = channels + @intFromBool(has_trns),
        };
        switch (hdr.color_type) {
            .i => {
                e.kind = .lookup;
                e.out_bpp = if (has_trns) 4 else 3;
                for (&e.lut, 0..) |*entry, idx| {
                    // out-of-range indices are an error the spec leaves to us: black
                    const rgb = if (idx * 3 + 3 <= palette.len) palette[idx * 3 ..][0..3].* else [3]u8{ 0, 0, 0 };
                    const alpha = if (idx < trns.len) trns[idx] else 255;
                    entry.* = rgb ++ [1]u8{alpha};
                }
            },
            .g => if (depth < 8 or (depth == 8 and has_trns)) {
                e.kind = .lookup;
                // a key wider than the samples never matches
                const key: usize = if (has_trns) std.mem.readInt(u16, trns[0..2], .big) else std.math.maxInt(usize);
                const max = (@as(usize, 1) << @intCast(depth)) - 1;
                for (e.lut[0 .. max + 1], 0..) |*entry, v| {
                    // scale to 8 bits by repeating the bits: 0b10 -> 0b10101010
                    const gray: u8 = @intCast(v * (255 / max));
                    entry.* = .{ gray, if (v == key) 0 else 255, 0, 0 };
                }
            } else e.initDirect(depth, trns),
            .rgb => e.initDirect(depth, trns),
            .ga, .rgba => e.kind = if (depth == 16) .reduce16 else .copy,
        }
        return e;
    }

    /// 8- and 16-bit gray / rgb.
    fn initDirect(e: *Expander, depth: u8, trns: []const u8) void {
        if (trns.len == 0) {
            e.kind = if (depth == 16) .reduce16 else .copy;
            return;
        }
        e.kind = .key;
        for (e.key[0..e.channels], 0..) |*k, c| k.* = std.mem.readInt(u16, trns[c * 2 ..][0..2], .big);
    }

    /// Converts one defiltered scanline of `width` pixels, writing pixel x at
    /// `out[x * stride ..]` (stride exceeds the pixel size in Adam7 passes).
    pub fn expand(e: *const Expander, row: []const u8, width: usize, out: []u8, stride: usize) void {
        switch (e.kind) {
            .copy => if (stride == e.channels) {
                @memcpy(out[0 .. width * stride], row[0 .. width * stride]);
            } else switch (e.channels) {
                inline 1...4 => |n| for (0..width) |x| {
                    out[x * stride ..][0..n].* = row[x * n ..][0..n].*;
                },
                else => unreachable,
            },
            .reduce16 => if (stride == e.channels)
                highBytes(row, out[0 .. width * stride])
            else switch (e.channels) {
                inline 1...4 => |n| for (0..width) |x| {
                    inline for (0..n) |c| out[x * stride + c] = row[(x * n + c) * 2];
                },
                else => unreachable,
            },
            .lookup => switch (e.depth) {
                inline 1, 2, 4, 8 => |depth| switch (e.out_bpp) {
                    inline 1...4 => |n| lookupRow(depth, n, &e.lut, row, width, out, stride),
                    else => unreachable,
                },
                else => unreachable,
            },
            .key => switch (e.channels) {
                inline 1, 3 => |n| switch (e.depth) {
                    inline 8, 16 => |depth| e.keyRow(n, depth, row, width, out, stride),
                    else => unreachable,
                },
                else => unreachable,
            },
        }
    }

    /// Writes the color samples, plus alpha 0 where the pixel equals the tRNS key.
    fn keyRow(e: *const Expander, comptime n: usize, comptime depth: usize, row: []const u8, width: usize, out: []u8, stride: usize) void {
        const bytes = depth / 8;
        for (0..width) |x| {
            const px = row[x * n * bytes ..][0 .. n * bytes];
            const o = out[x * stride ..][0 .. n + 1];
            var is_key = true;
            inline for (0..n) |c| {
                const s: u16 = if (bytes == 2) std.mem.readInt(u16, px[c * 2 ..][0..2], .big) else px[c];
                is_key = is_key and s == e.key[c];
                o[c] = px[c * bytes]; // the high byte
            }
            o[n] = if (is_key) 0 else 255;
        }
    }
};

/// out[k] = row[2k]: the high byte of each big-endian 16-bit sample.
fn highBytes(row: []const u8, out: []u8) void {
    const n = 16;
    const evens = comptime std.simd.iota(i32, n) * @as(@Vector(n, i32), @splat(2));
    var k: usize = 0;
    while (k + n <= out.len) : (k += n) {
        const v: @Vector(2 * n, u8) = row[2 * k ..][0 .. 2 * n].*;
        out[k..][0..n].* = @shuffle(u8, v, undefined, evens);
    }
    for (out[k..], k..) |*o, i| o.* = row[2 * i];
}

/// Palette or low-depth gray: unpack each `depth`-bit sample (MSB first) and copy
/// its `n`-byte table entry.
fn lookupRow(comptime depth: usize, comptime n: usize, lut: *const [256][4]u8, row: []const u8, width: usize, out: []u8, stride: usize) void {
    const mask = (1 << depth) - 1;
    for (0..width) |x| {
        const bit = x * depth;
        const shift: u3 = @intCast(8 - depth - bit % 8);
        const v = (row[bit / 8] >> shift) & mask;
        out[x * stride ..][0..n].* = lut[v][0..n].*;
    }
}

test "png expand matches the scalar oracle" {
    const Scalar = @import("scalar.zig").Expander;
    var rng: std.Random.DefaultPrng = .init(0x5eed);
    const random = rng.random();
    const ColorType = Header.ColorType;
    const Case = struct { ct: ColorType, depths: []const u8 };
    const cases = [_]Case{
        .{ .ct = .g, .depths = &.{ 1, 2, 4, 8, 16 } },
        .{ .ct = .rgb, .depths = &.{ 8, 16 } },
        .{ .ct = .i, .depths = &.{ 1, 2, 4, 8 } },
        .{ .ct = .ga, .depths = &.{ 8, 16 } },
        .{ .ct = .rgba, .depths = &.{ 8, 16 } },
    };
    var palette: [3 * 200]u8 = undefined; // short, so high indices fall off the end
    random.bytes(&palette);
    var row: [8 * 70]u8 = undefined;
    var want: [8 * 4 * 70]u8 = undefined;
    var got: [8 * 4 * 70]u8 = undefined;
    for (cases) |case| for (case.depths) |depth| {
        const hdr: Header = .{
            .width = 0, // unused here: the width is passed per row
            .height = 0,
            .bit_depth = @enumFromInt(depth),
            .color_type = case.ct,
            .compression_method = .none,
            .filter_method = .none,
            .interlace_method = .none,
        };
        // the key is a sample value that occurs in the row below; tRNS for the
        // palette is shorter than the palette so both alpha sources are hit
        var trns_buf: [150]u8 = undefined;
        random.bytes(&trns_buf);
        const max_sample: u16 = @intCast((@as(u32, 1) << @intCast(depth)) - 1);
        const key = random.uintAtMost(u16, max_sample);
        var key_buf: [6]u8 = undefined;
        for (0..3) |c| std.mem.writeInt(u16, key_buf[c * 2 ..][0..2], key, .big);
        const trns_options: []const []const u8 = switch (case.ct) {
            .g => &.{ &.{}, key_buf[0..2] },
            .rgb => &.{ &.{}, &key_buf },
            .i => &.{ &.{}, &trns_buf },
            .ga, .rgba => &.{&.{}},
        };
        for (trns_options) |trns| {
            const fast: Expander = .init(&hdr, &palette, trns);
            const slow: Scalar = .init(&hdr, &palette, trns);
            for (1..70) |width| for ([_]usize{ 1, 2, 4, 8 }) |dx| {
                const row_len = hdr.rowBytesFor(width);
                random.bytes(row[0..row_len]);
                // plant key pixels: every sample of some pixels equals the key
                if (depth >= 8) {
                    const bytes = depth / 8;
                    const px_bytes = bytes * case.ct.channels();
                    var x: usize = 0;
                    while (x < width) : (x += 3) for (0..case.ct.channels()) |c| {
                        const at = row[x * px_bytes + c * bytes ..];
                        if (bytes == 2) std.mem.writeInt(u16, at[0..2], key, .big) else at[0] = @intCast(key);
                    };
                }
                const stride = dx * fast.out_bpp;
                const len = (width - 1) * stride + fast.out_bpp;
                // pixels between the strided ones must stay untouched
                @memset(want[0..len], 0xAA);
                @memset(got[0..len], 0xAA);
                slow.expand(row[0..row_len], width, want[0..len], stride);
                fast.expand(row[0..row_len], width, got[0..len], stride);
                std.testing.expectEqualSlices(u8, want[0..len], got[0..len]) catch |err| {
                    std.debug.print("{t} depth {} trns {} width {} dx {}\n", .{ case.ct, depth, trns.len, width, dx });
                    return err;
                };
            };
        }
    };
}
