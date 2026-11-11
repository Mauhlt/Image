//! PNG: all color types (gray, gray+alpha, rgb, rgba, palette), bit depths 1-16
//! (16-bit is reduced to 8 by dropping the low byte), tRNS transparency,
//! multiple (and zero-length) IDAT chunks, Adam7 interlacing.
//! Unknown critical chunks are rejected, unknown ancillary chunks skipped.
//! Encode: 8-bit g / ga / rgb / rgba (bgr(a)/ycbcr(a) are converted), adaptive per-row filter.
const std = @import("std");
const Error = @import("../error.zig").Error;

const Chunk = @import("chunk.zig");
const Header = @import("header.zig");
const FilterMethod = Header.FilterMethod;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;

pub const SIG = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// Everything gathered from the chunk list.
const Parsed = struct {
    hdr: Header,
    srgb: bool = false,
    palette: []const u8 = &.{}, // rgb triplets
    trns: []const u8 = &.{},
    idat_len: usize = 0,

    fn tag(self: *const Parsed) PixelTag {
        const has_trns = self.trns.len > 0;
        return switch (self.hdr.color_type) {
            .g => if (has_trns) .ga else .g,
            .ga => .ga,
            .rgb => if (has_trns) .rgba else .rgb,
            .rgba => .rgba,
            .i => if (has_trns) .rgba else .rgb,
        };
    }
};

/// Walks the chunks; if `idat_out` is given, concatenates IDAT payloads into it.
fn parse(data: []const u8, idat_out: ?[]u8) !Parsed {
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
                idat_state = .inside;
                // a zero-length IDAT is legal and simply contributes nothing
                if (idat_out) |out| {
                    if (p.idat_len + chunk.data.len > out.len) return Error.InvalidDataLen;
                    @memcpy(out[p.idat_len..][0..chunk.data.len], chunk.data);
                }
                p.idat_len += chunk.data.len;
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
    const p = try parse(data, null);
    const tag = p.tag();
    // PNG samples are sRGB unless stated otherwise (gAMA/iCCP); treat as sRGB
    return .{ .width = p.hdr.width, .height = p.hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const first = try parse(data, null);
    const idat = try scratch.alloc(u8, first.idat_len);
    defer scratch.free(idat);
    const p = try parse(data, idat);
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
        const window = try scratch.alloc(u8, std.compress.flate.max_window_len);
        defer scratch.free(window);
        var reader: std.Io.Reader = .fixed(idat);
        var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, window);
        decompress.reader.readSliceAll(raw) catch return Error.DecompressionFailed;
    }

    // defilter in place, then scatter each row into its pass's pixel positions
    const bpp = @max(1, hdr.bitsPerPixel() / 8);
    const zero_row = try scratch.alloc(u8, hdr.rowBytes());
    defer scratch.free(zero_row);
    @memset(zero_row, 0);
    const out_bpp = inf.tag.bytesPerPixel();
    const out_stride = @as(usize, hdr.width) * out_bpp;
    var start: usize = 0;
    for (passes) |pass| {
        const w, const h = pass.size(hdr.width, hdr.height);
        if (w == 0) continue; // an empty pass has no rows, not even filter bytes
        const row_bytes = hdr.rowBytesFor(w);
        // each pass starts afresh: its first row is filtered against zeros
        var prev: []const u8 = zero_row[0..row_bytes];
        for (0..h) |py| {
            const filter = std.enums.fromInt(FilterMethod, raw[start]) orelse return Error.UnsupportedFilterMethod;
            const row = raw[start + 1 ..][0..row_bytes];
            start += row_bytes + 1;
            defilterRow(filter, row, prev, bpp);
            prev = row;
            const y = pass.y0 + py * pass.dy;
            const row_start = y * out_stride + pass.x0 * out_bpp;
            const row_end = row_start + (w - 1) * pass.dx * out_bpp;
            expandRow(&p, row, w, out[row_start .. row_end + out_bpp], pass.dx * out_bpp);
        }
    }
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

/// Converts one defiltered scanline of `width` pixels into 8-bit output pixels,
/// `stride` bytes apart in `out` (wider than a pixel for interlace passes).
fn expandRow(p: *const Parsed, row: []const u8, width: usize, out: []u8, stride: usize) void {
    const hdr = &p.hdr;
    const depth: usize = @intFromEnum(hdr.bit_depth);
    const channels = hdr.color_type.channels();

    // fast path: 8-bit, no tRNS expansion, same layout, contiguous
    if (depth == 8 and hdr.color_type != .i and p.trns.len == 0 and stride == channels) {
        @memcpy(out, row[0..out.len]);
        return;
    }

    for (0..width) |x| {
        var o = x * stride;
        // read `channels` samples, scaled to 8-bit (except palette indices)
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
            .g => {
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

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn defilterRow(filter: FilterMethod, row: []u8, prev: []const u8, bpp: usize) void {
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

fn filterRow(out: []u8, filter: FilterMethod, row: []const u8, prev: []const u8, bpp: usize) void {
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

/// Cheap predictor of how well a filtered row compresses (smaller = better).
fn sumAbs(row: []const u8) u64 {
    var sum: u64 = 0;
    for (row) |r| sum += @abs(@as(i8, @bitCast(r)));
    return sum;
}

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    // PNG stores g / ga / rgb / rgba; convert anything else
    const tag: PixelTag = switch (img.pixels) {
        .g => .g,
        .ga => .ga,
        .rgb, .bgr, .ycbcr => .rgb,
        .rgba, .bgra, .ycbcra => .rgba,
    };
    const converted = if (std.meta.activeTag(img.pixels) == tag) null else try img.pixels.convertV(tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const src = (converted orelse img.pixels).asBytes();

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
            filterRow(cand, f, row, prev, bpp);
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

test "png sub-byte samples" {
    // 4-bit row: 0xAB 0xC0 -> samples A, B, C
    const row = [_]u8{ 0xAB, 0xC0 };
    try std.testing.expectEqual(@as(u16, 0xA), sample(&row, 0, 4));
    try std.testing.expectEqual(@as(u16, 0xB), sample(&row, 1, 4));
    try std.testing.expectEqual(@as(u16, 0xC), sample(&row, 2, 4));
    try std.testing.expectEqual(@as(u8, 0xFF), scale8(1, 1));
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
        // WIC rounds 16-bit gray to 8 bits where we keep the high byte: some are off by one
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
