//! ITU T.81 lossless JPEG (SOF3, Huffman coded, "process 14"): predictors 1..7,
//! point transform, 2..16 bit precision, 1..4 components (interleaved scans need
//! H = V = 1), restart intervals and DNL. Also a matching encoder (optimal
//! Huffman table).
//!
//! Raw API: `decode` -> 16-bit samples at their own precision; `encode`.
//! Codec path: jpg.zig sends SOF3 files to `info` / `decodeInto`, which scale the
//! samples to Image pixels (1 component -> .g, or .g16 above 8 bits; 3 -> .rgb; see narrow.zig).
//!
//! Shared with the DCT codec: marker walking (misc.Segments / entropyEnd), DHT
//! parsing and Huffman tables (huffman.zig: DecTable handles the 16-bit codes and
//! category 16 symbol as is), Huffman encode tables and the bit writer. The bit
//! reader stays specialised for speed (see BitReader).
const std = @import("std");
const Info = @import("../../info.zig");
const misc = @import("misc.zig");
const huffman = @import("huffman.zig");
const BitWriter = @import("bitwriter.zig");
const narrow = @import("narrow.zig");
const ImageError = @import("../error.zig").Error;

pub const Error = error{ InvalidData, UnexpectedEnd, UnsupportedFeature, OutOfMemory };

pub const Decoded = struct {
    width: u16,
    height: u16,
    precision: u8, // bits per sample (P)
    components: u8,
    /// width*height*components, component-interleaved per pixel
    samples: []u16,
};

// ---------------------------------------------------------------- bit reader

/// MSB-first reader over one entropy-coded segment. Undoes 0xFF00 stuffing;
/// at a marker or the end of the data it feeds zero bits and counts them, so
/// `overrun` can tell whether any of those were actually consumed.
///
/// Kept apart from jpg's bitreader.zig on purpose: this left-aligned layout
/// (peek = one shift, no mask) and the 48-bit SWAR refill decode lossless
/// streams ~20% faster than the shared right-aligned reader (Volume
/// `zig build bench -- dicom`: 1.57 vs 1.93 ms per 512x512 16-bit slice).
const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    /// left aligned
    acc: u64 = 0,
    count: u32 = 0,
    /// zero bits fed past a marker / the end
    virt: u32 = 0,

    fn fill(self: *BitReader) void {
        // Fast path: 8 bytes with no 0xFF (so no stuffing / marker) go in with
        // one big-endian load. 8 = the accumulator width, not a SIMD width.
        if (self.count <= 48 and self.pos + 8 <= self.data.len) {
            const x = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
            if (!hasFF(x)) {
                const take = (64 - self.count) / 8; // whole bytes that fit, 2..8
                const keep: u32 = 64 - take * 8;
                self.acc |= (x >> @intCast(keep)) << @intCast(keep - self.count);
                self.count += take * 8;
                self.pos += take;
                return;
            }
        }
        while (self.count <= 48) {
            var byte: u8 = 0;
            if (self.pos < self.data.len and self.data[self.pos] != 0xFF) {
                byte = self.data[self.pos];
                self.pos += 1;
            } else if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == 0x00) {
                byte = 0xFF;
                self.pos += 2;
            } else {
                self.virt += 8; // marker or end: leave pos there
            }
            self.acc |= @as(u64, byte) << @intCast(56 - self.count);
            self.count += 8;
        }
    }

    inline fn consume(self: *BitReader, n: u32) void {
        self.acc <<= @intCast(n);
        self.count -= n;
    }

    inline fn readBits(self: *BitReader, n: u32) u32 {
        if (n == 0) return 0;
        if (self.count < n) self.fill();
        const v: u32 = @intCast(self.acc >> @intCast(64 - n));
        self.consume(n);
        return v;
    }

    /// Huffman symbol when at least 16 bits are already buffered (jpg's
    /// DecTable: LOOKAHEAD-bit lookup, then the per-length max-code walk).
    inline fn decodeSymbolBuffered(self: *BitReader, t: *const huffman.DecTable) Error!u8 {
        const entry = t.lookup[@intCast(self.acc >> (64 - huffman.LOOKAHEAD))];
        if (entry >> 8 != 0) {
            self.consume(entry >> 8);
            return @truncate(entry);
        }
        inline for (huffman.LOOKAHEAD + 1..17) |len| {
            const code: i32 = @intCast(self.acc >> (64 - len));
            if (code <= t.maxcode[len]) {
                self.consume(len);
                return t.values[@intCast(code + t.delta[len])];
            }
        }
        return failure(self);
    }

    fn overrun(self: *const BitReader) bool {
        return self.virt > self.count;
    }

    /// Drops buffered bits and skips the RSTn marker at the current position.
    fn restart(self: *BitReader) Error!void {
        try check(self);
        self.acc = 0;
        self.count = 0;
        self.virt = 0;
        while (self.pos + 1 < self.data.len and self.data[self.pos] == 0xFF and self.data[self.pos + 1] == 0xFF)
            self.pos += 1;
        if (self.pos + 1 >= self.data.len) return error.UnexpectedEnd;
        if (self.data[self.pos] != 0xFF) return error.InvalidData;
        const m = self.data[self.pos + 1];
        if (m < 0xD0 or m > 0xD7) return error.InvalidData;
        self.pos += 2;
    }
};

/// True if any byte of `x` is 0xFF (exact SWAR zero-byte test on ~x).
inline fn hasFF(x: u64) bool {
    const ones: u64 = 0x0101_0101_0101_0101;
    return ((~x) -% ones) & x & (ones << 7) != 0;
}

// ---------------------------------------------------------------- shared-piece glue

fn nextSegment(it: *misc.Segments) Error!?misc.Segment {
    return it.next() catch |err| switch (err) {
        error.InvalidMarker => error.InvalidData,
        error.UnexpectedEndOfData => error.UnexpectedEnd,
    };
}

/// The error for a reader that hit an invalid code or ran out of data.
fn failure(br: *const BitReader) Error {
    return if (br.virt > 0 and br.pos >= br.data.len) error.UnexpectedEnd else error.InvalidData;
}

/// Fails if zero bits fed past the end of the segment were consumed.
fn check(br: *const BitReader) Error!void {
    if (br.overrun()) return failure(br);
}

/// Height from the DNL segment that must follow the first scan (ending at `end`).
fn dnlHeight(data: []const u8, end: usize) Error!u16 {
    if (end + 6 > data.len or data[end + 1] != @backingInt(misc.Marker.DNL)) return error.InvalidData;
    const h = std.mem.readInt(u16, data[end + 4 ..][0..2], .big);
    if (h == 0) return error.InvalidData;
    return h;
}

// ---------------------------------------------------------------- prediction

/// Prediction state shared by the decoder and encoder (H.1.2.1).
const Predictor = struct {
    selection: u8,
    default: i32,
    /// the line that uses the 1-D (Ra) predictor: start of scan / restart
    ra_line: usize = 0,
    /// the next MCU is the first of the scan or of a restart interval
    reset: bool = true,

    /// `buf` holds reconstructed (point-transformed) samples, interleaved by `nc`.
    inline fn predict(self: *const Predictor, buf: []const u16, w: usize, nc: usize, x: usize, y: usize, c: usize) i32 {
        if (self.reset) return self.default;
        const i = (y * w + x) * nc + c;
        if (y == self.ra_line) return buf[i - nc];
        const rb: i32 = buf[i - w * nc];
        if (x == 0) return rb;
        const ra: i32 = buf[i - nc];
        const rc: i32 = buf[i - w * nc - nc];
        return switch (self.selection) {
            1 => ra,
            2 => rb,
            3 => rc,
            4 => ra + rb - rc,
            5 => ra + ((rb - rc) >> 1),
            6 => rb + ((ra - rc) >> 1),
            else => (ra + rb) >> 1,
        };
    }
};

// ---------------------------------------------------------------- decoder

const ScanComp = struct { index: u8, table: u8 };

pub const Frame = struct {
    precision: u8 = 0,
    width: u16 = 0,
    height: u16 = 0,
    nc: u8 = 0,
    ids: [4]u8 = @splat(0),
    hv: [4]u8 = @splat(0x11),
};

/// Parses an SOF3 segment body.
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
        frame.hv[i] = seg[7 + 3 * i];
        if (frame.nc > 1 and frame.hv[i] != 0x11) return error.UnsupportedFeature;
    }
    return frame;
}

/// The frame header alone (height taken from DNL when the SOF leaves it 0).
pub fn readFrame(data: []const u8) Error!Frame {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return error.InvalidData;
    var frame: ?Frame = null;
    var it: misc.Segments = .{ .data = data };
    while (try nextSegment(&it)) |s| switch (s.marker) {
        .SOF3 => {
            if (frame != null) return error.InvalidData;
            frame = try parseFrame(s.body);
            if (frame.?.height != 0) return frame.?;
        },
        .SOS => {
            var f = frame orelse return error.InvalidData;
            f.height = try dnlHeight(data, misc.entropyEnd(data, it.pos));
            return f;
        },
        .EOI => break,
        else => {},
    };
    return error.InvalidData;
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return error.InvalidData;

    var frame: Frame = .{};
    var have_frame = false;
    var tables: [4]?huffman.DecTable = @splat(null);
    var ac_tables: [4]?huffman.DecTable = @splat(null); // class 1: unused by lossless scans
    var restart_interval: u16 = 0;
    var samples: ?[]u16 = null;
    errdefer if (samples) |s| gpa.free(s);
    var decoded_mask: u8 = 0;

    var it: misc.Segments = .{ .data = data };
    while (try nextSegment(&it)) |segment| {
        const seg = segment.body;
        switch (segment.marker) {
            .EOI => break,
            .SOF3 => {
                if (have_frame) return error.InvalidData;
                frame = try parseFrame(seg);
                have_frame = true;
            },
            .SOF0, .SOF1, .SOF2, .SOF5, .SOF6, .SOF7, .SOF9, .SOF10, .SOF11, .SOF13, .SOF14, .SOF15, .DAC, .SOF55 => return error.UnsupportedFeature,
            .DHT => huffman.parseDht(seg, &tables, &ac_tables) catch return error.InvalidData,
            .DRI => {
                if (seg.len < 2) return error.InvalidData;
                restart_interval = std.mem.readInt(u16, seg[0..2], .big);
            },
            .SOS => {
                if (!have_frame) return error.InvalidData;
                if (seg.len < 1) return error.InvalidData;
                const ns = seg[0];
                if (ns < 1 or ns > frame.nc or seg.len < 4 + 2 * @as(usize, ns)) return error.InvalidData;
                var comps: [4]ScanComp = undefined;
                for (0..ns) |k| {
                    const id = seg[1 + 2 * k];
                    const td = seg[2 + 2 * k] >> 4;
                    const idx = std.mem.indexOfScalar(u8, frame.ids[0..frame.nc], id) orelse return error.InvalidData;
                    if (td > 3 or tables[td] == null) return error.InvalidData;
                    comps[k] = .{ .index = @intCast(idx), .table = td };
                }
                const ss = seg[1 + 2 * ns];
                const al: u4 = @intCast(seg[3 + 2 * ns] & 0xF);
                if (ss < 1 or ss > 7) return error.InvalidData;
                if (al >= frame.precision) return error.InvalidData;

                const pos = it.pos;
                const end = misc.entropyEnd(data, pos);
                if (frame.height == 0) frame.height = try dnlHeight(data, end); // DNL after the first scan
                const pixels = @as(usize, frame.width) * frame.height;
                if (samples == null) {
                    // every sample takes at least one bit: refuse absurd sizes early
                    if (pixels * ns > (end - pos) * 8 + 64) return error.UnexpectedEnd;
                    const s = try gpa.alloc(u16, pixels * frame.nc);
                    @memset(s, 0);
                    samples = s;
                }
                var tbl_ptrs: [4]*const huffman.DecTable = undefined;
                for (0..ns) |k| tbl_ptrs[k] = &tables[comps[k].table].?;
                try decodeScan(samples.?, frame, comps[0..ns], tbl_ptrs[0..ns], ss, al, restart_interval, data[pos..end]);
                for (comps[0..ns]) |c| decoded_mask |= @as(u8, 1) << @intCast(c.index);
                it.pos = end;
            },
            else => {}, // SOI, TEM, RSTn, DQT, DNL, APPn, COM, ...: skip
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

// ---------------------------------------------------------------- codec path (8 bit)

/// Header of an SOF3 file for Image's codec path (jpg.zig dispatches here).
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

fn decodeScan(
    out: []u16,
    frame: Frame,
    comps: []const ScanComp,
    tables: []const *const huffman.DecTable,
    selection: u8,
    pt: u4,
    restart_interval: u16,
    entropy: []const u8,
) Error!void {
    const w: usize = frame.width;
    const h: usize = frame.height;
    const nc: usize = frame.nc;
    var br: BitReader = .{ .data = entropy };
    var pred: Predictor = .{
        .selection = selection,
        .default = @as(i32, 1) << @intCast(frame.precision - pt - 1),
    };
    var mcus_left: u32 = restart_interval;

    if (restart_interval == 0 and nc == 1) {
        // the common DICOM case: one component, no restarts -> rows with the
        // predictor chosen once per scan instead of per sample
        switch (selection) {
            inline 1...7 => |sel| try decodeGray(sel, out, w, h, tables[0], &br, pred.default),
            else => unreachable,
        }
    } else for (0..h) |y| {
        for (0..w) |x| {
            if (restart_interval != 0) {
                if (mcus_left == 0) {
                    try br.restart();
                    mcus_left = restart_interval;
                    pred.reset = true;
                }
                mcus_left -= 1;
            }
            if (pred.reset) pred.ra_line = y;
            for (comps, tables) |comp, t| {
                const c = comp.index;
                const px = pred.predict(out, w, nc, x, y, c);
                out[(y * w + x) * nc + c] = @truncate(@as(u32, @bitCast(px + try readDiff(&br, t))));
            }
            pred.reset = false;
        }
        try check(&br);
    }
    try check(&br);

    if (pt != 0) {
        var i: usize = 0;
        while (i < out.len) : (i += nc) {
            for (comps) |comp| out[i + comp.index] <<= pt;
        }
    }
}

/// One Huffman-coded difference (H.1.2.2): category symbol + extra bits.
inline fn readDiff(br: *BitReader, t: *const huffman.DecTable) Error!i32 {
    // one refill check per sample: a code (<= 16) + extra bits (<= 15) fit in 32
    if (br.count < 32) br.fill();
    const s = try br.decodeSymbolBuffered(t);
    return switch (s) {
        0 => 0,
        1...15 => blk: {
            const n: u5 = @intCast(s);
            const v: i32 = @intCast(br.acc >> @intCast(64 - @as(u32, n)));
            br.consume(n);
            break :blk if (v < (@as(i32, 1) << (n - 1))) v - (@as(i32, 1) << n) + 1 else v;
        },
        16 => 32768,
        else => error.InvalidData,
    };
}

/// Single-component scan without restart intervals; same predictions as
/// `Predictor.predict` (first row: Ra, first column: Rb, first sample: default).
fn decodeGray(comptime sel: u8, out: []u16, w: usize, h: usize, t: *const huffman.DecTable, br: *BitReader, default: i32) Error!void {
    for (0..h) |y| {
        const row = out[y * w ..][0..w];
        if (y == 0) {
            var prev: i32 = default;
            for (row) |*o| {
                o.* = @truncate(@as(u32, @bitCast(prev + try readDiff(br, t))));
                prev = o.*;
            }
        } else {
            const up = out[(y - 1) * w ..][0..w];
            var ra: i32 = @as(u16, @truncate(@as(u32, @bitCast(@as(i32, up[0]) + try readDiff(br, t)))));
            row[0] = @intCast(ra);
            for (1..w) |x| {
                const rb: i32 = up[x];
                const rc: i32 = up[x - 1];
                const px: i32 = switch (sel) {
                    1 => ra,
                    2 => rb,
                    3 => rc,
                    4 => ra + rb - rc,
                    5 => ra + ((rb - rc) >> 1),
                    6 => rb + ((ra - rc) >> 1),
                    else => (ra + rb) >> 1,
                };
                const v: u16 = @truncate(@as(u32, @bitCast(px + try readDiff(br, t))));
                row[x] = v;
                ra = v;
            }
        }
        try check(br);
    }
}

// ---------------------------------------------------------------- encoder

pub const EncodeOptions = struct {
    /// 1..7 (H.1.2.1)
    predictor: u8 = 1,
    point_transform: u4 = 0,
    /// in MCUs (pixels); 0 = none
    restart_interval: u16 = 0,
};

/// Lossless JPEG (SOF3, predictor 1, optimal Huffman table, one interleaved scan).
pub fn encode(gpa: std.mem.Allocator, width: u16, height: u16, precision: u8, components: u8, samples: []const u16) Error![]u8 {
    return encodeWith(gpa, width, height, precision, components, samples, .{});
}

fn category(d: i32) u8 {
    if (d == 32768) return 16;
    const a: u32 = @abs(d);
    return @intCast(32 - @clz(a));
}

pub fn encodeWith(
    gpa: std.mem.Allocator,
    width: u16,
    height: u16,
    precision: u8,
    components: u8,
    samples: []const u16,
    opts: EncodeOptions,
) Error![]u8 {
    if (precision < 2 or precision > 16) return error.InvalidData;
    if (components < 1 or components > 4) return error.UnsupportedFeature;
    if (width == 0 or height == 0) return error.InvalidData;
    if (opts.predictor < 1 or opts.predictor > 7) return error.InvalidData;
    if (opts.point_transform >= precision) return error.InvalidData;
    const w: usize = width;
    const nc: usize = components;
    const n = w * height * nc;
    if (samples.len != n) return error.InvalidData;

    // reconstructed (point-transformed) samples
    const rec = try gpa.alloc(u16, n);
    defer gpa.free(rec);
    for (rec, samples) |*r, s| {
        if (precision < 16 and s >> @intCast(precision) != 0) return error.InvalidData;
        r.* = s >> opts.point_transform;
    }

    // differences (mod 2^16, in -32767..32768)
    const diffs = try gpa.alloc(i32, n);
    defer gpa.free(diffs);
    var freq: [17]u32 = @splat(0);
    {
        var pred: Predictor = .{
            .selection = opts.predictor,
            .default = @as(i32, 1) << @intCast(precision - opts.point_transform - 1),
        };
        var mcus_left: u32 = opts.restart_interval;
        for (0..height) |y| for (0..w) |x| {
            if (opts.restart_interval != 0) {
                if (mcus_left == 0) {
                    mcus_left = opts.restart_interval;
                    pred.reset = true;
                }
                mcus_left -= 1;
            }
            if (pred.reset) pred.ra_line = y;
            for (0..nc) |c| {
                const i = (y * w + x) * nc + c;
                const px = pred.predict(rec, w, nc, x, y, c);
                var d: i32 = (@as(i32, rec[i]) - px) & 0xFFFF;
                if (d > 32768) d -= 65536;
                diffs[i] = d;
                freq[category(d)] += 1;
            }
            pred.reset = false;
        };
    }

    var bits: [16]u8 = undefined;
    var values: [17]u8 = undefined;
    const nvalues = optimalTable(freq, &bits, &values);
    const enc = huffman.encTable(.{ .bits = bits, .values = values[0..nvalues] });

    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, n + 1024);
    errdefer aw.deinit();
    writeStream(&aw.writer, width, height, precision, components, opts, &bits, values[0..nvalues], &enc, diffs) catch
        return error.OutOfMemory; // the only way an allocating writer fails
    return aw.toOwnedSlice();
}

fn writeStream(
    w: *std.Io.Writer,
    width: u16,
    height: u16,
    precision: u8,
    components: u8,
    opts: EncodeOptions,
    bits: *const [16]u8,
    values: []const u8,
    enc: *const [256]huffman.EncEntry,
    diffs: []const i32,
) std.Io.Writer.Error!void {
    const nc: usize = components;
    try w.writeAll(&.{ 0xFF, 0xD8 });
    // SOF3
    try w.writeAll(&.{ 0xFF, 0xC3 });
    try w.writeInt(u16, @intCast(8 + 3 * nc), .big);
    try w.writeByte(precision);
    try w.writeInt(u16, height, .big);
    try w.writeInt(u16, width, .big);
    try w.writeByte(components);
    for (0..nc) |c| try w.writeAll(&.{ @intCast(c + 1), 0x11, 0 });
    // DHT
    try w.writeAll(&.{ 0xFF, 0xC4 });
    try w.writeInt(u16, @intCast(19 + values.len), .big);
    try w.writeByte(0x00);
    try w.writeAll(bits);
    try w.writeAll(values);
    if (opts.restart_interval != 0) {
        try w.writeAll(&.{ 0xFF, 0xDD, 0x00, 0x04 });
        try w.writeInt(u16, opts.restart_interval, .big);
    }
    // SOS
    try w.writeAll(&.{ 0xFF, 0xDA });
    try w.writeInt(u16, @intCast(6 + 2 * nc), .big);
    try w.writeByte(components);
    for (0..nc) |c| try w.writeAll(&.{ @intCast(c + 1), 0x00 });
    try w.writeAll(&.{ opts.predictor, 0, opts.point_transform });

    var bw: BitWriter = .{ .w = w };
    var mcus_left: u32 = opts.restart_interval;
    var rst: u8 = 0;
    for (0..@as(usize, width) * height) |p| {
        if (opts.restart_interval != 0) {
            if (mcus_left == 0) {
                try bw.flush();
                try w.writeAll(&.{ 0xFF, 0xD0 + rst });
                rst = (rst + 1) & 7;
                mcus_left = opts.restart_interval;
            }
            mcus_left -= 1;
        }
        for (diffs[p * nc ..][0..nc]) |d| {
            const s = category(d);
            try bw.putBits(enc[s].code, @intCast(enc[s].len));
            if (s > 0 and s < 16) {
                const v: i32 = if (d < 0) d - 1 else d;
                try bw.putBits(@as(u32, @bitCast(v)), @intCast(s)); // putBits keeps the low s bits
            }
        }
    }
    try bw.flush();
    try w.writeAll(&.{ 0xFF, 0xD9 });
}

/// Optimal Huffman code lengths limited to 16 bits (T.81 K.2).
/// Returns the number of values written.
fn optimalTable(freq_in: [17]u32, bits_out: *[16]u8, values: *[17]u8) usize {
    const N = 18; // 17 categories + one reserved symbol (keeps the all-ones code unused)
    var freq: [N]u64 = undefined;
    for (0..17) |i| freq[i] = freq_in[i];
    freq[17] = 1;
    var codesize: [N]u32 = @splat(0);
    var others: [N]i32 = @splat(-1);

    while (true) {
        var v1: i32 = -1;
        var v2: i32 = -1;
        // least frequency, ties -> largest index
        for (0..N) |i| {
            if (freq[i] == 0) continue;
            if (v1 < 0 or freq[i] <= freq[@intCast(v1)]) v1 = @intCast(i);
        }
        for (0..N) |i| {
            if (freq[i] == 0 or i == v1) continue;
            if (v2 < 0 or freq[i] <= freq[@intCast(v2)]) v2 = @intCast(i);
        }
        if (v2 < 0) break;
        var a: usize = @intCast(v1);
        var b: usize = @intCast(v2);
        freq[a] += freq[b];
        freq[b] = 0;
        codesize[a] += 1;
        while (others[a] >= 0) {
            a = @intCast(others[a]);
            codesize[a] += 1;
        }
        others[a] = v2;
        codesize[b] += 1;
        while (others[b] >= 0) {
            b = @intCast(others[b]);
            codesize[b] += 1;
        }
    }

    var bits: [33]u32 = @splat(0);
    for (codesize) |cs| if (cs > 0) {
        bits[cs] += 1;
    };
    // limit to 16 bits (K.3)
    var i: usize = 32;
    while (i > 16) : (i -= 1) {
        while (bits[i] > 0) {
            var j = i - 2;
            while (bits[j] == 0) j -= 1;
            bits[i] -= 2;
            bits[i - 1] += 1;
            bits[j + 1] += 2;
            bits[j] -= 1;
        }
    }
    // drop the reserved symbol from the longest length
    i = 16;
    while (bits[i] == 0) i -= 1;
    bits[i] -= 1;
    for (0..16) |l| bits_out[l] = @intCast(bits[l + 1]);

    var n: usize = 0;
    for (1..33) |len| {
        for (0..17) |s| {
            if (codesize[s] == len) {
                values[n] = @intCast(s);
                n += 1;
            }
        }
    }
    // the reserved symbol (17) sorts last among the longest codes and is dropped
    var total: usize = 0;
    for (bits_out) |b| total += b;
    return total;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testImage(gpa: std.mem.Allocator, w: usize, h: usize, nc: usize, precision: u8, seed: u64) ![]u16 {
    const s = try gpa.alloc(u16, w * h * nc);
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    const max: u32 = (@as(u32, 1) << @intCast(precision)) - 1;
    for (0..h) |y| for (0..w) |x| for (0..nc) |c| {
        // smooth gradient + noise, with occasional extremes
        const base: u32 = @intCast((x * 7 + y * 13 + c * 50) % (max + 1));
        const noise = r.uintLessThan(u32, 9);
        var v = (base + noise) % (max + 1);
        if (r.uintLessThan(u32, 50) == 0) v = if (r.boolean()) max else 0;
        s[(y * w + x) * nc + c] = @intCast(v);
    };
    return s;
}

fn roundTrip(w: u16, h: u16, nc: u8, precision: u8, opts: EncodeOptions, seed: u64) !void {
    const gpa = testing.allocator;
    const img = try testImage(gpa, w, h, nc, precision, seed);
    defer gpa.free(img);
    const enc = try encodeWith(gpa, w, h, precision, nc, img, opts);
    defer gpa.free(enc);
    const dec = try decode(gpa, enc);
    defer gpa.free(dec.samples);
    try testing.expectEqual(w, dec.width);
    try testing.expectEqual(h, dec.height);
    try testing.expectEqual(precision, dec.precision);
    try testing.expectEqual(nc, dec.components);
    for (img, dec.samples) |a, b| {
        const expect = (a >> opts.point_transform) << opts.point_transform;
        try testing.expectEqual(expect, b);
    }
}

test "hand-assembled 2x2 stream" {
    // P=8, predictor 1, table: 00 -> 0, 01 -> 1, 10 -> 8.
    // Samples 128 129 / 128 0: diffs 0, +1, 0 (Rb), -128.
    // bits 00 01|1 00 10|01111111 + 1 pad -> 19 3F FF(00)
    const data = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xC3,
        0x00, 0x0B,
        0x08, 0x00,
        0x02, 0x00,
        0x02, 0x01,
        0x01, 0x11,
        0x00, 0xFF,
        0xC4, 0x00,
        0x16, 0x00,
        0,    3,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    1,
        8,    0xFF,
        0xDA, 0x00,
        0x08, 0x01,
        0x01, 0x00,
        0x01, 0x00,
        0x00, 0x19,
        0x3F, 0xFF,
        0x00, 0xFF,
        0xD9,
    };
    const dec = try decode(testing.allocator, &data);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqualSlices(u16, &.{ 128, 129, 128, 0 }, dec.samples);
    try testing.expectEqual(@as(u8, 8), dec.precision);
}

test "all predictors round trip" {
    for (1..8) |p| try roundTrip(37, 23, 1, 12, .{ .predictor = @intCast(p) }, p);
}

test "predictors with 16 bit and 8 bit precision" {
    for (1..8) |p| {
        try roundTrip(19, 11, 1, 16, .{ .predictor = @intCast(p) }, 100 + p);
        try roundTrip(19, 11, 1, 8, .{ .predictor = @intCast(p) }, 200 + p);
    }
}

test "2 bit precision" {
    try roundTrip(16, 9, 1, 2, .{}, 7);
}

test "point transform" {
    try roundTrip(20, 10, 1, 12, .{ .point_transform = 3, .predictor = 4 }, 1);
    try roundTrip(20, 10, 1, 16, .{ .point_transform = 15 }, 2);
}

test "restart intervals" {
    try roundTrip(17, 9, 1, 12, .{ .restart_interval = 17, .predictor = 6 }, 3); // one row
    try roundTrip(17, 9, 1, 12, .{ .restart_interval = 5, .predictor = 7 }, 4); // mid-row
    try roundTrip(17, 9, 3, 8, .{ .restart_interval = 34 }, 5);
}

test "interleaved components" {
    for (2..5) |nc| try roundTrip(13, 7, @intCast(nc), 10, .{ .predictor = 5 }, nc);
}

test "category 16 difference" {
    // 0 next to 32768 -> difference 32768
    const gpa = testing.allocator;
    const img = [_]u16{ 0, 32768, 65535, 0, 32768, 0, 1, 65535 };
    const enc = try encode(gpa, 4, 2, 16, 1, &img);
    defer gpa.free(enc);
    const dec = try decode(gpa, enc);
    defer gpa.free(dec.samples);
    try testing.expectEqualSlices(u16, &img, dec.samples);
}

test "constant image (single symbol table)" {
    const gpa = testing.allocator;
    const img: [64]u16 = @splat(128);
    const enc = try encode(gpa, 8, 8, 8, 1, &img);
    defer gpa.free(enc);
    const dec = try decode(gpa, enc);
    defer gpa.free(dec.samples);
    try testing.expectEqualSlices(u16, &img, dec.samples);
}

test "DNL defined height" {
    const gpa = testing.allocator;
    const img = try testImage(gpa, 6, 5, 1, 8, 9);
    defer gpa.free(img);
    const enc = try encode(gpa, 6, 5, 8, 1, img);
    defer gpa.free(enc);
    // zero the SOF3 height (offset: SOI 2 + marker 2 + len 2 + P 1) and append DNL
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, enc[0 .. enc.len - 2]);
    buf.items[7] = 0;
    buf.items[8] = 0;
    try buf.appendSlice(gpa, &.{ 0xFF, 0xDC, 0x00, 0x04, 0x00, 0x05, 0xFF, 0xD9 });
    const dec = try decode(gpa, buf.items);
    defer gpa.free(dec.samples);
    try testing.expectEqual(@as(u16, 5), dec.height);
    try testing.expectEqualSlices(u16, img, dec.samples);
}

test "truncated and garbled input" {
    const gpa = testing.allocator;
    const img = try testImage(gpa, 32, 32, 1, 12, 11);
    defer gpa.free(img);
    const enc = try encode(gpa, 32, 32, 12, 1, img);
    defer gpa.free(enc);

    // every truncation must fail cleanly (or decode if only EOI is missing)
    for (0..enc.len - 2) |n| {
        if (decode(gpa, enc[0..n])) |d| {
            gpa.free(d.samples);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try testing.expectError(error.UnexpectedEnd, decode(gpa, enc[0 .. enc.len - 40]));

    // flipped bits must never crash
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
    // baseline JPEG frame
    try testing.expectError(error.UnsupportedFeature, decode(gpa, &.{ 0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x02 }));
}

test "hasFF and the 8-byte refill around stuffed bytes" {
    try testing.expect(!hasFF(0));
    try testing.expect(!hasFF(0xFEFE_FEFE_FEFE_FEFE));
    try testing.expect(!hasFF(0x7F80_0001_FE00_10EF));
    for (0..8) |k| try testing.expect(hasFF(@as(u64, 0xFF) << @intCast(8 * k)));
    try testing.expect(hasFF(0xFF00_0000_0000_00FF));
    // bytes 00 FF 00 (stuffed) then plain bytes: read 8 bits at a time
    const data = [_]u8{ 0x12, 0xFF, 0x00, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44 };
    var br: BitReader = .{ .data = &data };
    for ([_]u32{ 0x12, 0xFF, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44 }) |want|
        try testing.expectEqual(want, br.readBits(8));
    try check(&br);
    _ = br.readBits(1); // past the end -> zero bits, counted
    try testing.expectError(error.UnexpectedEnd, check(&br));
}
