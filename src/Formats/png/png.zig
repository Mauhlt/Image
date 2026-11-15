//! PNG: all color types (gray, gray+alpha, rgb, rgba, palette), bit depths 1-16
//! (16-bit gray without tRNS decodes to `.g16`; other 16-bit layouts are reduced to 8
//! bits by dropping the low byte), tRNS transparency,
//! multiple (and zero-length) IDAT chunks, Adam7 interlacing.
//! Unknown critical chunks are rejected, unknown ancillary chunks skipped.
//! Encode: 8-bit g / ga / rgb / rgba (bgr(a)/ycbcr(a) are converted), 16-bit gray from
//! `.g16`, adaptive per-row filter.
const std = @import("std");
const inflate = @import("../../inflate/inflate.zig");
const Error = @import("../error.zig").Error;

const Chunk = @import("chunk.zig");
const Header = @import("header.zig");
const FilterMethod = Header.FilterMethod;
const filter = @import("filter.zig");
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const simd = @import("../../Colors/simd.zig");
const native_endian = @import("builtin").cpu.arch.endian();

pub const SIG = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// Everything gathered from the chunk list.
const Parsed = struct {
    hdr: Header,
    srgb: bool = false,
    palette: []const u8 = &.{}, // rgb triplets
    trns: []const u8 = &.{},
    idat_len: usize = 0,
    /// Offset of the first IDAT chunk in the file; the others follow it directly.
    idat_start: usize = 0,
    idat_chunks: usize = 0,

    fn tag(self: *const Parsed) PixelTag {
        const has_trns = self.trns.len > 0;
        return switch (self.hdr.color_type) {
            // a tRNS key needs alpha, which `.g16` lacks: that stays 8-bit `.ga`
            .g => if (has_trns) .ga else if (self.hdr.bit_depth == .bit16) .g16 else .g,
            .ga => .ga,
            .rgb => if (has_trns) .rgba else .rgb,
            .rgba => .rgba,
            .i => if (has_trns) .rgba else .rgb,
        };
    }
};

/// Walks and validates (CRCs included) the chunks.
fn parse(data: []const u8) !Parsed {
    if (data.len < SIG.len or !std.mem.eql(u8, data[0..SIG.len], &SIG)) return Error.UnexpectedSignature;
    var i: usize = SIG.len;
    const hdr_chunk: Chunk = try .decode(data[i..]);
    try hdr_chunk.validateCrc();
    var p: Parsed = .{ .hdr = try .decode(hdr_chunk) };
    i += hdr_chunk.sizeOf();

    var seen_iend = false;
    // IDATs must be consecutive and PLTE must come before them
    const IdatState = enum { before, inside, after };
    var idat_state: IdatState = .before;
    while (i < data.len) {
        const chunk: Chunk = try .decode(data[i..]);
        try chunk.validateCrc();
        const chunk_start = i;
        i += chunk.sizeOf();
        if (chunk.tag != .IDAT and idat_state == .inside) idat_state = .after;
        switch (chunk.tag) {
            .IHDR => return Error.InvalidChunkOrder,
            .sRGB => p.srgb = true,
            .PLTE => {
                if (idat_state != .before or p.palette.len > 0) return Error.InvalidChunkOrder;
                if (chunk.data.len == 0 or chunk.data.len % 3 != 0 or chunk.data.len > 256 * 3) return Error.InvalidChunkLen;
                p.palette = chunk.data;
            },
            // tRNS is ancillary: like libpng, ignore a misplaced or repeated one
            .tRNS => if (idat_state == .before and p.trns.len == 0) {
                p.trns = chunk.data;
            },
            .IDAT => {
                if (idat_state == .after) return Error.InvalidChunkOrder;
                if (idat_state == .before) p.idat_start = chunk_start;
                idat_state = .inside;
                // a zero-length IDAT is legal and simply contributes nothing
                p.idat_len += chunk.data.len;
                p.idat_chunks += 1;
            },
            .IEND => {
                seen_iend = true;
                break;
            },
            .unsupported => {
                // bit 5 of the first tag byte clear (uppercase) = critical: we can't
                // safely ignore a chunk the spec says is needed to display the image
                if (chunk.data[0] & 0x20 == 0) return Error.UnsupportedFeature;
            },
            .gAMA, .pHYs => {}, // ancillary chunks we don't use
        }
    }
    if (idat_state == .before) return Error.MissingIdat;
    if (!seen_iend) return Error.MissingIend;
    if (p.hdr.color_type == .i and p.palette.len == 0) return Error.InvalidHeader;
    // tRNS is ancillary, so like libpng drop a malformed one instead of failing;
    // keeping it would make `tag()` promise an alpha channel `expandRow` can't fill
    const trns_ok = switch (p.hdr.color_type) {
        .g => p.trns.len == 2,
        .rgb => p.trns.len == 6,
        .i => true, // entries past the palette are never looked up
        .ga, .rgba => false, // already have alpha; the spec forbids tRNS here
    };
    if (!trns_ok) p.trns = &.{};
    return p;
}

pub fn info(data: []const u8) !Info {
    const p = try parse(data);
    const tag = p.tag();
    // PNG samples are sRGB unless stated otherwise (gAMA/iCCP); treat as sRGB
    return .{ .width = p.hdr.width, .height = p.hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    return decodeWith(Simd, scratch, data, inf, out);
}

/// The kernels `decodeWith` uses: `defilterPass` and an `Expander` type.
/// Tests swap in scalar.zig's oracle.
const Simd = struct {
    const defilterPass = filter.defilterPass;
    const Expander = @import("expand.zig").Expander;
};

/// The IDAT payloads as one zlib stream: a single IDAT is used in place, several
/// are concatenated into `scratch`.
fn idatStream(scratch: std.mem.Allocator, data: []const u8, p: *const Parsed) ![]const u8 {
    const first: Chunk = try .decode(data[p.idat_start..]);
    if (p.idat_chunks == 1) return first.data;
    const idat = try scratch.alloc(u8, p.idat_len);
    var i = p.idat_start;
    var len: usize = 0;
    for (0..p.idat_chunks) |_| {
        const chunk: Chunk = try .decode(data[i..]);
        @memcpy(idat[len..][0..chunk.data.len], chunk.data);
        len += chunk.data.len;
        i += chunk.sizeOf();
    }
    return idat;
}

fn decodeWith(comptime Rows: type, scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const p = try parse(data);
    const hdr = &p.hdr;
    if (hdr.width != inf.width or hdr.height != inf.height or p.tag() != inf.tag) return Error.InvalidHeader;

    const passes: []const Pass = switch (hdr.interlace_method) {
        .none => &.{.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1 }},
        .adam7 => &adam7,
    };

    // inflate: every pass is stored back to back, each row prefixed by its filter byte
    var raw_len: usize = 0;
    for (passes) |pass| {
        const w, const h = pass.size(hdr.width, hdr.height);
        if (w > 0) raw_len += h * (hdr.rowBytesFor(w) + 1);
    }
    const raw = try scratch.alloc(u8, raw_len);
    defer scratch.free(raw);
    {
        const idat = try idatStream(scratch, data, &p);
        defer if (p.idat_chunks > 1) scratch.free(idat);
        // one-shot inflate straight into `raw` (also the match history), Adler-32
        // checked; a stream that is truncated or runs on past the image data falls
        // back to streaming exactly `raw.len` bytes, as other decoders tolerate it
        if (inflate.decompress(.zlib, idat, raw, .{})) |r| {
            if (r.out_len != raw.len) try streamInflate(idat, raw);
        } else |e| switch (e) {
            error.OutputTooSmall, error.EndOfStream => try streamInflate(idat, raw),
            else => return Error.DecompressionFailed,
        }
    }

    // defilter in place, then scatter each row into its pass's pixel positions
    const zero_row = try scratch.alloc(u8, hdr.rowBytes());
    defer scratch.free(zero_row);
    @memset(zero_row, 0);
    var sink: RowSink(Rows.Expander) = .{
        .expander = .init(hdr, p.palette, p.trns),
        .out = out,
        .out_bpp = inf.tag.bytesPerPixel(),
        .out_stride = @as(usize, hdr.width) * inf.tag.bytesPerPixel(),
    };
    const bpp = @max(1, hdr.bitsPerPixel() / 8);
    var start: usize = 0;
    for (passes) |pass| {
        const w, const h = pass.size(hdr.width, hdr.height);
        if (w == 0) continue; // an empty pass has no rows, not even filter bytes
        const row_bytes = hdr.rowBytesFor(w);
        sink.pass = pass;
        sink.width = w;
        // each pass starts afresh: its first row is filtered against zeros
        try Rows.defilterPass(raw[start..][0 .. h * (row_bytes + 1)], row_bytes, h, bpp, zero_row, &sink);
        start += h * (row_bytes + 1);
    }
}

/// Receives defiltered rows of the current pass and expands them into place.
fn RowSink(comptime Expander: type) type {
    return struct {
        expander: Expander,
        out: []u8,
        out_bpp: usize,
        out_stride: usize,
        pass: Pass = undefined,
        width: usize = undefined,

        pub fn row(s: *const @This(), py: usize, data: []const u8) void {
            const y = s.pass.y0 + py * s.pass.dy;
            const row_start = y * s.out_stride + s.pass.x0 * s.out_bpp;
            const row_end = row_start + (s.width - 1) * s.pass.dx * s.out_bpp;
            s.expander.expand(data, s.width, s.out[row_start .. row_end + s.out_bpp], s.pass.dx * s.out_bpp);
        }
    };
}

/// One Adam7 pass: the pixels at (x0 + i*dx, y0 + j*dy).
/// A non-interlaced image is a single pass with dx = dy = 1.
const Pass = struct {
    x0: u8,
    y0: u8,
    dx: u8,
    dy: u8,

    /// Width and height of this pass's sub-image; either may be 0 for small images.
    fn size(self: Pass, width: u32, height: u32) struct { usize, usize } {
        return .{ span(width, self.x0, self.dx), span(height, self.y0, self.dy) };
    }

    fn span(full: u32, start: u8, step: u8) usize {
        return if (full > start) (full - start + step - 1) / step else 0;
    }
};

const adam7 = [7]Pass{
    .{ .x0 = 0, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 4, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 0, .y0 = 4, .dx = 4, .dy = 8 },
    .{ .x0 = 2, .y0 = 0, .dx = 4, .dy = 4 },
    .{ .x0 = 0, .y0 = 2, .dx = 2, .dy = 4 },
    .{ .x0 = 1, .y0 = 0, .dx = 2, .dy = 2 },
    .{ .x0 = 0, .y0 = 1, .dx = 1, .dy = 2 },
};

/// Cheap predictor of how well a filtered row compresses (smaller = better).
fn sumAbs(row: []const u8) u64 {
    var sum: u64 = 0;
    for (row) |r| sum += @abs(@as(i8, @bitCast(r)));
    return sum;
}

/// std's streaming inflate of exactly `raw.len` bytes (no checksum check).
fn streamInflate(idat: []const u8, raw: []u8) !void {
    var reader: std.Io.Reader = .fixed(idat);
    var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    var writer: std.Io.Writer = .fixed(raw);
    decompress.reader.streamExact(&writer, raw.len) catch return Error.DecompressionFailed;
}

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    // PNG stores g / ga / rgb / rgba (8-bit) and g16; convert anything else
    const tag: PixelTag = switch (img.pixels) {
        .g => .g,
        .g16 => .g16,
        .ga => .ga,
        .rgb, .bgr, .ycbcr => .rgb,
        .rgba, .bgra, .ycbcra => .rgba,
    };
    const converted = if (std.meta.activeTag(img.pixels) == tag) null else try img.pixels.convertV(tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    // 16-bit samples are stored big-endian
    const swapped: ?[]u8 = if (tag == .g16 and native_endian == .little) try gpa.alloc(u8, img.pixels.asBytes().len) else null;
    defer if (swapped) |s| gpa.free(s);
    if (swapped) |s| simd.nativeFromBig16(img.pixels.asBytes(), s);
    const src = swapped orelse (converted orelse img.pixels).asBytes();

    const hdr: Header = .fromImage(img);
    const bpp: usize = tag.bytesPerPixel();
    const row_bytes = @as(usize, img.width) * bpp;

    // filter every row with the best of the 5 filters
    const filtered = try gpa.alloc(u8, (row_bytes + 1) * img.height);
    defer gpa.free(filtered);
    const cand = try gpa.alloc(u8, row_bytes);
    defer gpa.free(cand);
    const zero_row = try gpa.alloc(u8, row_bytes);
    defer gpa.free(zero_row);
    @memset(zero_row, 0);
    var prev: []const u8 = zero_row;
    for (0..img.height) |y| {
        const row = src[y * row_bytes ..][0..row_bytes];
        const dst = filtered[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        var best_sum: u64 = std.math.maxInt(u64);
        for (std.enums.values(FilterMethod)) |f| {
            filter.filterRow(cand, f, row, prev, bpp);
            const sum = sumAbs(cand);
            if (sum < best_sum) {
                best_sum = sum;
                dst[0] = @intFromEnum(f);
                @memcpy(dst[1..], cand);
            }
        }
        prev = row;
    }

    // zlib
    var comp_aw: std.Io.Writer.Allocating = try .initCapacity(gpa, filtered.len / 2 + 128);
    defer comp_aw.deinit();
    {
        const hist_buf = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(hist_buf);
        var comp: std.compress.flate.Compress = try .init(&comp_aw.writer, hist_buf, .zlib, .default);
        try comp.writer.writeAll(filtered);
        try comp.finish();
    }
    const idat_data = comp_aw.written();

    var hdr_bytes: [13]u8 = undefined;
    try hdr.encode(&hdr_bytes);
    const chunks = [_]Chunk{
        .{ .tag = .IHDR, .len = 13, .data = &hdr_bytes },
        .{ .tag = .sRGB, .len = 1, .data = &.{0} },
        .{ .tag = .IDAT, .len = @intCast(idat_data.len), .data = idat_data },
        .{ .tag = .IEND, .len = 0, .data = &.{} },
    };
    try w.writeAll(&SIG);
    for (&chunks) |*c| try c.encode(w);
}

// ─────────────────────────── Fixture tests ───────────────────────────
// src/Data/Read/png/: PngSuite + Windows WIC references, see its README.md

const test_dir = "src/Data/Read/png/";

fn readFixture(io: std.Io, gpa: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, test_dir ++ name, gpa, .unlimited);
}

fn expectSamePixels(a: *const Image, b: *const Image) !void {
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqual(std.meta.activeTag(a.pixels), std.meta.activeTag(b.pixels));
    try std.testing.expectEqualSlices(u8, a.pixels.asBytes(), b.pixels.asBytes());
}

/// Fixtures `name` and `twin` must decode to identical pixels.
fn expectTwins(io: std.Io, gpa: std.mem.Allocator, comptime name: []const u8, comptime twin: []const u8) !void {
    const a_data = try readFixture(io, gpa, name);
    defer gpa.free(a_data);
    const b_data = try readFixture(io, gpa, twin);
    defer gpa.free(b_data);
    const a = try Image.decode(.png, gpa, a_data);
    defer a.deinit(gpa);
    const b = try Image.decode(.png, gpa, b_data);
    defer b.deinit(gpa);
    expectSamePixels(&a, &b) catch |err| {
        std.debug.print("mismatch: {s} vs {s}\n", .{ name, twin });
        return err;
    };
}

const RawChunk = struct { name: *const [4]u8, data: []const u8 };

fn writeChunk(w: *std.Io.Writer, c: RawChunk) !void {
    try w.writeInt(u32, @intCast(c.data.len), .big);
    try w.writeAll(c.name);
    try w.writeAll(c.data);
    var h = std.hash.Crc32.init();
    h.update(c.name);
    h.update(c.data);
    try w.writeInt(u32, h.final(), .big);
}

/// Re-emits a PNG with its IDAT payload split into `idat_split`-byte chunks, writing
/// `between` before each piece, `before` ahead of the IDATs and `after` behind them.
/// Lets tests build chunk layouts no fixture has.
const Rebuild = struct {
    before: []const RawChunk = &.{},
    between: []const RawChunk = &.{},
    after: []const RawChunk = &.{},
    idat_split: usize = std.math.maxInt(usize),

    fn apply(self: Rebuild, gpa: std.mem.Allocator, png: []const u8) ![]u8 {
        var idat: std.ArrayList(u8) = .empty;
        defer idat.deinit(gpa);
        var i: usize = SIG.len;
        while (i < png.len) {
            const c: Chunk = try .decode(png[i..]);
            if (c.tag == .IDAT) try idat.appendSlice(gpa, c.data);
            i += c.sizeOf();
        }

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll(&SIG);
        var wrote_idat = false;
        i = SIG.len;
        while (i < png.len) {
            const c: Chunk = try .decode(png[i..]);
            const raw = png[i..][0..c.sizeOf()];
            i += c.sizeOf();
            if (c.tag != .IDAT) {
                try w.writeAll(raw);
                continue;
            }
            if (wrote_idat) continue;
            wrote_idat = true;
            for (self.before) |b| try writeChunk(w, b);
            var rest: []const u8 = idat.items;
            while (rest.len > 0) {
                for (self.between) |b| try writeChunk(w, b);
                const n = @min(rest.len, self.idat_split);
                try writeChunk(w, .{ .name = "IDAT", .data = rest[0..n] });
                rest = rest[n..];
            }
            for (self.after) |a| try writeChunk(w, a);
        }
        return aw.toOwnedSlice();
    }
};

fn decodeRebuilt(gpa: std.mem.Allocator, png: []const u8, edit: Rebuild) !Image {
    const data = try edit.apply(gpa, png);
    defer gpa.free(data);
    return Image.decode(.png, gpa, data);
}

test {
    _ = filter;
    _ = @import("expand.zig");
    _ = @import("scalar.zig");
}

/// The original scalar row kernels, for checking the SIMD ones end to end.
const Oracle = struct {
    const scalar = @import("scalar.zig");
    const defilterPass = scalar.defilterPass;
    const Expander = scalar.Expander;
};

/// Decodes `data` with the SIMD kernels and with the scalar oracle; both must agree.
fn expectMatchesOracle(gpa: std.mem.Allocator, data: []const u8) !void {
    const inf = try info(data);
    const want = try gpa.alloc(u8, try inf.byteLen());
    defer gpa.free(want);
    const got = try gpa.alloc(u8, want.len);
    defer gpa.free(got);
    try decodeWith(Oracle, gpa, data, inf, want);
    try decodeInto(gpa, data, inf, got);
    try std.testing.expectEqualSlices(u8, want, got);
}

test "png decoder matches the scalar oracle on every fixture" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    inline for (.{
        "basi0g01", "basi0g02", "basi0g04", "basi0g08", "basi0g16", "basi2c08", "basi2c16",
        "basi3p01", "basi3p02", "basi3p04", "basi3p08", "basi4a08", "basi4a16", "basi6a08",
        "basi6a16", "basn0g01", "basn0g02", "basn0g04", "basn0g08", "basn0g16", "basn2c08",
        "basn2c16", "basn3p01", "basn3p02", "basn3p04", "basn3p08", "basn4a08", "basn4a16",
        "basn6a08", "basn6a16", "s01i3p01", "s01n3p01", "s02i3p01", "s02n3p01", "s03i3p01",
        "s03n3p01", "s04i3p01", "s04n3p01", "s05i3p02", "s05n3p02", "s06i3p02", "s06n3p02",
        "s07i3p02", "s07n3p02", "s08i3p02", "s08n3p02", "s09i3p02", "s09n3p02", "s33i3p04",
        "s33n3p04", "s34i3p04", "s34n3p04", "s35i3p04", "s35n3p04", "s36i3p04", "s36n3p04",
        "s37i3p04", "s37n3p04", "s38i3p04", "s38n3p04", "s39i3p04", "s39n3p04", "tbbn0g04",
        "tbbn3p08", "tbrn2c08", "tbwn0g16", "tm3n3p02",
    }) |name| {
        const data = try readFixture(io, gpa, name ++ ".png");
        defer gpa.free(data);
        expectMatchesOracle(gpa, data) catch |err| {
            std.debug.print("mismatch: {s}\n", .{name});
            return err;
        };
    }
    // the library's encoder picks a filter per row, unlike most fixtures above
    const art = try std.Io.Dir.cwd().readFileAlloc(io, "src/Data/Read/BasicArt.png", gpa, .unlimited);
    defer gpa.free(art);
    try expectMatchesOracle(gpa, art);
    const art16 = try readFixture(io, gpa, "BasicArt16i.png");
    defer gpa.free(art16);
    try expectMatchesOracle(gpa, art16);
}

test "png 16-bit Adam7 BasicArt matches the 8-bit original" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const art16_data = try readFixture(io, gpa, "BasicArt16i.png");
    defer gpa.free(art16_data);
    const art16 = try Image.decode(.png, gpa, art16_data);
    defer art16.deinit(gpa);
    const art_data = try std.Io.Dir.cwd().readFileAlloc(io, "src/Data/Read/BasicArt.png", gpa, .unlimited);
    defer gpa.free(art_data);
    const art = try Image.decode(.png, gpa, art_data);
    defer art.deinit(gpa);
    // the high byte of v * 257 is v
    try expectSamePixels(&art, &art16);
    // and the same again with the zlib stream split over many IDATs
    const split = try decodeRebuilt(gpa, art16_data, .{ .idat_split = 1000 });
    defer split.deinit(gpa);
    try expectSamePixels(&art, &split);
}

test "png decoder matches the scalar oracle on random images" {
    // Any bytes are a valid filtered stream, so random rows with random filter
    // types reach every filter, bit depth, color type, tRNS and Adam7 pass shape.
    const gpa = std.testing.allocator;
    var rng: std.Random.DefaultPrng = .init(0xC0FFEE);
    const random = rng.random();
    const Kind = struct { ct: Header.ColorType, depths: []const u8 };
    const kinds = [_]Kind{
        .{ .ct = .g, .depths = &.{ 1, 2, 4, 8, 16 } },
        .{ .ct = .rgb, .depths = &.{ 8, 16 } },
        .{ .ct = .i, .depths = &.{ 1, 2, 4, 8 } },
        .{ .ct = .ga, .depths = &.{ 8, 16 } },
        .{ .ct = .rgba, .depths = &.{ 8, 16 } },
    };
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 3, 5 }, .{ 7, 2 }, .{ 13, 9 }, .{ 33, 17 }, .{ 70, 11 } };
    var palette: [3 * 180]u8 = undefined; // short: high 8-bit indices fall off the end
    random.bytes(&palette);
    var trns_buf: [120]u8 = undefined;
    random.bytes(&trns_buf);
    for (kinds) |kind| for (kind.depths) |depth| for (sizes) |size| {
        for (std.enums.values(Header.InterlaceMethod)) |interlace| for (0..2) |with_trns| {
            const hdr: Header = .{
                .width = size[0],
                .height = size[1],
                .bit_depth = @enumFromInt(depth),
                .color_type = kind.ct,
                .compression_method = .none,
                .filter_method = .none,
                .interlace_method = interlace,
            };
            // small sample values so the tRNS key (zero) actually occurs
            const trns: []const u8 = if (with_trns == 0) &.{} else switch (kind.ct) {
                .g => &.{ 0, 0 },
                .rgb => &.{ 0, 0, 0, 0, 0, 0 },
                .i => &trns_buf,
                .ga, .rgba => continue,
            };
            const data = try randomPng(gpa, random, &hdr, &palette, trns);
            defer gpa.free(data);
            expectMatchesOracle(gpa, data) catch |err| {
                std.debug.print("{t} depth {} {}x{} {t} trns {}\n", .{ kind.ct, depth, size[0], size[1], interlace, trns.len });
                return err;
            };
        };
    };
}

/// A PNG whose filtered scanlines are random bytes behind random filter types.
fn randomPng(gpa: std.mem.Allocator, random: std.Random, hdr: *const Header, palette: []const u8, trns: []const u8) ![]u8 {
    const passes: []const Pass = switch (hdr.interlace_method) {
        .none => &.{.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1 }},
        .adam7 => &adam7,
    };
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (passes) |pass| {
        const w, const h = pass.size(hdr.width, hdr.height);
        if (w == 0) continue;
        for (0..h) |_| {
            try raw.append(gpa, random.uintLessThan(u8, 5));
            const row = try raw.addManyAsSlice(gpa, hdr.rowBytesFor(w));
            random.bytes(row);
            // mostly-small samples, so tRNS keys of zero match some pixels
            for (row) |*b| {
                if (random.boolean()) b.* &= 0x01;
            }
        }
    }
    var zlib: std.Io.Writer.Allocating = try .initCapacity(gpa, raw.items.len + 128);
    defer zlib.deinit();
    {
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var comp: std.compress.flate.Compress = try .init(&zlib.writer, window, .zlib, .fastest);
        try comp.writer.writeAll(raw.items);
        try comp.finish();
    }
    var ihdr: [13]u8 = undefined;
    try hdr.encode(&ihdr);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(&SIG);
    try writeChunk(w, .{ .name = "IHDR", .data = &ihdr });
    if (hdr.color_type == .i) try writeChunk(w, .{ .name = "PLTE", .data = palette });
    if (trns.len > 0) try writeChunk(w, .{ .name = "tRNS", .data = trns });
    try writeChunk(w, .{ .name = "IDAT", .data = zlib.written() });
    try writeChunk(w, .{ .name = "IEND", .data = &.{} });
    return aw.toOwnedSlice();
}

test "png adam7 matches non-interlaced twins" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // every color type x bit depth
    inline for (.{
        "0g01", "0g02", "0g04", "0g08", "0g16", "2c08", "2c16", "3p01",
        "3p02", "3p04", "3p08", "4a08", "4a16", "6a08", "6a16",
    }) |kind| try expectTwins(io, gpa, "basi" ++ kind ++ ".png", "basn" ++ kind ++ ".png");
    // odd sizes leave some passes empty or a single pixel wide
    inline for (.{
        "s01i3p01", "s02i3p01", "s03i3p01", "s04i3p01", "s05i3p02", "s06i3p02",
        "s07i3p02", "s08i3p02", "s09i3p02", "s33i3p04", "s34i3p04", "s35i3p04",
        "s36i3p04", "s37i3p04", "s38i3p04", "s39i3p04",
    }) |name| try expectTwins(io, gpa, name ++ ".png", name[0..3] ++ "n" ++ name[4..] ++ ".png");
}

test "png matches Windows' decoder" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    inline for (.{
        "basi0g01", "basi0g02", "basi0g04", "basi0g08", "basi0g16", "basi2c08", "basi2c16",
        "basi3p01", "basi3p02", "basi3p04", "basi3p08", "basi4a08", "basi4a16", "basi6a08",
        "basi6a16", "tbbn0g04", "tbwn0g16", "tbrn2c08", "tbbn3p08", "tm3n3p02",
    }) |name| {
        const data = try readFixture(io, gpa, name ++ ".png");
        defer gpa.free(data);
        const ref_data = try readFixture(io, gpa, name ++ ".wic.png");
        defer gpa.free(ref_data);
        const decoded = try Image.decode(.png, gpa, data);
        defer decoded.deinit(gpa);
        const img = try decoded.convert(.rgba, gpa);
        defer img.deinit(gpa);
        const ref = try Image.decode(.png, gpa, ref_data); // WIC wrote it as rgba
        defer ref.deinit(gpa);
        try std.testing.expectEqual(ref.width, img.width);
        try std.testing.expectEqual(ref.height, img.height);
        // 16-bit gray decodes to .g16, which `convert` rounds to 8 bits as round(v / 257);
        // WIC narrows a little differently: some are off by one
        const tol: u8 = if (comptime std.mem.eql(u8, name, "basi0g16")) 1 else 0;
        const a = std.mem.bytesAsSlice([4]u8, img.pixels.asBytes());
        const b = std.mem.bytesAsSlice([4]u8, ref.pixels.asBytes());
        for (a, b, 0..) |pa, pb, i| {
            // WIC whitens fully transparent pixels; their color is meaningless anyway
            if (pa[3] == 0 and pb[3] == 0) continue;
            for (pa, pb) |x, y| if (@max(x, y) - @min(x, y) > tol) {
                std.debug.print("{s}: pixel {} is {any}, WIC says {any}\n", .{ name, i, pa, pb });
                return error.TestUnexpectedResult;
            };
        }
    }
}

test "png tRNS through adam7" {
    // PngSuite has no interlaced tRNS files: add the same tRNS to both twins
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Case = struct { kind: []const u8, trns: []const u8 };
    // gray / rgb keys are the top-left pixel's color, so some pixels match
    inline for (.{
        Case{ .kind = "0g01", .trns = &.{ 0, 0 } },
        Case{ .kind = "0g02", .trns = &.{ 0, 0 } },
        Case{ .kind = "0g04", .trns = &.{ 0, 0 } },
        Case{ .kind = "0g08", .trns = &.{ 0, 0 } },
        Case{ .kind = "0g16", .trns = &.{ 0, 0 } },
        Case{ .kind = "2c08", .trns = &.{ 0, 255, 0, 255, 0, 255 } },
        Case{ .kind = "2c16", .trns = &.{ 255, 255, 255, 255, 0, 0 } },
        Case{ .kind = "3p01", .trns = &.{ 0, 128 } },
        Case{ .kind = "3p02", .trns = &.{ 0, 128 } },
        Case{ .kind = "3p04", .trns = &.{ 0, 128 } },
        Case{ .kind = "3p08", .trns = &.{ 0, 128 } },
    }) |case| {
        const edit: Rebuild = .{ .before = &.{.{ .name = "tRNS", .data = case.trns }} };
        const i_data = try readFixture(io, gpa, "basi" ++ case.kind ++ ".png");
        defer gpa.free(i_data);
        const n_data = try readFixture(io, gpa, "basn" ++ case.kind ++ ".png");
        defer gpa.free(n_data);
        const a = try decodeRebuilt(gpa, i_data, edit);
        defer a.deinit(gpa);
        const b = try decodeRebuilt(gpa, n_data, edit);
        defer b.deinit(gpa);
        expectSamePixels(&a, &b) catch |err| {
            std.debug.print("mismatch: {s}\n", .{case.kind});
            return err;
        };
        // the key must actually hit some pixels (not all), or the test proves nothing
        const bytes = a.pixels.asBytes();
        const bpp = std.meta.activeTag(a.pixels).bytesPerPixel();
        var transparent: usize = 0;
        var k: usize = bpp - 1;
        while (k < bytes.len) : (k += bpp) {
            if (bytes[k] == 0) transparent += 1;
        }
        std.testing.expect(transparent > 0 and transparent < a.width * a.height) catch |err| {
            std.debug.print("{s}: {} transparent pixels\n", .{ case.kind, transparent });
            return err;
        };
    }
}

test "png chunk layout" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const data = try readFixture(io, gpa, "basi3p02.png");
    defer gpa.free(data);
    const ref = try Image.decode(.png, gpa, data);
    defer ref.deinit(gpa);

    const empty_idat: RawChunk = .{ .name = "IDAT", .data = &.{} };
    const text: RawChunk = .{ .name = "tEXt", .data = "Comment\x00hi" };
    const plte: RawChunk = .{ .name = "PLTE", .data = &.{ 0, 0, 0 } };
    const ok_cases = [_]Rebuild{
        // many small IDATs, each preceded by an empty one, and an empty one last
        .{ .idat_split = 7, .between = &.{empty_idat}, .after = &.{empty_idat} },
        // unknown ancillary chunks are skipped, before and after the image data
        .{ .before = &.{.{ .name = "fOOb", .data = "x" }}, .after = &.{text} },
        // a tRNS after the image data is ignored (it would make palette entry 0 clear)
        .{ .after = &.{.{ .name = "tRNS", .data = &.{0} }} },
    };
    for (ok_cases) |edit| {
        const img = try decodeRebuilt(gpa, data, edit);
        defer img.deinit(gpa);
        try expectSamePixels(&ref, &img);
    }

    const Bad = struct { edit: Rebuild, err: anyerror };
    const bad_cases = [_]Bad{
        // IDATs must be consecutive
        .{ .edit = .{ .idat_split = 50, .between = &.{text} }, .err = Error.InvalidChunkOrder },
        // PLTE after the image data
        .{ .edit = .{ .after = &.{plte} }, .err = Error.InvalidChunkOrder },
        // a second PLTE
        .{ .edit = .{ .before = &.{plte} }, .err = Error.InvalidChunkOrder },
        // unknown critical chunk (uppercase first letter)
        .{ .edit = .{ .before = &.{.{ .name = "FOOb", .data = "x" }} }, .err = Error.UnsupportedFeature },
    };
    for (bad_cases) |case| {
        const bad = try case.edit.apply(gpa, data);
        defer gpa.free(bad);
        try std.testing.expectError(case.err, info(bad));
    }
}

test "png malformed tRNS is ignored" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    inline for (.{ "basn0g08.png", "basn2c08.png", "basn6a08.png" }) |name| {
        const data = try readFixture(io, gpa, name);
        defer gpa.free(data);
        const ref = try Image.decode(.png, gpa, data);
        defer ref.deinit(gpa);
        // 1 byte fits no layout (gray needs 2, rgb 6, rgba allows none): dropped like libpng
        const img = try decodeRebuilt(gpa, data, .{ .before = &.{.{ .name = "tRNS", .data = &.{0} }} });
        defer img.deinit(gpa);
        try expectSamePixels(&ref, &img);
    }
}

test "png 16-bit gray decodes to g16 and round trips exactly" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // PngSuite's 16-bit gray: the samples as stored, big-endian in the file
    const data = try readFixture(io, gpa, "basn0g16.png");
    defer gpa.free(data);
    const img = try Image.decode(.png, gpa, data);
    defer img.deinit(gpa);
    try std.testing.expectEqual(PixelTag.g16, std.meta.activeTag(img.pixels));
    try std.testing.expectEqual(vk_r16, img.fmt);

    var prng: std.Random.DefaultPrng = .init(0x916);
    const random = prng.random();
    const N = @import("../../Colors/misc.zig").N;
    for ([_]u32{ 1, 3, N - 1, N, N + 1, 2 * N + 3, 37 }) |w| {
        const h = 3;
        const bytes = try gpa.alloc(u8, @as(usize, w) * h * 2);
        const samples = std.mem.bytesAsSlice(u16, bytes);
        for (samples, 0..) |*s, i| s.* = switch (i % 5) {
            0 => 0,
            1 => 1,
            2 => 4095,
            3 => 65535,
            else => random.int(u16),
        };
        const src: Image = .{ .width = w, .height = h, .pixels = .fromBytes(.g16, bytes), .fmt = vk_r16 };
        defer src.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try src.encode(.png, &aw.writer, gpa);
        // stored as 16-bit gray, big-endian
        const hdr: Header = try .decode(try Chunk.decode(aw.written()[SIG.len..]));
        try std.testing.expectEqual(Header.BitDepth.bit16, hdr.bit_depth);
        try std.testing.expectEqual(Header.ColorType.g, hdr.color_type);
        try expectMatchesOracle(gpa, aw.written());
        const back = try Image.decode(.png, gpa, aw.written());
        defer back.deinit(gpa);
        try expectSamePixels(&src, &back);
    }
}

const vk_r16 = Info.fmtFor(.g16, true);
