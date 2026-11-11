//! PNG scanline filters (spec section 9). Decoding undoes them with SIMD:
//! `up` has no dependency between bytes and runs 32 bytes at a time, while
//! `sub`, `avg` and `paeth` depend on the pixel to the left, so they run one
//! pixel per step with every channel of the pixel in a vector lane.
//! That makes avg and paeth latency-bound: each pixel waits for the one before.
//! Two consecutive such rows are therefore undone together, the lower one pixel
//! behind (it needs the pixel above), so the CPU overlaps two independent chains.
const std = @import("std");
const Error = @import("../error.zig").Error;
const FilterMethod = @import("header.zig").FilterMethod;

/// Defilters one pass in place: `h` rows of `row_bytes` bytes, each behind its
/// filter-type byte. Calls `sink.row(y, row)` on each defiltered row, in order.
/// `zero_row` is at least `row_bytes` zeros (what a pass's first row is filtered
/// against); `bpp` is bytes per complete pixel, rounded up to 1 below 8 bits.
pub fn defilterPass(raw: []u8, row_bytes: usize, h: usize, bpp: usize, zero_row: []const u8, sink: anytype) !void {
    var prev: []const u8 = zero_row[0..row_bytes];
    var y: usize = 0;
    while (y < h) {
        const line = raw[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        const method = std.enums.fromInt(FilterMethod, line[0]) orelse return Error.UnsupportedFilterMethod;
        const row = line[1..];
        if (y + 1 < h and isSerial(method)) {
            const next_line = raw[(y + 1) * (row_bytes + 1) ..][0 .. row_bytes + 1];
            const next_method = std.enums.fromInt(FilterMethod, next_line[0]) orelse .none;
            if (isSerial(next_method)) {
                defilterPair(method, row, prev, next_method, next_line[1..], bpp);
                sink.row(y, row);
                sink.row(y + 1, next_line[1..]);
                prev = next_line[1..];
                y += 2;
                continue;
            }
        }
        defilterRow(method, row, prev, bpp);
        sink.row(y, row);
        prev = row;
        y += 1;
    }
}

/// The filters whose pixels wait on a multi-instruction chain through the left
/// pixel (sub's chain is a single add, so pairing it gains nothing).
fn isSerial(method: FilterMethod) bool {
    return method == .avg or method == .paeth;
}

/// Undoes `filter` on `row` in place. `prev` is the previous defiltered row of the
/// same pass.
pub fn defilterRow(filter: FilterMethod, row: []u8, prev: []const u8, bpp: usize) void {
    switch (filter) {
        .none => {},
        .up => defilterUp(row, prev),
        inline .sub, .avg, .paeth => |f| switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| {
                var px: Pixel(f, n) = .{};
                var i: usize = 0;
                while (i < row.len) : (i += n) px.store(row, i, px.step(px.load(row, i), px.load(prev, i)));
            },
            else => unreachable, // no color type / bit depth has another pixel size
        },
    }
}

/// `row0` (filtered against `prev`) and the row after it, `row1`, both avg or paeth.
fn defilterPair(m0: FilterMethod, row0: []u8, prev: []const u8, m1: FilterMethod, row1: []u8, bpp: usize) void {
    switch (m0) {
        inline .avg, .paeth => |f0| switch (m1) {
            inline .avg, .paeth => |f1| switch (bpp) {
                inline 1, 2, 3, 4, 6, 8 => |n| {
                    var px0: Pixel(f0, n) = .{};
                    var px1: Pixel(f1, n) = .{};
                    // row1's pixel above is row0's pixel finished in the step
                    // before, still in a register: reloading it from memory would
                    // wait on that store
                    px0.store(row0, 0, px0.step(px0.load(row0, 0), px0.load(prev, 0)));
                    var i: usize = n;
                    while (i < row0.len) : (i += n) {
                        const above = px0.bytes(px0.a);
                        px0.store(row0, i, px0.step(px0.load(row0, i), px0.load(prev, i)));
                        px1.store(row1, i - n, px1.step(px1.load(row1, i - n), above));
                    }
                    px1.store(row1, row1.len - n, px1.step(px1.load(row1, row1.len - n), px0.bytes(px0.a)));
                },
                else => unreachable,
            },
            else => unreachable,
        },
        else => unreachable,
    }
}

fn defilterUp(row: []u8, prev: []const u8) void {
    const n = 32;
    const V = @Vector(n, u8);
    var i: usize = 0;
    while (i + n <= row.len) : (i += n) {
        const r: V = row[i..][0..n].*;
        const b: V = prev[i..][0..n].*;
        row[i..][0..n].* = r +% b;
    }
    for (row[i..], prev[i..row.len]) |*r, b| r.* +%= b;
}

/// One row's running state for a left-to-right filter, one pixel per vector.
/// Left of the row the neighbours `a` (left) and `c` (up-left) are zero, which
/// turns the first pixel's predictors into the spec's special cases
/// (paeth(0, b, 0) == b and so on).
fn Pixel(comptime filter: FilterMethod, comptime bpp: usize) type {
    return struct {
        /// LLVM assembles a 3- or 6-byte vector one byte at a time, so rgb and
        /// rgb16 pixels use 4 or 8 lanes; the extra lanes are never stored.
        const lanes = std.math.ceilPowerOfTwoAssert(usize, bpp);
        const Bytes = @Vector(lanes, u8);
        // paeth compares sums of two differences, which need 16 bits
        const T = if (filter == .paeth) i16 else u8;
        const V = @Vector(lanes, T);

        a: V = @splat(0),
        c: V = @splat(0),

        /// Filtered pixel x and the defiltered pixel above it -> defiltered pixel.
        inline fn step(px: *@This(), x_bytes: Bytes, b_bytes: Bytes) V {
            const x: V = x_bytes;
            const b: V = b_bytes;
            px.a = switch (filter) {
                .sub => x +% px.a,
                .avg => avg: {
                    if (lanes == 1) {
                        // a single lane is scalar code, where the shift is cheap
                        break :avg x +% @as(V, @intCast((@as(@Vector(1, u16), px.a) + b) >> @splat(1)));
                    }
                    // floor((a + b) / 2) as the rounded-up average (one `pavgb` on
                    // x86) minus the bit it rounded: x86 has no shift of u8 lanes,
                    // and emulating one lengthens the per-pixel chain
                    const W = @Vector(lanes, u16);
                    const ceil: V = @intCast((@as(W, px.a) + b + @as(W, @splat(1))) >> @splat(1));
                    break :avg x +% (ceil -% ((px.a ^ b) & @as(V, @splat(1))));
                },
                .paeth => paeth: {
                    // branchless `paethPredictor`: with p = a + b - c the
                    // distances are |b - c|, |a - c| and |(a - c) + (b - c)|
                    const e = b - px.c;
                    const d = px.a - px.c;
                    const pa = @abs(e);
                    const pb = @abs(d);
                    const pc = @abs(d + e);
                    const pred = @select(T, pa <= @min(pb, pc), px.a, @select(T, pb <= pc, b, px.c));
                    break :paeth (x + pred) & @as(V, @splat(0xFF));
                },
                else => comptime unreachable,
            };
            px.c = b;
            return px.a;
        }

        inline fn bytes(_: *const @This(), v: V) Bytes {
            // lanes are always 0..255; @intCast would mean the same, but Zig's
            // Debug x86 backend narrows i16 -> u8 vectors with signed saturation
            return if (T == u8) v else @truncate(@as(@Vector(lanes, u16), @bitCast(v)));
        }

        /// Pixel `i` of `buf`, plus the start of the next pixel when `lanes` > `bpp`.
        /// A row's last pixel has nothing after it to over-read, so it is copied in.
        inline fn load(_: *const @This(), buf: []const u8, i: usize) Bytes {
            if (lanes == bpp or i + lanes <= buf.len) return buf[i..][0..lanes].*;
            var px: [lanes]u8 = @splat(0);
            px[0..bpp].* = buf[i..][0..bpp].*;
            return px;
        }

        inline fn store(px: *const @This(), buf: []u8, i: usize, v: V) void {
            const arr: [lanes]u8 = px.bytes(v);
            buf[i..][0..bpp].* = arr[0..bpp].*;
        }
    };
}

pub fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub fn filterRow(out: []u8, filter: FilterMethod, row: []const u8, prev: []const u8, bpp: usize) void {
    switch (filter) {
        .none => @memcpy(out, row),
        .sub => {
            @memcpy(out[0..bpp], row[0..bpp]);
            for (bpp..row.len) |i| out[i] = row[i] -% row[i - bpp];
        },
        .up => for (out, row, prev) |*o, r, p| {
            o.* = r -% p;
        },
        .avg => {
            for (0..bpp) |i| out[i] = row[i] -% prev[i] / 2;
            for (bpp..row.len) |i| out[i] = row[i] -% @as(u8, @intCast((@as(u16, row[i - bpp]) + prev[i]) / 2));
        },
        .paeth => {
            for (0..bpp) |i| out[i] = row[i] -% prev[i];
            for (bpp..row.len) |i| out[i] = row[i] -% paethPredictor(row[i - bpp], prev[i], prev[i - bpp]);
        },
    }
}

test "png filters invert" {
    const prev = [_]u8{ 10, 200, 30, 40, 50, 60 };
    const row = [_]u8{ 1, 2, 250, 4, 5, 255 };
    for (std.enums.values(FilterMethod)) |f| {
        var tmp: [6]u8 = undefined;
        filterRow(&tmp, f, &row, &prev, 3);
        defilterRow(f, &tmp, &prev, 3);
        try std.testing.expectEqualSlices(u8, &row, &tmp);
    }
}

test "png vector paeth matches the predictor on every input" {
    // 256 lanes: every left value `a` at once, for each above / above-left pair
    const P = Pixel(.paeth, 256);
    for (0..256) |b| for (0..256) |c| {
        var px: P = .{ .a = std.simd.iota(i16, 256), .c = @splat(@intCast(c)) };
        // x = 0 leaves the bare prediction
        const got: [256]u8 = px.bytes(px.step(@splat(0), @splat(@intCast(b))));
        for (got, 0..) |g, a| {
            const want = paethPredictor(@intCast(a), @intCast(b), @intCast(c));
            if (g != want) {
                std.debug.print("paeth({}, {}, {}) = {}, vector says {}\n", .{ a, b, c, want, g });
                return error.TestUnexpectedResult;
            }
        }
    };
}

test "png defilter matches the scalar oracle" {
    const scalar = @import("scalar.zig");
    var rng: std.Random.DefaultPrng = .init(0x9e3779b9);
    const random = rng.random();
    var prev_buf: [8 * 80]u8 = undefined;
    var row_buf: [8 * 80]u8 = undefined;
    var want_buf: [8 * 80]u8 = undefined;
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |bpp| {
        // odd lengths cover the scalar tail of `up` and rows shorter than one vector
        for (1..80) |width| {
            const len = width * bpp;
            for (0..4) |round| {
                random.bytes(prev_buf[0..len]);
                random.bytes(row_buf[0..len]);
                // tiny values make paeth's distance ties common
                if (round % 2 == 1) for (prev_buf[0..len], row_buf[0..len]) |*p, *r| {
                    p.* &= 3;
                    r.* &= 3;
                };
                for (std.enums.values(FilterMethod)) |f| {
                    const want = want_buf[0..len];
                    @memcpy(want, row_buf[0..len]);
                    scalar.defilterRow(f, want, prev_buf[0..len], bpp);
                    var got: [8 * 80]u8 = undefined;
                    @memcpy(got[0..len], row_buf[0..len]);
                    defilterRow(f, got[0..len], prev_buf[0..len], bpp);
                    std.testing.expectEqualSlices(u8, want, got[0..len]) catch |err| {
                        std.debug.print("filter {t}, bpp {}, width {}\n", .{ f, bpp, width });
                        return err;
                    };
                }
            }
        }
    }
}

test "png defilterPass (row pairs) matches the scalar oracle" {
    const scalar = @import("scalar.zig");
    var rng: std.Random.DefaultPrng = .init(0x51ab);
    const random = rng.random();
    const max_w = 40;
    const max_h = 7;
    const zero_row: [8 * max_w]u8 = @splat(0);
    var raw: [(8 * max_w + 1) * max_h]u8 = undefined;
    var want: [raw.len]u8 = undefined;
    // every filter type for the first two rows, so each pair kind and every
    // single-row fallback occurs; later rows are random
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |bpp| for ([_]usize{ 1, 2, 5, 17, max_w }) |width| {
        for (1..max_h + 1) |h| for (0..5) |f0| for (0..5) |f1| {
            const row_bytes = width * bpp;
            const len = h * (row_bytes + 1);
            random.bytes(raw[0..len]);
            for (0..h) |y| raw[y * (row_bytes + 1)] = switch (y) {
                0 => @intCast(f0),
                1 => @intCast(f1),
                else => random.uintLessThan(u8, 5),
            };
            @memcpy(want[0..len], raw[0..len]);
            const Ignore = struct {
                pub fn row(_: @This(), _: usize, _: []const u8) void {}
            };
            try scalar.defilterPass(want[0..len], row_bytes, h, bpp, &zero_row, Ignore{});
            try defilterPass(raw[0..len], row_bytes, h, bpp, &zero_row, Ignore{});
            std.testing.expectEqualSlices(u8, want[0..len], raw[0..len]) catch |err| {
                std.debug.print("bpp {}, width {}, height {}, filters {} {}\n", .{ bpp, width, h, f0, f1 });
                return err;
            };
        };
    };
}
