//! HEIC check: ISO-BMFF boxes (sizes inside their parents), `ftyp` with a
//! HEIF/HEIC brand first, a `meta` box with the primary item (`pitm`) and
//! its properties (`iprp`: `ipco` + `ipma`). The size is the primary item's
//! `ispe`, quarter-turned by its `irot`; a clean-aperture crop (`clap`) is
//! not applied, so the size can be a little larger than what decodes.
//! The full check walks every top-level box to the end of the file.
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

const brands = [_]*const [4]u8{ "heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1" };

pub fn sniff(data: []const u8) bool {
    if (data.len < 16 or !std.mem.eql(u8, data[4..8], "ftyp")) return false;
    const size = std.mem.readInt(u32, data[0..4], .big);
    if (size < 16) return false;
    const end = @min(data.len, size);
    var i: usize = 8;
    while (i + 4 <= end) : (i += 4) {
        if (i == 12) continue; // minor version
        for (brands) |b| if (std.mem.eql(u8, data[i..][0..4], b)) return true;
    }
    return false;
}

const Box = struct { type: [4]u8, body: []const u8 };

const Boxes = struct {
    data: []const u8,
    pos: usize = 0,
    count: *u32,
    max: u32,

    fn next(it: *Boxes) Error!?Box {
        const d = it.data;
        if (it.pos >= d.len) return null;
        it.count.* += 1;
        if (it.count.* > it.max) return error.TooManyChunks;
        if (d.len - it.pos < 8) return error.Truncated;
        var size: u64 = std.mem.readInt(u32, d[it.pos..][0..4], .big);
        const t = d[it.pos + 4 ..][0..4].*;
        var hdr: u64 = 8;
        if (size == 1) {
            if (d.len - it.pos < 16) return error.Truncated;
            size = std.mem.readInt(u64, d[it.pos + 8 ..][0..8], .big);
            hdr = 16;
        } else if (size == 0) size = d.len - it.pos; // to the end
        if (size < hdr) return error.InvalidChunk;
        if (size > d.len - it.pos) return error.Truncated;
        const body = d[it.pos + @as(usize, @intCast(hdr)) .. it.pos + @as(usize, @intCast(size))];
        it.pos += @intCast(size);
        return .{ .type = t, .body = body };
    }
};

fn eql(t: [4]u8, s: *const [4]u8) bool {
    return std.mem.eql(u8, &t, s);
}

/// 1-based ipco indices associated with `item` in an `ipma` body.
fn associations(ipma: []const u8, item: u32, out: *[32]u16) Error![]const u16 {
    var p: usize = 0;
    const vf = try root.int(u32, ipma, p, .big);
    p += 4;
    const version: u8 = @truncate(vf >> 24);
    const wide_index = vf & 1 != 0;
    const count = try root.int(u32, ipma, p, .big);
    p += 4;
    for (0..count) |_| {
        const id: u32 = if (version >= 1) try root.int(u32, ipma, p, .big) else try root.int(u16, ipma, p, .big);
        p += if (version >= 1) 4 else 2;
        const n = try root.int(u8, ipma, p, .big);
        p += 1;
        var k: usize = 0;
        for (0..n) |_| {
            const v: u16 = if (wide_index) (try root.int(u16, ipma, p, .big)) & 0x7FFF else (try root.int(u8, ipma, p, .big)) & 0x7F;
            p += if (wide_index) 2 else 1;
            if (id == item and k < out.len) {
                out[k] = v;
                k += 1;
            }
        }
        if (id == item) return out[0..k];
    }
    return error.InvalidHeader;
}

pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth) Error!Info {
    if (!sniff(data)) return error.UnknownFormat;
    var count: u32 = 0;
    var top: Boxes = .{ .data = data, .count = &count, .max = limits.max_chunks };
    var meta: ?[]const u8 = null;
    while (try top.next()) |b| {
        if (eql(b.type, "meta")) {
            if (meta != null) return error.InvalidChunkOrder;
            meta = b.body;
            if (depth == .header) break;
        }
    }
    const m = meta orelse return error.MissingImageData;
    if (m.len < 4) return error.Truncated;
    var primary: ?u32 = null;
    var ipco: ?[]const u8 = null;
    var ipma: ?[]const u8 = null;
    var it: Boxes = .{ .data = m[4..], .count = &count, .max = limits.max_chunks };
    while (try it.next()) |b| {
        if (eql(b.type, "pitm")) {
            const v = try root.int(u8, b.body, 0, .big);
            primary = if (v == 0) try root.int(u16, b.body, 4, .big) else try root.int(u32, b.body, 4, .big);
        } else if (eql(b.type, "iprp")) {
            var pit: Boxes = .{ .data = b.body, .count = &count, .max = limits.max_chunks };
            while (try pit.next()) |c| {
                if (eql(c.type, "ipco")) ipco = c.body;
                if (eql(c.type, "ipma")) ipma = c.body;
            }
        }
    }
    const id = primary orelse return error.InvalidHeader;
    var buf: [32]u16 = undefined;
    const assoc = try associations(ipma orelse return error.InvalidHeader, id, &buf);
    const props = ipco orelse return error.InvalidHeader;
    var size: ?[2]u32 = null;
    var turn = false;
    var alpha = false;
    for (assoc) |want| {
        var pit: Boxes = .{ .data = props, .count = &count, .max = limits.max_chunks };
        var idx: u16 = 0;
        while (try pit.next()) |c| {
            idx += 1;
            if (idx != want) continue;
            if (eql(c.type, "ispe")) {
                size = .{ try root.int(u32, c.body, 4, .big), try root.int(u32, c.body, 8, .big) };
            } else if (eql(c.type, "irot")) {
                turn = (try root.int(u8, c.body, 0, .big)) & 1 != 0;
            } else if (eql(c.type, "pixi")) {
                alpha = (try root.int(u8, c.body, 4, .big)) >= 4;
            }
            break;
        }
    }
    var wh = size orelse return error.InvalidHeader;
    if (turn) std.mem.swap(u32, &wh[0], &wh[1]);
    try limits.admit(wh[0], wh[1]);
    const px = @as(u64, wh[0]) * wh[1];
    return .{
        .format = .heic,
        .width = wh[0],
        .height = wh[1],
        .channels = if (alpha) 4 else 3,
        .bits = 8,
        // HEVC pictures (16-bit planes, colour and alpha), the assembled
        // image, then the RGB(A) output.
        .decode_bytes = px * 12 + px * 4,
    };
}

test "heif boxes" {
    const t = std.testing;
    const ftyp = "\x00\x00\x00\x10ftypheic\x00\x00\x00\x00";
    const pitm = "\x00\x00\x00\x0Epitm\x00\x00\x00\x00\x00\x01";
    const ispe = "\x00\x00\x00\x14ispe\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x20";
    const irot = "\x00\x00\x00\x09irot\x01";
    const ipco = "\x00\x00\x00\x25ipco" ++ ispe ++ irot;
    const ipma = "\x00\x00\x00\x15ipma\x00\x00\x00\x00\x00\x00\x00\x01\x00\x01\x02\x81\x02";
    const iprp = "\x00\x00\x00\x42iprp" ++ ipco ++ ipma;
    const meta = "\x00\x00\x00\x5Cmeta\x00\x00\x00\x00" ++ pitm ++ iprp;
    const file = ftyp ++ meta;
    try t.expectEqual(root.Format.heic, root.detect(file).?);
    const i = try root.check(file, .{});
    // 64 x 32, turned a quarter.
    try t.expectEqual(@as(u32, 32), i.width);
    try t.expectEqual(@as(u32, 64), i.height);
    try t.expectError(error.Truncated, root.check(file[0 .. file.len - 1], .{}));
    try t.expectError(error.ImageTooLarge, root.check(file, .{ .max_height = 63 }));
    try t.expectError(error.MissingImageData, root.check(ftyp, .{}));
}
