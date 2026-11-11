//! PNG: all color types (gray, gray+alpha, rgb, rgba, palette), bit depths 1-16
//! (16-bit is reduced to 8), tRNS transparency, multiple IDAT chunks.
//! Adam7 interlacing is not supported.
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
    if (p.hdr.interlace_method != .none) return Error.UnsupportedInterlaceMethod;
    i += hdr_chunk.sizeOf();

    var seen_iend = false;
    var seen_idat = false;
    while (i < data.len) {
        const chunk: Chunk = try .decode(data[i..]);
        try chunk.validateCrc();
        i += chunk.sizeOf();
        switch (chunk.tag) {
            .IHDR => return Error.InvalidChunkOrder,
            .sRGB => p.srgb = true,
            .PLTE => {
                if (chunk.data.len % 3 != 0 or chunk.data.len > 256 * 3) return Error.InvalidChunkLen;
                p.palette = chunk.data;
            },
            .tRNS => p.trns = chunk.data,
            .IDAT => {
                if (idat_out) |out| {
                    if (p.idat_len + chunk.data.len > out.len) return Error.InvalidDataLen;
                    @memcpy(out[p.idat_len..][0..chunk.data.len], chunk.data);
                }
                p.idat_len += chunk.data.len;
                seen_idat = true;
            },
            .IEND => {
                seen_iend = true;
                break;
            },
            else => {}, // ancillary chunks we don't use
        }
    }
    if (!seen_idat) return Error.MissingIdat;
    if (!seen_iend) return Error.MissingIend;
    if (p.hdr.color_type == .i and p.palette.len == 0) return Error.InvalidHeader;
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

    // inflate
    const row_bytes = hdr.rowBytes();
    const raw = try scratch.alloc(u8, hdr.height * (row_bytes + 1));
    defer scratch.free(raw);
    {
        const window = try scratch.alloc(u8, std.compress.flate.max_window_len);
        defer scratch.free(window);
        var reader: std.Io.Reader = .fixed(idat);
        var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, window);
        decompress.reader.readSliceAll(raw) catch return Error.DecompressionFailed;
    }

    // defilter in place; filter byte at raw[row * (row_bytes + 1)]
    const bpp = @max(1, hdr.bitsPerPixel() / 8);
    const zero_row = try scratch.alloc(u8, row_bytes);
    defer scratch.free(zero_row);
    @memset(zero_row, 0);
    var prev: []const u8 = zero_row;
    const out_bpp = inf.tag.bytesPerPixel();
    for (0..hdr.height) |y| {
        const start = y * (row_bytes + 1);
        const filter = std.enums.fromInt(FilterMethod, raw[start]) orelse return Error.UnsupportedFilterMethod;
        const row = raw[start + 1 ..][0..row_bytes];
        defilterRow(filter, row, prev, bpp);
        prev = row;
        expandRow(&p, row, out[y * hdr.width * out_bpp ..][0 .. hdr.width * out_bpp]);
    }
}

/// Converts one defiltered scanline into 8-bit output pixels.
fn expandRow(p: *const Parsed, row: []const u8, out: []u8) void {
    const hdr = &p.hdr;
    const depth: usize = @intFromEnum(hdr.bit_depth);
    const channels = hdr.color_type.channels();
    const width: usize = hdr.width;

    // fast path: 8-bit, no tRNS expansion, same layout
    if (depth == 8 and hdr.color_type != .i and p.trns.len == 0) {
        @memcpy(out, row[0..out.len]);
        return;
    }

    var o: usize = 0;
    for (0..width) |x| {
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
