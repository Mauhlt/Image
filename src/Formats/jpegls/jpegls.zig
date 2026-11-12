//! ITU T.87 JPEG-LS decoder for DICOM compressed pixel data: lossless and
//! near-lossless, 2..16 bit, regular and run mode, default or LSE (id 1)
//! coding parameters, restart markers. 1..4 components with ILV 0 (one
//! component per scan) or ILV 1 (line interleaved); ILV 2 (sample interleaved
//! with more than one component), mapping tables and point transform are
//! reported as error.UnsupportedFeature.
//!
//! Raw API: `decode` -> 16-bit samples at their own precision.
//! Codec path (`.jls`): `info` / `decodeInto` scale the samples to Image pixels
//! (1 component -> .g, or .g16 above 8 bits; 3 -> .rgb; see jpg/narrow.zig). No encoder (`encode` fails).
//!
//! Shares marker handling (Marker, Segments) with jpg; the entropy coder, bit
//! stuffing and so the bit reader and `entropyEnd` are JPEG-LS specific.
const std = @import("std");
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const ImageError = @import("../error.zig").Error;
const jpg_misc = @import("../jpg/misc.zig");
const narrow = @import("../jpg/narrow.zig");
const Marker = jpg_misc.Marker;

pub const Error = error{ InvalidData, UnexpectedEnd, UnsupportedFeature, OutOfMemory };

pub const Decoded = struct {
    width: u16,
    height: u16,
    precision: u8, // bits per sample (P)
    components: u8,
    /// width*height*components, component-interleaved per pixel
    samples: []u16,
};

// ---------------------------------------------------------------- parameters

const J = [32]u5{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// LSE id 1 values; 0 = default.
const Preset = struct { maxval: u16 = 0, t1: u16 = 0, t2: u16 = 0, t3: u16 = 0, reset: u16 = 0 };

const Params = struct {
    maxval: i32,
    near: i32,
    range: i32,
    qbpp: u32,
    limit: i32,
    t1: i32,
    t2: i32,
    t3: i32,
    reset: i32,

    fn init(precision: u8, near: i32, preset: Preset) Error!Params {
        const maxval: i32 = if (preset.maxval != 0) preset.maxval else (@as(i32, 1) << @intCast(precision)) - 1;
        if (near < 0 or near > @min(255, @divFloor(maxval, 2))) return error.InvalidData;
        const range = @divFloor(maxval + 2 * near, 2 * near + 1) + 1;
        const bpp = @max(2, ceilLog2(maxval + 1));
        var p: Params = .{
            .maxval = maxval,
            .near = near,
            .range = range,
            .qbpp = ceilLog2(range),
            .limit = @intCast(2 * (bpp + @max(8, bpp))),
            .t1 = 0,
            .t2 = 0,
            .t3 = 0,
            .reset = if (preset.reset != 0) preset.reset else 64,
        };
        // default thresholds (C.2.4.1.1)
        var t1: i32 = undefined;
        var t2: i32 = undefined;
        var t3: i32 = undefined;
        if (maxval >= 128) {
            const factor = @divFloor(@min(maxval, 4095) + 128, 256);
            t1 = clampT(factor * (3 - 2) + 2 + 3 * near, near + 1, maxval);
            t2 = clampT(factor * (7 - 3) + 3 + 5 * near, t1, maxval);
            t3 = clampT(factor * (21 - 4) + 4 + 7 * near, t2, maxval);
        } else {
            const factor = @divFloor(256, maxval + 1);
            t1 = clampT(@max(2, @divFloor(3, factor) + 3 * near), near + 1, maxval);
            t2 = clampT(@max(3, @divFloor(7, factor) + 5 * near), t1, maxval);
            t3 = clampT(@max(4, @divFloor(21, factor) + 7 * near), t2, maxval);
        }
        p.t1 = if (preset.t1 != 0) preset.t1 else t1;
        p.t2 = if (preset.t2 != 0) preset.t2 else t2;
        p.t3 = if (preset.t3 != 0) preset.t3 else t3;
        if (p.reset < 3) return error.InvalidData;
        return p;
    }

    fn clampT(i: i32, j: i32, maxval: i32) i32 {
        return if (i > maxval or i < j) j else i;
    }

    inline fn quantizeGradient(p: *const Params, d: i32) i32 {
        if (d <= -p.t3) return -4;
        if (d <= -p.t2) return -3;
        if (d <= -p.t1) return -2;
        if (d < -p.near) return -1;
        if (d <= p.near) return 0;
        if (d < p.t1) return 1;
        if (d < p.t2) return 2;
        if (d < p.t3) return 3;
        return 4;
    }

    /// Rx from the prediction and the (signed, quantized) error (A.4.5).
    inline fn reconstruct(p: *const Params, px: i32, errval: i32) i32 {
        const step = 2 * p.near + 1;
        var rx = px + errval * step;
        if (rx < -p.near) {
            rx += p.range * step;
        } else if (rx > p.maxval + p.near) {
            rx -= p.range * step;
        }
        return std.math.clamp(rx, 0, p.maxval);
    }
};

fn ceilLog2(x: i32) u32 {
    var n: u32 = 0;
    while ((@as(i64, 1) << @intCast(n)) < x) n += 1;
    return n;
}

inline fn medPredict(ra: i32, rb: i32, rc: i32) i32 {
    if (rc >= @max(ra, rb)) return @min(ra, rb);
    if (rc <= @min(ra, rb)) return @max(ra, rb);
    return ra + rb - rc;
}

// ---------------------------------------------------------------- context state

const State = struct {
    a: [367]i32,
    b: [365]i32,
    c: [365]i32,
    n: [367]i32,
    nn: [2]i32,
    run_index: [4]u8,

    fn init(p: *const Params) State {
        return .{
            .a = @splat(@max(2, @divFloor(p.range + 32, 64))),
            .b = @splat(0),
            .c = @splat(0),
            .n = @splat(1),
            .nn = @splat(0),
            .run_index = @splat(0),
        };
    }

    const Context = struct { q: usize, sign: i32 };

    inline fn context(p: *const Params, ra: i32, rb: i32, rc: i32, rd: i32) Context {
        var q1 = p.quantizeGradient(rd - rb);
        var q2 = p.quantizeGradient(rb - rc);
        var q3 = p.quantizeGradient(rc - ra);
        var sign: i32 = 1;
        if (q1 < 0 or (q1 == 0 and (q2 < 0 or (q2 == 0 and q3 < 0)))) {
            q1 = -q1;
            q2 = -q2;
            q3 = -q3;
            sign = -1;
        }
        return .{ .q = @intCast((q1 * 9 + q2) * 9 + q3), .sign = sign };
    }

    /// Smallest k (max 24) with n << k >= a. Closed form: k is the bit-length
    /// difference of a and n, or one more (n << d has a's bit length).
    inline fn golombK(n: i32, a: i32) u5 {
        if (a <= n) return 0;
        if (n <= 0) return golombKLoop(n, a);
        const d: u6 = @intCast(@clz(@as(u32, @intCast(n))) - @clz(@as(u32, @intCast(a))));
        const k = @as(u32, d) + @intFromBool((@as(i64, n) << d) < a);
        return @intCast(@min(k, 24));
    }

    fn golombKLoop(n: i32, a: i32) u5 {
        var k: u5 = 0;
        while ((@as(i64, n) << k) < a and k < 24) k += 1;
        return k;
    }

    /// Bias-corrected prediction for a regular-mode sample (A.4).
    inline fn correctedPrediction(self: *const State, p: *const Params, px: i32, ctx: Context) i32 {
        return std.math.clamp(px + ctx.sign * self.c[ctx.q], 0, p.maxval);
    }

    /// The special mapping case of A.5.2.
    inline fn specialMap(self: *const State, p: *const Params, k: u5, q: usize) bool {
        return p.near == 0 and k == 0 and 2 * self.b[q] <= -self.n[q];
    }

    /// A.6.1 / A.6.2
    inline fn updateRegular(self: *State, p: *const Params, q: usize, errval: i32) void {
        self.b[q] += errval * (2 * p.near + 1);
        self.a[q] += @intCast(@abs(errval));
        if (self.n[q] == p.reset) {
            self.a[q] >>= 1;
            self.b[q] = if (self.b[q] >= 0) self.b[q] >> 1 else -((1 - self.b[q]) >> 1);
            self.n[q] >>= 1;
        }
        self.n[q] += 1;
        if (self.b[q] <= -self.n[q]) {
            self.b[q] += self.n[q];
            if (self.c[q] > -128) self.c[q] -= 1;
            if (self.b[q] <= -self.n[q]) self.b[q] = -self.n[q] + 1;
        } else if (self.b[q] > 0) {
            self.b[q] -= self.n[q];
            if (self.c[q] < 127) self.c[q] += 1;
            if (self.b[q] > 0) self.b[q] = 0;
        }
    }

    inline fn riK(self: *const State, ritype: u1) u5 {
        const q = 365 + @as(usize, ritype);
        const temp = if (ritype == 0) self.a[q] else self.a[q] + (self.n[q] >> 1);
        return golombK(self.n[q], temp);
    }

    /// A.7.2.2
    inline fn updateRunInterruption(self: *State, p: *const Params, ritype: u1, errval: i32, emerr: i32) void {
        const q = 365 + @as(usize, ritype);
        if (errval < 0) self.nn[ritype] += 1;
        self.a[q] += (emerr + 1 - @as(i32, ritype)) >> 1;
        if (self.n[q] == p.reset) {
            self.a[q] >>= 1;
            self.n[q] >>= 1;
            self.nn[ritype] >>= 1;
        }
        self.n[q] += 1;
    }
};

// ---------------------------------------------------------------- bit reader

/// MSB-first reader over one JPEG-LS entropy-coded segment: after an 0xFF
/// byte the next byte carries only 7 bits. At a marker or the end it feeds
/// zero bits and counts them so overruns can be detected.
const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    /// left aligned
    acc: u64 = 0,
    count: u32 = 0,
    virt: u32 = 0,
    prev_ff: bool = false,

    fn fill(self: *BitReader) void {
        // Fast path: 8 bytes with no 0xFF (so every byte carries 8 bits and none
        // starts a marker) go in with one big-endian load. 8 = the accumulator
        // width, not a SIMD width.
        if (!self.prev_ff and self.count <= 48 and self.pos + 8 <= self.data.len) {
            const x = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
            const ones: u64 = 0x0101_0101_0101_0101;
            if (((~x) -% ones) & x & (ones << 7) == 0) {
                const take = (64 - self.count) / 8; // whole bytes that fit, 2..8
                const keep: u32 = 64 - take * 8;
                self.acc |= (x >> @intCast(keep)) << @intCast(keep - self.count);
                self.count += take * 8;
                self.pos += take;
                return;
            }
        }
        while (self.count <= 48) {
            if (self.pos < self.data.len) {
                const byte = self.data[self.pos];
                if (self.prev_ff) {
                    // the marker check below means this byte is < 0x80
                    self.acc |= @as(u64, byte) << @intCast(57 - self.count);
                    self.count += 7;
                    self.prev_ff = false;
                    self.pos += 1;
                    continue;
                }
                const is_marker = byte == 0xFF and (self.pos + 1 >= self.data.len or self.data[self.pos + 1] >= 0x80);
                if (!is_marker) {
                    self.acc |= @as(u64, byte) << @intCast(56 - self.count);
                    self.count += 8;
                    self.prev_ff = byte == 0xFF;
                    self.pos += 1;
                    continue;
                }
            }
            self.virt += 8;
            self.count += 8;
        }
    }

    inline fn consume(self: *BitReader, n: u32) void {
        self.acc = if (n >= 64) 0 else self.acc << @intCast(n);
        self.count -= n;
    }

    fn readBits(self: *BitReader, n: u32) u32 {
        if (n == 0) return 0;
        if (self.count < n) self.fill();
        const v: u32 = @intCast(self.acc >> @intCast(64 - n));
        self.consume(n);
        return v;
    }

    fn readBit(self: *BitReader) u1 {
        return @intCast(self.readBits(1));
    }

    /// Number of 0 bits before the next 1 bit (which is consumed).
    fn unary(self: *BitReader, max: u32) Error!u32 {
        var n: u32 = 0;
        while (true) {
            if (self.count == 0) self.fill();
            const lz: u32 = @clz(self.acc);
            if (lz < self.count) {
                n += lz;
                self.consume(lz + 1);
                if (n > max) return self.failure();
                return n;
            }
            n += self.count;
            self.acc = 0;
            self.count = 0;
            if (n > max) return self.failure();
        }
    }

    fn failure(self: *const BitReader) Error {
        return if (self.virt > 0 and self.pos >= self.data.len) error.UnexpectedEnd else error.InvalidData;
    }

    fn check(self: *const BitReader) Error!void {
        if (self.virt > self.count) return self.failure();
    }

    fn restart(self: *BitReader) Error!void {
        try self.check();
        self.acc = 0;
        self.count = 0;
        self.virt = 0;
        self.prev_ff = false;
        while (self.pos + 1 < self.data.len and self.data[self.pos] == 0xFF and self.data[self.pos + 1] == 0xFF)
            self.pos += 1;
        if (self.pos + 1 >= self.data.len) return error.UnexpectedEnd;
        if (self.data[self.pos] != 0xFF) return error.InvalidData;
        const m = self.data[self.pos + 1];
        if (m < 0xD0 or m > 0xD7) return error.InvalidData;
        self.pos += 2;
    }

    /// Golomb-coded value with length limit (A.5.3).
    fn golomb(self: *BitReader, k: u5, limit: i32, qbpp: u32) Error!i32 {
        const max: u32 = @intCast(@max(0, limit - @as(i32, @intCast(qbpp)) - 1));
        const prefix = try self.unary(max);
        if (prefix < max) return @intCast((prefix << k) | self.readBits(k));
        return @as(i32, @intCast(self.readBits(qbpp))) + 1;
    }
};

/// Offset of the marker ending the entropy-coded data at `start`
/// (skipping RSTn markers), or `data.len`.
fn entropyEnd(data: []const u8, start: usize) usize {
    var i = start;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] != 0xFF) continue;
        const m = data[i + 1];
        if (m < 0x80) {
            i += 1;
        } else if (m >= 0xD0 and m <= 0xD7) {
            i += 1;
        } else if (m != 0xFF) {
            return i;
        }
    }
    return data.len;
}

// ---------------------------------------------------------------- decoder

pub const Frame = struct {
    precision: u8 = 0,
    width: u16 = 0,
    height: u16 = 0,
    nc: u8 = 0,
    ids: [4]u8 = @splat(0),
};

fn nextSegment(it: *jpg_misc.Segments) Error!?jpg_misc.Segment {
    return it.next() catch |err| switch (err) {
        error.InvalidMarker => error.InvalidData,
        error.UnexpectedEndOfData => error.UnexpectedEnd,
    };
}

/// Parses an SOF55 segment body.
fn parseFrame(seg: []const u8) Error!Frame {
    if (seg.len < 6) return error.InvalidData;
    var frame: Frame = .{
        .precision = seg[0],
        .height = std.mem.readInt(u16, seg[1..3], .big),
        .width = std.mem.readInt(u16, seg[3..5], .big),
        .nc = seg[5],
    };
    if (frame.precision < 2 or frame.precision > 16) return error.InvalidData;
    if (frame.width == 0) return error.InvalidData;
    if (frame.nc < 1 or frame.nc > 4) return error.UnsupportedFeature;
    if (seg.len < 6 + 3 * @as(usize, frame.nc)) return error.InvalidData;
    for (0..frame.nc) |i| {
        frame.ids[i] = seg[6 + 3 * i];
        if (frame.nc > 1 and seg[7 + 3 * i] != 0x11) return error.UnsupportedFeature;
    }
    return frame;
}

/// Height from the DNL segment that must follow the first scan (ending at `end`).
fn dnlHeight(data: []const u8, end: usize) Error!u16 {
    if (end + 6 > data.len or data[end + 1] != @backingInt(Marker.DNL)) return error.InvalidData;
    const h = std.mem.readInt(u16, data[end + 4 ..][0..2], .big);
    if (h == 0) return error.InvalidData;
    return h;
}

/// The frame header alone (height taken from DNL when the SOF leaves it 0).
pub fn readFrame(data: []const u8) Error!Frame {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return error.InvalidData;
    var frame: ?Frame = null;
    var it: jpg_misc.Segments = .{ .data = data };
    while (try nextSegment(&it)) |s| switch (s.marker) {
        .SOF55 => {
            if (frame != null) return error.InvalidData;
            frame = try parseFrame(s.body);
            if (frame.?.height != 0) return frame.?;
        },
        .SOS => {
            var f = frame orelse return error.InvalidData;
            f.height = try dnlHeight(data, entropyEnd(data, it.pos));
            return f;
        },
        .EOI => break,
        else => {},
    };
    return error.InvalidData;
}

// ---------------------------------------------------------------- codec path (8 bit)

pub fn info(data: []const u8) !Info {
    const f = try readFrame(data);
    const tag = try narrow.tagFor(f.nc, f.precision);
    return .{ .width = f.width, .height = f.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

/// Decodes to 16-bit samples in `scratch`, then scales them into `out` as `inf.tag`
/// pixels (`narrow.tagFor`: .g / .g16 above 8 bits for 1 component, .rgb for 3).
pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const d = try decode(scratch, data);
    defer scratch.free(d.samples);
    if (d.width != inf.width or d.height != inf.height) return ImageError.InvalidDimensions;
    if (try narrow.tagFor(d.components, d.precision) != inf.tag) return ImageError.UnsupportedPixels;
    if (out.len != d.samples.len * @as(usize, if (inf.tag == .g16) 2 else 1)) return ImageError.InvalidDataLen;
    narrow.store(d.samples, d.precision, inf.tag, out);
}

/// No JPEG-LS encoder (only the test encoder below, which is not a supported API).
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    _ = .{ img, w, gpa };
    return ImageError.UnsupportedFeature;
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return error.InvalidData;

    var frame: Frame = .{};
    var have_frame = false;
    var preset: Preset = .{};
    var restart_interval: u16 = 0;
    var samples: ?[]u16 = null;
    errdefer if (samples) |s| gpa.free(s);
    var decoded_mask: u8 = 0;

    // missing EOI: accept if complete
    var it: jpg_misc.Segments = .{ .data = data };
    while (try nextSegment(&it)) |segment| {
        const seg = segment.body;
        switch (segment.marker) {
            .EOI => break,
            .SOF55 => {
                if (have_frame) return error.InvalidData;
                frame = try parseFrame(seg);
                have_frame = true;
            },
            .SOF0, .SOF1, .SOF2, .SOF3, .SOF5, .SOF6, .SOF7, .SOF9, .SOF10, .SOF11, .SOF13, .SOF14, .SOF15, .SOF57 => return error.UnsupportedFeature,
            .LSE => {
                if (seg.len < 1) return error.InvalidData;
                switch (seg[0]) {
                    1 => {
                        if (seg.len < 11) return error.InvalidData;
                        preset = .{
                            .maxval = std.mem.readInt(u16, seg[1..3], .big),
                            .t1 = std.mem.readInt(u16, seg[3..5], .big),
                            .t2 = std.mem.readInt(u16, seg[5..7], .big),
                            .t3 = std.mem.readInt(u16, seg[7..9], .big),
                            .reset = std.mem.readInt(u16, seg[9..11], .big),
                        };
                    },
                    2, 3, 4 => return error.UnsupportedFeature,
                    else => return error.UnsupportedFeature,
                }
            },
            .DRI => {
                if (seg.len < 2) return error.InvalidData;
                restart_interval = std.mem.readInt(u16, seg[0..2], .big);
            },
            .SOS => {
                if (!have_frame) return error.InvalidData;
                if (seg.len < 1) return error.InvalidData;
                const ns = seg[0];
                if (ns < 1 or ns > frame.nc or seg.len < 4 + 2 * @as(usize, ns)) return error.InvalidData;
                var comps: [4]u8 = undefined;
                for (0..ns) |k| {
                    const id = seg[1 + 2 * k];
                    if (seg[2 + 2 * k] != 0) return error.UnsupportedFeature; // mapping table
                    comps[k] = @intCast(std.mem.indexOfScalar(u8, frame.ids[0..frame.nc], id) orelse return error.InvalidData);
                }
                const near = seg[1 + 2 * ns];
                const ilv = seg[2 + 2 * ns];
                if (seg[3 + 2 * ns] != 0) return error.UnsupportedFeature; // point transform
                switch (ilv) {
                    0 => if (ns != 1) return error.InvalidData,
                    1 => {},
                    2 => if (ns != 1) return error.UnsupportedFeature,
                    else => return error.InvalidData,
                }
                const params = try Params.init(frame.precision, near, preset);

                const pos = it.pos;
                const end = entropyEnd(data, pos);
                if (frame.height == 0) frame.height = try dnlHeight(data, end); // DNL after the first scan
                const pixels = @as(usize, frame.width) * frame.height;
                if (samples == null) {
                    // run mode codes a full line in at least one bit per 2^15 samples
                    if (@as(usize, frame.height) * ns > (end - pos) * 8 + 64) return error.UnexpectedEnd;
                    const s = try gpa.alloc(u16, pixels * frame.nc);
                    @memset(s, 0);
                    samples = s;
                }
                try decodeScan(gpa, samples.?, frame, comps[0..ns], &params, restart_interval, data[pos..end]);
                for (comps[0..ns]) |c| decoded_mask |= @as(u8, 1) << @intCast(c);
                it.pos = end;
            },
            else => {}, // SOI, TEM, RSTn, APPn, COM, DNL, ...
        }
    }

    if (!have_frame or samples == null) return error.InvalidData;
    if (decoded_mask != (@as(u8, 1) << @intCast(frame.nc)) - 1) return error.InvalidData;
    return .{
        .width = frame.width,
        .height = frame.height,
        .precision = frame.precision,
        .components = frame.nc,
        .samples = samples.?,
    };
}

/// Line buffers: index i + 1 holds sample i, index 0 is sample -1 and
/// index w + 1 is sample w (edge rules of A.2.1 / C.2.2).
const Lines = struct {
    buf: []i32,
    w: usize,

    fn prev(self: Lines, comp: usize, y: usize) []i32 {
        return self.line(comp, (y + 1) & 1);
    }
    fn cur(self: Lines, comp: usize, y: usize) []i32 {
        return self.line(comp, y & 1);
    }
    fn line(self: Lines, comp: usize, which: usize) []i32 {
        const stride = self.w + 2;
        return self.buf[(comp * 2 + which) * stride ..][0..stride];
    }
};

fn decodeScan(
    gpa: std.mem.Allocator,
    out: []u16,
    frame: Frame,
    comps: []const u8,
    p: *const Params,
    restart_interval: u16,
    entropy: []const u8,
) Error!void {
    const w: usize = frame.width;
    const nc: usize = frame.nc;
    const lines: Lines = .{ .buf = try gpa.alloc(i32, comps.len * 2 * (w + 2)), .w = w };
    defer gpa.free(lines.buf);
    @memset(lines.buf, 0);

    var br: BitReader = .{ .data = entropy };
    var st = State.init(p);

    for (0..frame.height) |y| {
        if (restart_interval != 0 and y > 0 and y % restart_interval == 0) {
            try br.restart();
            st = State.init(p);
            @memset(lines.buf, 0);
        }
        for (comps, 0..) |c, k| {
            const prev = lines.prev(k, y);
            const cur = lines.cur(k, y);
            cur[0] = prev[1];
            prev[w + 1] = prev[w];
            try decodeLine(&br, &st, p, prev, cur, w, &st.run_index[k]);
            for (0..w) |x| out[(y * w + x) * nc + c] = @intCast(cur[x + 1]);
        }
        try br.check();
    }
    try br.check();
}

fn decodeLine(br: *BitReader, st: *State, p: *const Params, prev: []const i32, cur: []i32, w: usize, run_index: *u8) Error!void {
    var x: usize = 0;
    while (x < w) {
        const ra = cur[x];
        const rb = prev[x + 1];
        const rc = prev[x];
        const rd = prev[x + 2];
        const d1 = rd - rb;
        const d2 = rb - rc;
        const d3 = rc - ra;

        if (@abs(d1) <= p.near and @abs(d2) <= p.near and @abs(d3) <= p.near) {
            // run mode (A.7)
            const remaining = w - x;
            var cnt: usize = 0;
            var interrupted = true;
            while (br.readBit() == 1) {
                const r = @as(usize, 1) << J[run_index.*];
                const take = @min(r, remaining - cnt);
                cnt += take;
                if (take == r and run_index.* < 31) run_index.* += 1;
                if (cnt == remaining) {
                    interrupted = false;
                    break;
                }
            }
            if (interrupted) {
                cnt += br.readBits(J[run_index.*]);
                if (cnt >= remaining) return error.InvalidData;
            }
            for (cur[x + 1 ..][0..cnt]) |*s| s.* = ra;
            x += cnt;
            if (!interrupted) break;

            // run interruption sample (A.7.2)
            const rb_i = prev[x + 1];
            const ritype: u1 = @intFromBool(@abs(ra - rb_i) <= p.near);
            const px = if (ritype == 1) ra else rb_i;
            const k = st.riK(ritype);
            const emerr = try br.golomb(k, p.limit - J[run_index.*] - 1, p.qbpp);
            const temp = emerr + ritype;
            const map = temp & 1;
            const abs_err = (temp + map) >> 1;
            const negative = (k != 0 or 2 * st.nn[ritype] >= st.n[365 + @as(usize, ritype)]) == (map == 1);
            const errval = if (negative) -abs_err else abs_err;
            st.updateRunInterruption(p, ritype, errval, emerr);
            const sign: i32 = if (ritype == 0 and ra > rb_i) -1 else 1;
            cur[x + 1] = p.reconstruct(px, sign * errval);
            if (run_index.* > 0) run_index.* -= 1;
            x += 1;
            continue;
        }

        // regular mode (A.3 - A.6)
        const ctx = State.context(p, ra, rb, rc, rd);
        const px = st.correctedPrediction(p, medPredict(ra, rb, rc), ctx);
        const k = State.golombK(st.n[ctx.q], st.a[ctx.q]);
        const merr = try br.golomb(k, p.limit, p.qbpp);
        var errval: i32 = undefined;
        if (st.specialMap(p, k, ctx.q)) {
            errval = if (merr & 1 == 1) (merr - 1) >> 1 else -(merr >> 1) - 1;
        } else {
            errval = if (merr & 1 == 0) merr >> 1 else -((merr + 1) >> 1);
        }
        st.updateRegular(p, ctx.q, errval);
        cur[x + 1] = p.reconstruct(px, ctx.sign * errval);
        x += 1;
    }
}

// ---------------------------------------------------------------- tests
//
// A small encoder mirroring the decoder (lossless and near-lossless,
// ILV 0 / 1, restarts, optional LSE), test-only.

const testing = std.testing;

const TestWriter = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    byte: u8 = 0,
    nbits: u4 = 0,
    cap: u4 = 8,

    fn bit(self: *TestWriter, gpa: std.mem.Allocator, b: u1) !void {
        self.byte = (self.byte << 1) | b;
        self.nbits += 1;
        if (self.nbits == self.cap) {
            try self.out.append(gpa, self.byte);
            self.cap = if (self.byte == 0xFF) 7 else 8;
            self.byte = 0;
            self.nbits = 0;
        }
    }

    fn bits(self: *TestWriter, gpa: std.mem.Allocator, v: u32, n: u32) !void {
        var i = n;
        while (i > 0) {
            i -= 1;
            try self.bit(gpa, @intCast((@as(u64, v) >> @intCast(i)) & 1));
        }
    }

    /// Zero-pads to a byte boundary (a byte after 0xFF still needs its 0 bit).
    fn flush(self: *TestWriter, gpa: std.mem.Allocator) !void {
        while (self.nbits != 0) try self.bit(gpa, 0);
        if (self.cap == 7) try self.bits(gpa, 0, 7);
    }

    fn golomb(self: *TestWriter, gpa: std.mem.Allocator, k: u5, limit: i32, qbpp: u32, merr: i32) !void {
        const max: u32 = @intCast(limit - @as(i32, @intCast(qbpp)) - 1);
        const high: u32 = @intCast(merr >> k);
        if (high < max) {
            try self.bits(gpa, 0, high);
            try self.bit(gpa, 1);
            try self.bits(gpa, @as(u32, @intCast(merr)) & ((@as(u32, 1) << k) - 1), k);
        } else {
            try self.bits(gpa, 0, max);
            try self.bit(gpa, 1);
            try self.bits(gpa, @intCast(merr - 1), qbpp);
        }
    }
};

fn quantizeError(p: *const Params, e: i32) i32 {
    var q = if (e > 0) @divTrunc(e + p.near, 2 * p.near + 1) else -@divTrunc(p.near - e, 2 * p.near + 1);
    if (q < 0) q += p.range;
    if (q >= @divTrunc(p.range + 1, 2)) q -= p.range;
    return q;
}

fn encodeLine(gpa: std.mem.Allocator, bw: *TestWriter, st: *State, p: *const Params, prev: []const i32, cur: []i32, src: []const i32, run_index: *u8) !void {
    const w = src.len;
    var x: usize = 0;
    while (x < w) {
        const ra = cur[x];
        const rb = prev[x + 1];
        const rc = prev[x];
        const rd = prev[x + 2];
        if (@abs(rd - rb) <= p.near and @abs(rb - rc) <= p.near and @abs(rc - ra) <= p.near) {
            var cnt: usize = 0;
            while (x + cnt < w and @abs(src[x + cnt] - ra) <= p.near) cnt += 1;
            for (cur[x + 1 ..][0..cnt]) |*s| s.* = ra;
            const eol = x + cnt == w;
            var rem = cnt;
            while (rem >= @as(usize, 1) << J[run_index.*]) {
                try bw.bit(gpa, 1);
                rem -= @as(usize, 1) << J[run_index.*];
                if (run_index.* < 31) run_index.* += 1;
            }
            x += cnt;
            if (eol) {
                if (rem > 0) try bw.bit(gpa, 1);
                break;
            }
            try bw.bit(gpa, 0);
            try bw.bits(gpa, @intCast(rem), J[run_index.*]);

            const rb_i = prev[x + 1];
            const ritype: u1 = @intFromBool(@abs(ra - rb_i) <= p.near);
            const px = if (ritype == 1) ra else rb_i;
            const sign: i32 = if (ritype == 0 and ra > rb_i) -1 else 1;
            const errval = quantizeError(p, sign * (src[x] - px));
            const k = st.riK(ritype);
            const q = 365 + @as(usize, ritype);
            const map: i32 = if (k == 0 and errval > 0 and 2 * st.nn[ritype] < st.n[q])
                1
            else if (errval < 0 and 2 * st.nn[ritype] >= st.n[q])
                1
            else if (errval < 0 and k != 0)
                1
            else
                0;
            const emerr = 2 * @as(i32, @intCast(@abs(errval))) - ritype - map;
            try bw.golomb(gpa, k, p.limit - J[run_index.*] - 1, p.qbpp, emerr);
            st.updateRunInterruption(p, ritype, errval, emerr);
            cur[x + 1] = p.reconstruct(px, sign * errval);
            if (run_index.* > 0) run_index.* -= 1;
            x += 1;
            continue;
        }
        const ctx = State.context(p, ra, rb, rc, rd);
        const px = st.correctedPrediction(p, medPredict(ra, rb, rc), ctx);
        const errval = quantizeError(p, ctx.sign * (src[x] - px));
        const k = State.golombK(st.n[ctx.q], st.a[ctx.q]);
        const merr: i32 = if (st.specialMap(p, k, ctx.q))
            (if (errval >= 0) 2 * errval + 1 else -2 * (errval + 1))
        else
            (if (errval >= 0) 2 * errval else -2 * errval - 1);
        try bw.golomb(gpa, k, p.limit, p.qbpp, merr);
        st.updateRegular(p, ctx.q, errval);
        cur[x + 1] = p.reconstruct(px, ctx.sign * errval);
        x += 1;
    }
}

pub const TestOptions = struct {
    near: u8 = 0,
    ilv: u8 = 0,
    restart_interval: u16 = 0,
    preset: ?Preset = null,
};

/// Test / benchmark encoder (bit-at-a-time, unoptimised; not a supported API).
pub fn testEncode(gpa: std.mem.Allocator, w: u16, h: u16, precision: u8, nc: u8, samples: []const u16, opts: TestOptions) ![]u8 {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    errdefer o.deinit(gpa);
    const be = struct {
        fn u16be(v: u16) [2]u8 {
            return .{ @intCast(v >> 8), @truncate(v) };
        }
    }.u16be;
    try o.appendSlice(gpa, &.{ 0xFF, 0xD8, 0xFF, 0xF7 });
    try o.appendSlice(gpa, &be(@intCast(8 + 3 * @as(u16, nc))));
    try o.append(gpa, precision);
    try o.appendSlice(gpa, &be(h));
    try o.appendSlice(gpa, &be(w));
    try o.append(gpa, nc);
    for (0..nc) |c| try o.appendSlice(gpa, &.{ @intCast(c + 1), 0x11, 0 });
    if (opts.preset) |ps| {
        try o.appendSlice(gpa, &.{ 0xFF, 0xF8, 0x00, 0x0D, 0x01 });
        for ([_]u16{ ps.maxval, ps.t1, ps.t2, ps.t3, ps.reset }) |v| try o.appendSlice(gpa, &be(v));
    }
    if (opts.restart_interval != 0) {
        try o.appendSlice(gpa, &.{ 0xFF, 0xDD, 0x00, 0x04 });
        try o.appendSlice(gpa, &be(opts.restart_interval));
    }
    const p = try Params.init(precision, opts.near, opts.preset orelse .{});
    const scans: usize = if (opts.ilv == 0) nc else 1;
    const per_scan: usize = if (opts.ilv == 0) 1 else nc;
    const wz: usize = w;
    const lines: Lines = .{ .buf = try gpa.alloc(i32, per_scan * 2 * (wz + 2)), .w = wz };
    defer gpa.free(lines.buf);
    const src = try gpa.alloc(i32, wz);
    defer gpa.free(src);

    for (0..scans) |s| {
        try o.appendSlice(gpa, &.{ 0xFF, 0xDA });
        try o.appendSlice(gpa, &be(@intCast(6 + 2 * per_scan)));
        try o.append(gpa, @intCast(per_scan));
        for (0..per_scan) |k| try o.appendSlice(gpa, &.{ @intCast(s + k + 1), 0 });
        try o.appendSlice(gpa, &.{ opts.near, opts.ilv, 0 });

        var bw: TestWriter = .{ .out = o };
        var st = State.init(&p);
        @memset(lines.buf, 0);
        var rst: u8 = 0;
        for (0..h) |y| {
            if (opts.restart_interval != 0 and y > 0 and y % opts.restart_interval == 0) {
                try bw.flush(gpa);
                try bw.out.appendSlice(gpa, &.{ 0xFF, 0xD0 + rst });
                rst = (rst + 1) & 7;
                bw.cap = 8;
                st = State.init(&p);
                @memset(lines.buf, 0);
            }
            for (0..per_scan) |k| {
                const c = s + k;
                for (src, 0..) |*v, x| v.* = samples[(y * wz + x) * nc + c];
                const prev = lines.prev(k, y);
                const cur = lines.cur(k, y);
                cur[0] = prev[1];
                prev[wz + 1] = prev[wz];
                try encodeLine(gpa, &bw, &st, &p, prev, cur, src, &st.run_index[k]);
            }
        }
        try bw.flush(gpa);
        o = bw.out;
    }
    try o.appendSlice(gpa, &.{ 0xFF, 0xD9 });
    return o.toOwnedSlice(gpa);
}

fn testImage(gpa: std.mem.Allocator, w: usize, h: usize, nc: usize, precision: u8, seed: u64) ![]u16 {
    const s = try gpa.alloc(u16, w * h * nc);
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    const max: u32 = (@as(u32, 1) << @intCast(precision)) - 1;
    for (0..h) |y| for (0..w) |x| for (0..nc) |c| {
        const i = (y * w + x) * nc + c;
        // flat regions (run mode), gradients and noise
        const v: u32 = if ((x / 8 + y / 5) % 3 == 0)
            @intCast(max / 3)
        else if ((x + y) % 7 == 0)
            r.uintAtMost(u32, max)
        else
            @intCast((x * 3 + y * 5 + c * 17 + r.uintLessThan(u32, 4)) % (max + 1));
        s[i] = @intCast(v);
    };
    return s;
}

fn roundTrip(w: u16, h: u16, nc: u8, precision: u8, opts: TestOptions, seed: u64) !void {
    const gpa = testing.allocator;
    const img = try testImage(gpa, w, h, nc, precision, seed);
    defer gpa.free(img);
    const enc = try testEncode(gpa, w, h, precision, nc, img, opts);
    defer gpa.free(enc);
    const dec = try decode(gpa, enc);
    defer gpa.free(dec.samples);
    try testing.expectEqual(w, dec.width);
    try testing.expectEqual(h, dec.height);
    try testing.expectEqual(precision, dec.precision);
    try testing.expectEqual(nc, dec.components);
    for (img, dec.samples) |a, b| {
        const diff = @abs(@as(i32, a) - @as(i32, b));
        if (diff > opts.near) {
            std.debug.print("sample {} decoded {} (near {})\n", .{ a, b, opts.near });
            return error.TestUnexpectedResult;
        }
    }
}

test "golombK closed form matches the loop" {
    var n: i32 = 1;
    while (n < 300) : (n += 7) {
        var a: i32 = 0;
        while (a < 1 << 26) : (a = a * 3 + 1) {
            try testing.expectEqual(State.golombKLoop(n, a), State.golombK(n, a));
            try testing.expectEqual(State.golombKLoop(n, a + 1), State.golombK(n, a + 1));
        }
    }
    try testing.expectEqual(@as(u5, 24), State.golombK(1, std.math.maxInt(i32)));
}

test "T.87 Annex H.3 example (4x4, 8 bit, lossless)" {
    const data = [_]u8{
        0xFF, 0xD8, 0xFF, 0xF7, 0x00, 0x0B, 0x08, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x11, 0x00,
        0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x6C, 0x80,
        0x20, 0x8E, 0x01, 0xC0, 0x00, 0x00, 0x57, 0x40, 0x00, 0x00, 0x6E, 0xE6, 0x00, 0x00, 0x01,
        0xBC, 0x18, 0x00, 0x00, 0x05, 0xD8, 0x00, 0x00, 0x91, 0x60, 0xFF, 0xD9,
    };
    const dec = try decode(testing.allocator, &data);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqualSlices(u16, &.{
        0,   0,   90,  74,
        68,  50,  43,  205,
        64,  145, 145, 145,
        100, 145, 145, 145,
    }, dec.samples);
}

test "lossless round trip, various precisions" {
    for ([_]u8{ 2, 5, 8, 12, 16 }) |prec| try roundTrip(41, 17, 1, prec, .{}, prec);
}

test "near lossless" {
    for ([_]u8{ 1, 3, 10 }) |near| {
        try roundTrip(33, 21, 1, 8, .{ .near = near }, near);
        try roundTrip(33, 21, 1, 12, .{ .near = near }, 100 + near);
    }
}

test "constant and tiny images (run mode)" {
    const gpa = testing.allocator;
    for ([_][2]u16{ .{ 1, 1 }, .{ 1, 7 }, .{ 7, 1 }, .{ 300, 3 } }) |dims| {
        const img = try gpa.alloc(u16, @as(usize, dims[0]) * dims[1]);
        defer gpa.free(img);
        @memset(img, 1000);
        const enc = try testEncode(gpa, dims[0], dims[1], 12, 1, img, .{});
        defer gpa.free(enc);
        const dec = try decode(gpa, enc);
        defer gpa.free(dec.samples);
        try testing.expectEqualSlices(u16, img, dec.samples);
    }
    try roundTrip(1, 9, 1, 8, .{}, 1);
    try roundTrip(9, 1, 1, 8, .{}, 2);
}

test "multi component, ILV none and line" {
    try roundTrip(23, 11, 3, 8, .{ .ilv = 0 }, 1);
    try roundTrip(23, 11, 3, 8, .{ .ilv = 1 }, 2);
    try roundTrip(23, 11, 2, 12, .{ .ilv = 1, .near = 2 }, 3);
}

test "restart intervals" {
    try roundTrip(29, 19, 1, 10, .{ .restart_interval = 1 }, 4);
    try roundTrip(29, 19, 1, 16, .{ .restart_interval = 4 }, 5);
    try roundTrip(29, 19, 3, 8, .{ .restart_interval = 3, .ilv = 1 }, 6);
}

test "LSE preset parameters" {
    try roundTrip(31, 13, 1, 8, .{ .preset = .{ .t1 = 2, .t2 = 5, .t3 = 9, .reset = 32 } }, 7);
    // MAXVAL below 2^P - 1 (the image stays within it)
    const gpa = testing.allocator;
    const img = try testImage(gpa, 20, 10, 1, 9, 8);
    defer gpa.free(img);
    const enc = try testEncode(gpa, 20, 10, 12, 1, img, .{ .preset = .{ .maxval = 511 } });
    defer gpa.free(enc);
    const dec = try decode(gpa, enc);
    defer gpa.free(dec.samples);
    try testing.expectEqualSlices(u16, img, dec.samples);

    // mapping-table LSE ids are unsupported
    try testing.expectError(error.UnsupportedFeature, decode(gpa, &.{ 0xFF, 0xD8, 0xFF, 0xF8, 0x00, 0x05, 0x02, 0x01, 0x01 }));
}

test "truncated and garbled input" {
    const gpa = testing.allocator;
    const img = try testImage(gpa, 32, 32, 1, 12, 11);
    defer gpa.free(img);
    const enc = try testEncode(gpa, 32, 32, 12, 1, img, .{});
    defer gpa.free(enc);

    for (0..enc.len - 2) |n| {
        if (decode(gpa, enc[0..n])) |d| {
            gpa.free(d.samples);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try testing.expectError(error.UnexpectedEnd, decode(gpa, enc[0 .. enc.len - 40]));

    const copy = try gpa.dupe(u8, enc);
    defer gpa.free(copy);
    var rng = std.Random.DefaultPrng.init(5);
    for (0..300) |_| {
        @memcpy(copy, enc);
        const i = rng.random().uintLessThan(usize, copy.len);
        copy[i] ^= @as(u8, 1) << rng.random().int(u3);
        if (decode(gpa, copy)) |d| gpa.free(d.samples) else |_| {}
    }
    try testing.expectError(error.InvalidData, decode(gpa, "nope"));
    try testing.expectError(error.UnsupportedFeature, decode(gpa, &.{ 0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x02 }));
}
