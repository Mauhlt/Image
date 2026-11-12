//! One-shot DEFLATE decoder (RFC 1951) with zlib (RFC 1950) and gzip (RFC 1952)
//! containers, for whole in-memory streams whose decoded size is known up front.
//!
//!     const r = try inflate.decompress(.gzip, compressed, out, .{});
//!     // r.out_len bytes of `out` were written, r.in_len bytes of input consumed
//!
//! The output buffer is also the LZ77 history, so there is no window and no copy.
//! Checksums (zlib Adler-32; gzip CRC-32 + ISIZE, and the header CRC when present)
//! are verified by default. Concatenated gzip members are decoded back to back.
//! Every malformed or truncated stream, or one that does not fit in `out`, returns
//! an error; nothing reads or writes outside the given slices.
//!
//! Design (after libdeflate): a 64-bit bit buffer refilled branchlessly with one
//! unaligned 8-byte load; Huffman tables whose single lookup yields a literal, or a
//! length/distance base with the codeword and extra-bit counts packed so one shift
//! consumes both (subtables for codes longer than the main table); a hot loop with no
//! per-symbol bounds checks while at least `fast_in` input bytes and `fast_out` output
//! bytes remain, falling back to a fully checked loop near either end; and match
//! copies in whole SIMD chunks (overlap handled by offset class).
//!
//! `decompressSplit` writes the first `head.len` bytes to `head` and the rest to
//! `out` (e.g. a NIfTI header and its voxels), with matches free to span the two.
const std = @import("std");
pub const crc32 = @import("crc32.zig");
pub const adler32 = @import("adler32.zig");

/// Match-copy chunk width in bytes: the SIMD tuning width (Colors/misc.zig `N`).
const V = @import("../Colors/misc.zig").N;
const Chunk = @Vector(V, u8);

pub const Container = enum { raw, zlib, gzip };

pub const Error = error{
    /// Input ended before the stream did.
    EndOfStream,
    InvalidBlockType,
    WrongStoredBlockNlen,
    InvalidDynamicBlockHeader,
    OversubscribedHuffmanTree,
    IncompleteHuffmanTree,
    MissingEndOfBlockCode,
    /// A code that is not part of the alphabet (unused Huffman code, length 286/287,
    /// distance 30/31).
    InvalidCode,
    /// A distance reaching before the start of the output (or of the gzip member).
    InvalidMatch,
    BadGzipHeader,
    BadZlibHeader,
    WrongGzipChecksum,
    WrongGzipSize,
    WrongZlibChecksum,
    /// The stream decodes to more bytes than the output can hold.
    OutputTooSmall,
};

pub const Options = struct {
    /// Check the container checksums (zlib Adler-32; gzip CRC-32, ISIZE, FHCRC).
    verify: bool = true,
    /// gzip: after a member, keep going while the remaining input starts with
    /// another gzip header. Anything else after a member is left unconsumed.
    multi_member: bool = true,
};

pub const Result = struct {
    /// Input bytes consumed, including the container header and footer(s).
    in_len: usize,
    /// Output bytes written (for `decompressSplit`: head and out together).
    out_len: usize,
};

/// Decodes `in` into `out`. Uses ~12 KiB of stack for the Huffman tables; keep a
/// `Decompressor` around instead to reuse them.
pub fn decompress(container: Container, in: []const u8, out: []u8, opts: Options) Error!Result {
    var d: Decompressor = undefined;
    return d.decompressSplit(container, in, &.{}, out, opts);
}

/// Like `decompress`, but the first `head.len` decoded bytes go to `head`.
pub fn decompressSplit(container: Container, in: []const u8, head: []u8, out: []u8, opts: Options) Error!Result {
    var d: Decompressor = undefined;
    return d.decompressSplit(container, in, head, out, opts);
}

/// Decoder scratch (the dynamic Huffman tables). Needs no initialisation and holds
/// no state between calls.
pub const Decompressor = struct {
    t: Tables,
    pre: [pre_enough]u32,
    lens: [288 + 32]u8,

    pub fn decompress(d: *Decompressor, container: Container, in: []const u8, out: []u8, opts: Options) Error!Result {
        return d.decompressSplit(container, in, &.{}, out, opts);
    }

    pub fn decompressSplit(d: *Decompressor, container: Container, in: []const u8, head: []u8, out: []u8, opts: Options) Error!Result {
        var o: Out = .{ .head = head, .out = out };
        var p: usize = 0;
        switch (container) {
            .raw => p = try d.deflate(in, 0, &o),
            .zlib => {
                if (in.len < 2) return error.EndOfStream;
                const cmf = in[0];
                const flg = in[1];
                // method 8, window <= 32 KiB, header check, no preset dictionary
                if (cmf & 0x0f != 8 or cmf >> 4 > 7 or (@as(u16, cmf) << 8 | flg) % 31 != 0 or flg & 0x20 != 0)
                    return error.BadZlibHeader;
                if (opts.verify) o.startCheck(.adler32);
                p = try d.deflate(in, 2, &o);
                if (in.len - p < 4) return error.EndOfStream;
                const want = std.mem.readInt(u32, in[p..][0..4], .big);
                p += 4;
                if (opts.verify) {
                    o.checksum();
                    if (o.sum != want) return error.WrongZlibChecksum;
                }
            },
            .gzip => while (true) {
                p = try gzipHeader(in, p, opts.verify);
                o.ms = o.pos();
                if (opts.verify) o.startCheck(.crc32);
                p = try d.deflate(in, p, &o);
                if (in.len - p < 8) return error.EndOfStream;
                const want_crc = std.mem.readInt(u32, in[p..][0..4], .little);
                const want_size = std.mem.readInt(u32, in[p + 4 ..][0..4], .little);
                p += 8;
                if (opts.verify) {
                    if (@as(u32, @truncate(o.pos() - o.ms)) != want_size) return error.WrongGzipSize;
                    o.checksum();
                    if (o.sum != want_crc) return error.WrongGzipChecksum;
                }
                if (!opts.multi_member or in.len - p < 2 or in[p] != 0x1f or in[p + 1] != 0x8b) break;
            },
        }
        return .{ .in_len = p, .out_len = o.pos() };
    }

    /// Decodes one raw deflate stream starting at `in[start]`; returns the index of
    /// the first byte after it (the stream ends byte-aligned).
    fn deflate(d: *Decompressor, in: []const u8, start: usize, o: *Out) Error!usize {
        var b: Bits = .{ .in = in, .ip = start };
        while (true) {
            b.refill();
            const final = b.take(1);
            switch (b.take(2)) {
                0 => try stored(&b, o),
                1 => try huffmanBlock(&b, o, &fixed),
                2 => {
                    try d.readDynamicHeader(&b);
                    try huffmanBlock(&b, o, &d.t);
                },
                else => return error.InvalidBlockType,
            }
            if (b.overread()) return error.EndOfStream;
            if (final != 0) break;
        }
        b.consume(b.left & 7);
        const end = b.ip - b.left / 8;
        if (end > in.len) return error.EndOfStream;
        return end;
    }

    fn readDynamicHeader(d: *Decompressor, b: *Bits) Error!void {
        b.refill();
        const hlit = b.take(5) + 257;
        const hdist = b.take(5) + 1;
        const hclen = b.take(4) + 4;
        if (hlit > 286 or hdist > 30) return error.InvalidDynamicBlockHeader;

        var pre_lens: [19]u8 = @splat(0);
        const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
        // 19 x 3 bits: refill now (>= 56 bits) and once more after 14 lengths
        b.refill();
        for (order[0..hclen], 0..) |sym, i| {
            if (i == 14) b.refill();
            pre_lens[sym] = @intCast(b.take(3));
        }
        try build(&d.pre, &pre_lens, &pre_results, pre_bits, .pre);

        const total = hlit + hdist;
        const lens = &d.lens;
        var i: usize = 0;
        while (i < total) {
            b.refill();
            const e = d.pre[b.buf & mask(pre_bits)];
            if (e & EXC != 0) return error.InvalidCode;
            b.consume(e & 0xff);
            const sym = e >> 16;
            switch (sym) {
                0...15 => {
                    lens[i] = @intCast(sym);
                    i += 1;
                },
                16 => {
                    if (i == 0) return error.InvalidDynamicBlockHeader;
                    const n = 3 + b.take(2);
                    if (i + n > total) return error.InvalidDynamicBlockHeader;
                    @memset(lens[i..][0..n], lens[i - 1]);
                    i += n;
                },
                17, 18 => {
                    const n = if (sym == 17) 3 + b.take(3) else 11 + b.take(7);
                    if (i + n > total) return error.InvalidDynamicBlockHeader;
                    @memset(lens[i..][0..n], 0);
                    i += n;
                },
                else => unreachable,
            }
        }
        if (b.overread()) return error.EndOfStream;
        if (lens[256] == 0) return error.MissingEndOfBlockCode;
        try build(&d.t.lit, lens[0..hlit], &lit_results, lit_bits, .lit);
        try build(&d.t.dist, lens[hlit..][0..hdist], &dist_results, dist_bits, .dist);
    }
};

// ───────────────────────────── output ─────────────────────────────

const Check = enum { none, crc32, adler32 };
/// Bytes decoded between checksum updates: well past the 32 KiB window (the hot data)
/// and well inside L2.
const check_chunk = 128 * 1024;

/// The logical output is `head ++ out`; positions below are logical unless noted.
const Out = struct {
    head: []u8,
    out: []u8,
    /// Bytes written to `head` / `out`. `o > 0` implies `hn == head.len`.
    hn: usize = 0,
    o: usize = 0,
    /// Start of the current gzip member: matches may not reach before it.
    ms: usize = 0,
    /// Running checksum of the logical bytes [ms, done) (zlib: [0, done)). The
    /// fast loop stops every `check_chunk` bytes so finished output is summed while
    /// still in cache, instead of in a second pass over the whole buffer.
    check: Check = .none,
    sum: u32 = 0,
    done: usize = 0,

    fn startCheck(s: *Out, c: Check) void {
        s.check = c;
        s.sum = if (c == .adler32) 1 else 0;
        s.done = s.pos();
    }

    /// Brings `sum` up to date with everything written so far.
    fn checksum(s: *Out) void {
        const end = s.pos();
        if (s.check == .none or s.done >= end) return;
        if (s.done < s.hn) s.feed(s.head[s.done..s.hn]);
        const from = @max(s.done, s.head.len) - s.head.len;
        if (from < s.o) s.feed(s.out[from..s.o]);
        s.done = end;
    }

    fn feed(s: *Out, bytes: []const u8) void {
        s.sum = switch (s.check) {
            .crc32 => crc32.update(s.sum, bytes),
            .adler32 => adler32.update(s.sum, bytes),
            .none => unreachable,
        };
    }

    /// Index in `out` where the fast loop should next pause for `checksum`.
    fn checkStop(s: *const Out) usize {
        if (s.check == .none) return std.math.maxInt(usize);
        return (s.done -| s.head.len) + check_chunk;
    }

    fn pos(s: *const Out) usize {
        return s.hn + s.o;
    }

    fn room(s: *const Out) usize {
        return s.head.len - s.hn + s.out.len - s.o;
    }

    fn get(s: *const Out, p: usize) u8 {
        return if (p < s.head.len) s.head[p] else s.out[p - s.head.len];
    }

    fn put(s: *Out, byte: u8) Error!void {
        if (s.hn < s.head.len) {
            s.head[s.hn] = byte;
            s.hn += 1;
        } else if (s.o < s.out.len) {
            s.out[s.o] = byte;
            s.o += 1;
        } else return error.OutputTooSmall;
    }

    /// Checked, bytewise match copy (any position, any overlap).
    fn match(s: *Out, dist: usize, len: usize) Error!void {
        if (dist > s.pos() - s.ms) return error.InvalidMatch;
        if (len > s.room()) return error.OutputTooSmall;
        for (0..len) |_| s.put(s.get(s.pos() - dist)) catch unreachable;
    }

    fn write(s: *Out, bytes: []const u8) Error!void {
        if (bytes.len > s.room()) return error.OutputTooSmall;
        const h = @min(bytes.len, s.head.len - s.hn);
        @memcpy(s.head[s.hn..][0..h], bytes[0..h]);
        s.hn += h;
        @memcpy(s.out[s.o..][0 .. bytes.len - h], bytes[h..]);
        s.o += bytes.len - h;
    }

    /// Index in `out` before which the current member's matches may not reach
    /// directly (bytes before it are in `head` or belong to an earlier member).
    fn floor(s: *const Out) usize {
        return s.ms -| s.head.len;
    }
};

// ───────────────────────────── bit reader ─────────────────────────────

const Bits = struct {
    in: []const u8,
    /// Next input byte to load. May run past `in.len`: missing bytes read as zero,
    /// and `overread` reports when any of those zero bits were actually consumed.
    ip: usize,
    buf: u64 = 0,
    /// Valid bits in `buf` (< 64). Bits above it are zero or the true next bits.
    left: u32 = 0,

    /// Tops up to 56..63 bits with one unaligned 8-byte load. Needs ip + 8 <= in.len.
    /// (8 bytes = one u64 bit buffer: dictated by the algorithm, not a SIMD width.)
    inline fn refillFast(b: *Bits) void {
        b.buf |= std.mem.readInt(u64, b.in[b.ip..][0..8], .little) << @intCast(b.left);
        b.ip += 7 - (b.left >> 3);
        b.left |= 56;
    }

    fn refillSlow(b: *Bits) void {
        while (b.left < 56) : (b.left += 8) {
            const byte: u64 = if (b.ip < b.in.len) b.in[b.ip] else 0;
            b.buf |= byte << @intCast(b.left);
            b.ip += 1;
        }
    }

    inline fn refill(b: *Bits) void {
        if (b.in.len - @min(b.in.len, b.ip) >= 8) b.refillFast() else b.refillSlow();
    }

    /// True if bits past the end of the input have been consumed.
    fn overread(b: *const Bits) bool {
        return b.ip > b.in.len and (b.ip - b.in.len) * 8 > b.left;
    }

    inline fn consume(b: *Bits, n: u32) void {
        b.buf >>= @intCast(n);
        b.left -= n;
    }

    inline fn take(b: *Bits, n: u5) u32 {
        const v: u32 = @truncate(b.buf & mask(n));
        b.consume(n);
        return v;
    }
};

inline fn mask(n: anytype) u64 {
    return (@as(u64, 1) << @intCast(n)) - 1;
}

// ───────────────────────────── blocks ─────────────────────────────

fn stored(b: *Bits, o: *Out) Error!void {
    b.consume(b.left & 7);
    b.refill();
    const len = b.take(16);
    const nlen = b.take(16);
    // hand the whole bytes still buffered back to the input
    b.ip -= b.left / 8;
    b.buf = 0;
    b.left = 0;
    if (b.ip > b.in.len) return error.EndOfStream;
    if (len != ~nlen & 0xffff) return error.WrongStoredBlockNlen;
    if (b.in.len - b.ip < len) return error.EndOfStream;
    try o.write(b.in[b.ip..][0..len]);
    b.ip += len;
}

/// Input bytes the fast loop needs left: two 8-byte refills per iteration, the second
/// starting at most 7 bytes after the first.
const fast_in = 16;
/// Output bytes the fast loop needs left: 3 literals + a 258-byte match + the copy's
/// overshoot (up to a chunk plus a stride remainder past the match end).
const fast_out = 3 + 258 + 2 * V;

fn huffmanBlock(b: *Bits, o: *Out, t: *const Tables) Error!void {
    const lt = &t.lit;
    const dt = &t.dist;
    while (true) {
        if (o.hn == o.head.len and b.ip <= b.in.len and b.in.len - b.ip >= fast_in and o.out.len - o.o >= fast_out) {
            const stop = o.checkStop();
            if (try fastLoop(b, o, t, stop)) return;
            if (o.o >= stop) o.checksum();
            continue;
        }
        // one symbol, every step checked
        b.refill();
        var e = lt[b.buf & mask(lit_bits)];
        if (e & SUB != 0) {
            b.consume(e & 0xff);
            e = lt[(e >> 16) + (b.buf & mask((e >> 8) & 0xf))];
        }
        const saved = b.buf;
        b.consume(e & 0xff);
        if (e & LITERAL != 0) {
            if (b.overread()) return error.EndOfStream;
            try o.put(@truncate(e >> 16));
            continue;
        }
        if (e & EXC != 0) {
            if (b.overread()) return error.EndOfStream;
            if (e & EOB != 0) return;
            return error.InvalidCode;
        }
        const len = (e >> 16) + extra(saved, e);
        b.refill();
        var de = dt[b.buf & mask(dist_bits)];
        if (de & SUB != 0) {
            b.consume(de & 0xff);
            de = dt[(de >> 16) + (b.buf & mask((de >> 8) & 0xf))];
        }
        if (de & EXC != 0) return if (b.overread()) error.EndOfStream else error.InvalidCode;
        const dsaved = b.buf;
        b.consume(de & 0xff);
        if (b.overread()) return error.EndOfStream;
        try o.match((de >> 16) + extra(dsaved, de), len);
    }
}

/// Extra-bit value of a length/distance entry, from the bit buffer before the entry
/// was consumed: the `total` low bits, minus the codeword.
inline fn extra(saved: u64, e: u32) u32 {
    return @as(u32, @truncate(saved & mask(e & 0xff))) >> @intCast((e >> 8) & 0xf);
}

inline fn extraFast(saved: u64, e: u32) u32 {
    const total: u6 = @truncate(e);
    const v: u32 = @truncate(saved & ((@as(u64, 1) << total) - 1));
    return v >> @as(u5, @truncate(e >> 8));
}

/// Decodes while the input and output margins hold. Returns true at end of block,
/// false when a margin ran out (state written back for the checked loop).
///
/// The next literal/length entry is always looked up right after the previous symbol
/// is consumed ("preloaded"), while >= 11 valid bits remain, so the table load
/// overlaps the output write / match copy instead of following the refill.
fn fastLoop(b: *Bits, o: *Out, t: *const Tables, out_stop: usize) Error!bool {
    const in = b.in;
    // `out` rebased at the current member's floor, so `op` is also the number of
    // bytes a match may reach back
    const floor = o.floor();
    const out = o.out[floor..];
    var buf = b.buf;
    var left = b.left;
    var ip = b.ip;
    var op = o.o - floor;
    const in_last = in.len - fast_in;
    const out_last = @min(out.len - fast_out, out_stop -| floor);
    var eob = false;
    // `left` here: only its low 6 bits are the valid-bit count. Consuming subtracts
    // the whole entry (its low byte is the bit count; no borrow crosses into the
    // low byte since the count never goes negative), saving a mask per symbol.
    // the first lookup needs 11 valid bits: refill once up front
    buf |= std.mem.readInt(u64, in[ip..][0..8], .little) << @as(u6, @truncate(left));
    ip += 7 - ((left >> 3) & 7);
    left |= 56;
    var e = t.lit[buf & mask(lit_bits)];
    loop: while (ip <= in_last and op <= out_last) {
        // refill: one 8-byte load, 56..63 valid bits after (the low bits `e` was
        // looked up from are unchanged)
        buf |= std.mem.readInt(u64, in[ip..][0..8], .little) << @as(u6, @truncate(left));
        ip += 7 - ((left >> 3) & 7);
        left |= 56;

        // Consume each entry right after looking it up, whatever it is (literal,
        // length, subtable pointer, end of block: the low byte is always the right
        // count), so the shift never waits for the type test.
        var saved = buf;
        buf >>= @as(u6, @truncate(e));
        left -%= e;
        if (e & LITERAL != 0) {
            // main-table literals are <= 11 bits: up to three, then the next entry
            // (<= 11 + 4 + 5 bits), fit in 56
            out[op] = @truncate(e >> 16);
            op += 1;
            e = t.lit[buf & mask(lit_bits)];
            saved = buf;
            buf >>= @as(u6, @truncate(e));
            left -%= e;
            if (e & LITERAL != 0) {
                out[op] = @truncate(e >> 16);
                op += 1;
                e = t.lit[buf & mask(lit_bits)];
                saved = buf;
                buf >>= @as(u6, @truncate(e));
                left -%= e;
                if (e & LITERAL != 0) {
                    out[op] = @truncate(e >> 16);
                    op += 1;
                    e = t.lit[buf & mask(lit_bits)];
                    continue :loop;
                }
            }
        }
        // `e` is consumed and `saved` holds the bits from before it
        if (e & EXC != 0) {
            if (e & SUB != 0) {
                e = t.lit[(e >> 16) + (buf & mask((e >> 8) & 0xf))];
                saved = buf;
                buf >>= @as(u6, @truncate(e));
                left -%= e;
                if (e & LITERAL != 0) {
                    out[op] = @truncate(e >> 16);
                    op += 1;
                    e = t.lit[buf & mask(lit_bits)];
                    continue :loop;
                }
            }
            if (e & EXC != 0) {
                if (e & EOB == 0) return error.InvalidCode;
                eob = true;
                break :loop;
            }
        }
        // length
        const len = (e >> 16) + extraFast(saved, e);

        // distance: refill again (<= 7 bytes advanced since the last one)
        buf |= std.mem.readInt(u64, in[ip..][0..8], .little) << @as(u6, @truncate(left));
        ip += 7 - ((left >> 3) & 7);
        left |= 56;
        var de = t.dist[buf & mask(dist_bits)];
        if (de & EXC != 0) {
            if (de & SUB == 0) return error.InvalidCode;
            buf >>= @as(u6, @truncate(de));
            left -%= de;
            de = t.dist[(de >> 16) + (buf & mask((de >> 8) & 0xf))];
            if (de & EXC != 0) return error.InvalidCode;
        }
        saved = buf;
        buf >>= @as(u6, @truncate(de));
        left -%= de;
        const dist = (de >> 16) + extraFast(saved, de);
        e = t.lit[buf & mask(lit_bits)]; // >= 28 bits left

        if (dist > op) {
            // reaches into `head` or past the member start: checked path
            @branchHint(.cold);
            op = try rareMatch(o, op + floor, dist, len) - floor;
            continue :loop;
        }
        copyMatch(out, op, dist, len);
        op += len;
    }
    b.buf = buf;
    b.left = left & 63;
    b.ip = ip;
    o.o = op + floor;
    return eob;
}

noinline fn rareMatch(o: *Out, op: usize, dist: u32, len: u32) Error!usize {
    o.o = op;
    try o.match(dist, len);
    return o.o;
}

/// Copies `len` bytes from `dist` back. May write up to V + 7 bytes past the end
/// (the caller guarantees the room); reads only bytes before the write position, or
/// (small offsets) up to 8 bytes at the source, of which only the first `dist` matter.
inline fn copyMatch(out: []u8, op: usize, dist: usize, len: usize) void {
    const end = op + len;
    var d = op;
    if (dist >= V) {
        var s = op - dist;
        while (true) {
            const c: Chunk = out[s..][0..V].*;
            out[d..][0..V].* = c;
            d += V;
            s += V;
            if (d >= end) break;
        }
    } else if (dist >= 16) {
        var s = op - dist;
        while (true) {
            const c: @Vector(16, u8) = out[s..][0..16].*;
            out[d..][0..16].* = c;
            d += 16;
            s += 16;
            if (d >= end) break;
        }
    } else if (dist >= 8) {
        var s = op - dist;
        while (true) {
            out[d..][0..8].* = out[s..][0..8].*;
            d += 8;
            s += 8;
            if (d >= end) break;
        }
    } else {
        // offset 1..7: spread the period over a chunk, store it at a stride that is a
        // multiple of the period
        const src: @Vector(8, u8) = out[op - dist ..][0..8].*;
        const pat: Chunk, const stride: usize = switch (dist) {
            inline 1...7 => |k| .{ @shuffle(u8, src, undefined, periodMask(k)), V - V % k },
            else => unreachable,
        };
        while (true) {
            out[d..][0..V].* = pat;
            d += stride;
            if (d >= end) break;
        }
    }
}

fn periodMask(comptime k: usize) [V]i32 {
    var m: [V]i32 = undefined;
    for (&m, 0..) |*x, i| x.* = @intCast(i % k);
    return m;
}

// ───────────────────────────── gzip header ─────────────────────────────

fn gzipHeader(in: []const u8, start: usize, verify: bool) Error!usize {
    var p = start;
    if (in.len - p < 10) return error.EndOfStream;
    const h = in[p..][0..10];
    if (h[0] != 0x1f or h[1] != 0x8b or h[2] != 8) return error.BadGzipHeader;
    const flg = h[3];
    if (flg & 0xe0 != 0) return error.BadGzipHeader; // reserved flags
    p += 10;
    if (flg & 0x04 != 0) { // FEXTRA
        if (in.len - p < 2) return error.EndOfStream;
        const xlen = std.mem.readInt(u16, in[p..][0..2], .little);
        p += 2;
        if (in.len - p < xlen) return error.EndOfStream;
        p += xlen;
    }
    inline for (.{ 0x08, 0x10 }) |f| { // FNAME, FCOMMENT: zero-terminated
        if (flg & f != 0) {
            const z = std.mem.indexOfScalarPos(u8, in, p, 0) orelse return error.EndOfStream;
            p = z + 1;
        }
    }
    if (flg & 0x02 != 0) { // FHCRC: low 16 bits of the header's CRC-32
        if (in.len - p < 2) return error.EndOfStream;
        if (verify and std.mem.readInt(u16, in[p..][0..2], .little) != @as(u16, @truncate(crc32.hash(in[start..p]))))
            return error.BadGzipHeader;
        p += 2;
    }
    return p;
}

// ───────────────────────────── Huffman tables ─────────────────────────────
//
// Entry (u32):
//   bit 31      literal (value = the byte)
//   bit 15      exceptional: subtable pointer, end of block, or invalid code
//   bit 14      subtable pointer (value = subtable start, bits 8..11 = its index bits)
//   bit 13      end of block
//   bits 16..30 value: literal byte, length base, distance base, precode symbol
//   bits 8..11  codeword length (bits within this (sub)table)
//   bits 0..7   bits to consume: codeword + extra bits (pointer: main table bits)
// So `buf >>= e & 0xff` consumes a whole length or distance and its extra bits.

const LITERAL: u32 = 1 << 31;
const EXC: u32 = 1 << 15;
const SUB: u32 = 1 << 14;
const EOB: u32 = 1 << 13;

const lit_bits = 11;
const dist_bits = 8;
const pre_bits = 7;
// Largest table (main + subtables) any valid code can need, from zlib's `enough`
// (also libdeflate's): 288 symbols / 11 bits, 32 / 8, 19 / 7.
const lit_enough = 2342;
const dist_enough = 402;
const pre_enough = 128;

const len_base = [29]u32{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u32{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u32{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

// Per-symbol entry templates: value/flags in the high bits, extra-bit count in bits 0..4.
const lit_results: [288]u32 = blk: {
    var r: [288]u32 = undefined;
    for (0..256) |i| r[i] = LITERAL | (i << 16);
    r[256] = EXC | EOB;
    for (0..29) |i| r[257 + i] = (len_base[i] << 16) | len_extra[i];
    r[286] = EXC;
    r[287] = EXC;
    break :blk r;
};
const dist_results: [32]u32 = blk: {
    var r: [32]u32 = undefined;
    for (0..30) |i| r[i] = (dist_base[i] << 16) | dist_extra[i];
    r[30] = EXC;
    r[31] = EXC;
    break :blk r;
};
const pre_results: [19]u32 = blk: {
    var r: [19]u32 = undefined;
    for (0..19) |i| r[i] = i << 16;
    break :blk r;
};

inline fn entry(result: u32, len: u32) u32 {
    return (result & ~@as(u32, 0x1f)) | (len << 8) | (len + (result & 0x1f));
}

const Kind = enum { lit, dist, pre };

/// Builds a decode table from code lengths. Same acceptance rules as zlib and
/// std.compress.flate: over-subscribed codes are rejected; incomplete codes only as
/// a single 1-bit code in the literal/length or distance alphabet; an empty
/// distance (or precode) alphabet is allowed and decodes nothing.
fn build(table: []u32, lens: []const u8, results: []const u32, comptime tb: u5, comptime kind: Kind) Error!void {
    var count: [16]u16 = @splat(0);
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var left: i32 = 1;
    var max: u32 = 0;
    var n: usize = 0;
    for (1..16) |l| {
        left = left * 2 - count[l];
        if (left < 0) return error.OversubscribedHuffmanTree;
        if (count[l] != 0) max = @intCast(l);
        n += count[l];
    }
    if (max == 0) {
        @memset(table[0 .. 1 << tb], EXC);
        return;
    }
    if (left > 0) {
        if (kind == .pre or max != 1) return error.IncompleteHuffmanTree;
        @memset(table[0 .. 1 << tb], EXC); // the unused half stays invalid
    }

    var offs: [16]u16 = undefined;
    offs[1] = 0;
    for (1..15) |l| offs[l + 1] = offs[l] + count[l];
    var sorted: [288]u16 = undefined;
    for (lens, 0..) |l, s| {
        if (l != 0) {
            sorted[offs[l]] = @intCast(s);
            offs[l] += 1;
        }
    }

    var code: u32 = 0;
    var prev_len: u32 = lens[sorted[0]];
    var sub_end: u32 = 1 << tb;
    var sub_prefix: u32 = std.math.maxInt(u32);
    var sub_start: u32 = 0;
    var sub_bits: u32 = 0;
    var cnt = count;
    for (sorted[0..n], 0..) |sym, i| {
        const l: u32 = lens[sym];
        if (i > 0) code = (code + 1) << @intCast(l - prev_len);
        prev_len = l;
        const rev = @bitReverse(code) >> @intCast(32 - l); // codes are sent MSB first
        if (l <= tb) {
            const e = entry(results[sym], l);
            var j = rev;
            while (j < 1 << tb) : (j += @as(u32, 1) << @intCast(l)) table[j] = e;
        } else {
            const prefix = rev & ((1 << tb) - 1);
            if (prefix != sub_prefix) {
                // size the subtable to hold all remaining codes under this prefix (zlib)
                var cur = l - tb;
                var room: i32 = @as(i32, 1) << @intCast(cur);
                while (cur + tb < max) {
                    room -= cnt[cur + tb];
                    if (room <= 0) break;
                    cur += 1;
                    room <<= 1;
                }
                sub_prefix = prefix;
                sub_start = sub_end;
                sub_bits = cur;
                sub_end += @as(u32, 1) << @intCast(cur);
                table[prefix] = EXC | SUB | (sub_start << 16) | (cur << 8) | tb;
            }
            const e = entry(results[sym], l - tb);
            var j = rev >> tb;
            while (j < @as(u32, 1) << @intCast(sub_bits)) : (j += @as(u32, 1) << @intCast(l - tb)) table[sub_start + j] = e;
        }
        cnt[l] -= 1;
    }
}

/// Literal/length and distance tables side by side (one base pointer in the hot loop).
const Tables = struct { lit: [lit_enough]u32, dist: [dist_enough]u32 };
const fixed: Tables = blk: {
    @setEvalBranchQuota(200000);
    var lens: [288 + 32]u8 = undefined;
    @memset(lens[0..144], 8);
    @memset(lens[144..256], 9);
    @memset(lens[256..280], 7);
    @memset(lens[280..288], 8);
    @memset(lens[288..], 5);
    var t: Tables = .{ .lit = @splat(EXC), .dist = @splat(EXC) };
    build(&t.lit, lens[0..288], &lit_results, lit_bits, .lit) catch unreachable;
    build(&t.dist, lens[288..], &dist_results, dist_bits, .dist) catch unreachable;
    const final = t;
    break :blk final;
};

test {
    _ = crc32;
    _ = adler32;
    _ = @import("test.zig");
}
