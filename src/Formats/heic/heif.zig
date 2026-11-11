//! HEIF container (ISO/IEC 23008-12 on the ISO base media file format):
//! finds the primary image and everything needed to decode it.
//!
//! A HEIC file stores "items" in a `meta` box:
//!   iinf  item types: `hvc1` (one HEVC image) or `grid` (tiles of hvc1 images)
//!   iloc  where each item's bytes are (file offsets, or inside `idat`)
//!   iref  links: `dimg` (grid -> tiles), `auxl` (alpha plane -> image), `thmb`
//!   iprp  properties (`hvcC` decoder config, `ispe` size, `irot`, `imir`,
//!         `colr`, `auxC`), attached to items by `ipma`
const std = @import("std");
const Allocator = std.mem.Allocator;
const Error = @import("../error.zig").Error;

pub const ColorInfo = struct {
    /// ITU-T H.273 codes; defaults are what HEIC files without `colr` use.
    primaries: u16 = 2, // unspecified
    transfer: u16 = 2,
    matrix: u16 = 6, // BT.601
    full_range: bool = false,
    /// true when a `colr` nclx box was present (overrides the HEVC VUI)
    explicit: bool = false,
};

/// One HEVC-coded image (a whole image or one grid tile).
pub const Coded = struct {
    /// decoder configuration (`hvcC`): parameter-set NAL units, without length prefixes
    param_sets: []const []const u8,
    /// bytes per NAL length prefix in `data`
    length_size: u8,
    /// the item's data: length-prefixed NAL units (slices)
    data: []const u8,
    width: u32,
    height: u32,
};

pub const Image = struct {
    /// final size after the grid, before rotation
    width: u32,
    height: u32,
    /// tiles in raster order (one entry for a non-grid image)
    tiles: []Coded,
    columns: u32 = 1,
    rows: u32 = 1,
    /// Transforms, applied in this order (HEIF requires clap, irot, imir):
    /// crop to the clean aperture, counter-clockwise quarter turns, mirror.
    crop: ?Crop = null,
    rotation: u2 = 0,
    mirror: ?Mirror = null,
    color: ColorInfo = .{},
    /// the alpha plane, if the file has one (an auxiliary monochrome HEVC image)
    alpha: ?[]Coded = null,

    pub const Mirror = enum { vertical_axis, horizontal_axis };
    pub const Crop = struct { x: u32, y: u32, width: u32, height: u32 };

    /// Size of the displayed image, after cropping and rotation.
    pub fn outputSize(self: Image) struct { u32, u32 } {
        const w = if (self.crop) |c| c.width else self.width;
        const h = if (self.crop) |c| c.height else self.height;
        return if (self.rotation & 1 == 1) .{ h, w } else .{ w, h };
    }
};

const Box = struct {
    type: [4]u8,
    body: []const u8,
};

const BoxIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(it: *BoxIterator) Error!?Box {
        if (it.pos >= it.data.len) return null;
        if (it.pos + 8 > it.data.len) return Error.InvalidChunkLen;
        var size: u64 = std.mem.readInt(u32, it.data[it.pos..][0..4], .big);
        const box_type = it.data[it.pos + 4 ..][0..4].*;
        var header: usize = 8;
        if (size == 1) {
            if (it.pos + 16 > it.data.len) return Error.InvalidChunkLen;
            size = std.mem.readInt(u64, it.data[it.pos + 8 ..][0..8], .big);
            header = 16;
        } else if (size == 0) {
            size = it.data.len - it.pos; // to the end
        }
        if (size < header or it.pos + size > it.data.len) return Error.InvalidChunkLen;
        const body = it.data[it.pos + header .. it.pos + @as(usize, @intCast(size))];
        it.pos += @intCast(size);
        return .{ .type = box_type, .body = body };
    }

    fn find(data: []const u8, box_type: *const [4]u8) Error!?[]const u8 {
        var it: BoxIterator = .{ .data = data };
        while (try it.next()) |b| if (std.mem.eql(u8, &b.type, box_type)) return b.body;
        return null;
    }
};

/// Big-endian reader over a box body.
const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn int(r: *Reader, comptime T: type) Error!T {
        const n = @sizeOf(T);
        if (r.pos + n > r.data.len) return Error.UnexpectedEndOfData;
        defer r.pos += n;
        return std.mem.readInt(T, r.data[r.pos..][0..n], .big);
    }
    /// Unsigned integer of `n` bytes (0, 2, 4 or 8), as used by `iloc`.
    fn sized(r: *Reader, n: u8) Error!u64 {
        return switch (n) {
            0 => 0,
            1 => try r.int(u8),
            2 => try r.int(u16),
            4 => try r.int(u32),
            8 => try r.int(u64),
            else => Error.InvalidHeader,
        };
    }
    fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (r.pos + n > r.data.len) return Error.UnexpectedEndOfData;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }
    /// version + flags of a FullBox
    fn fullBox(r: *Reader) Error!struct { version: u8, flags: u24 } {
        const v = try r.int(u32);
        return .{ .version = @truncate(v >> 24), .flags = @truncate(v) };
    }
    fn itemId(r: *Reader, wide: bool) Error!u32 {
        return if (wide) try r.int(u32) else try r.int(u16);
    }
};

const Extent = struct { offset: u64, length: u64 };
const Location = struct { construction: u4 = 0, base: u64 = 0, extents: []Extent = &.{} };

const Item = struct {
    id: u32,
    type: [4]u8 = .{ 0, 0, 0, 0 },
    location: Location = .{},
    /// 1-based indices into ipco
    props: []u16 = &.{},
};

const Ref = struct { type: [4]u8, from: u32, to: []u32 };

/// Parsed `meta` box.
const Meta = struct {
    items: std.ArrayList(Item) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    props: std.ArrayList(Box) = .empty, // ipco children, in order
    primary: u32 = 0,
    idat: []const u8 = &.{},

    fn item(m: *const Meta, id: u32) ?*Item {
        for (m.items.items) |*it| if (it.id == id) return it;
        return null;
    }
    fn prop(m: *const Meta, it: *const Item, box_type: *const [4]u8) ?[]const u8 {
        for (it.props) |idx| {
            if (idx == 0 or idx > m.props.items.len) continue;
            const b = m.props.items[idx - 1];
            if (std.mem.eql(u8, &b.type, box_type)) return b.body;
        }
        return null;
    }
    fn references(m: *const Meta, ref_type: *const [4]u8, from: u32) []const u32 {
        for (m.refs.items) |r| if (r.from == from and std.mem.eql(u8, &r.type, ref_type)) return r.to;
        return &.{};
    }
};

/// Parses the file and describes its primary image. Allocations go in `arena`.
pub fn parse(arena: Allocator, data: []const u8) !Image {
    const ftyp = try BoxIterator.find(data, "ftyp") orelse return Error.UnexpectedSignature;
    if (!isHeif(ftyp)) return Error.UnexpectedSignature;
    const meta_body = try BoxIterator.find(data, "meta") orelse return Error.InvalidHeader;
    var meta = try parseMeta(arena, meta_body);

    const primary = meta.item(meta.primary) orelse return Error.MissingFrame;
    var img: Image = .{ .width = 0, .height = 0, .tiles = &.{} };

    // `iden` items only attach transforms (irot, imir, clap) to another image.
    // Follow them to the coded image, collecting the transforms on the way;
    // an inner transform applies first, but HEIC writers use a single level.
    var src = primary;
    for (0..8) |_| {
        try applyTransforms(&meta, src, &img);
        if (!std.mem.eql(u8, &src.type, "iden")) break;
        const ids = meta.references("dimg", src.id);
        if (ids.len != 1) return Error.InvalidHeader;
        src = meta.item(ids[0]) orelse return Error.InvalidHeader;
    } else return Error.InvalidHeader; // cycle or absurd nesting

    if (std.mem.eql(u8, &src.type, "grid")) {
        const desc = try itemData(&meta, data, src);
        var r: Reader = .{ .data = desc };
        _ = try r.int(u8); // version
        const wide = (try r.int(u8)) & 1 != 0;
        img.rows = @as(u32, try r.int(u8)) + 1;
        img.columns = @as(u32, try r.int(u8)) + 1;
        img.width = if (wide) try r.int(u32) else try r.int(u16);
        img.height = if (wide) try r.int(u32) else try r.int(u16);
        const tile_ids = meta.references("dimg", src.id);
        if (tile_ids.len != img.rows * img.columns) return Error.InvalidHeader;
        img.tiles = try arena.alloc(Coded, tile_ids.len);
        for (tile_ids, img.tiles) |id, *t| t.* = try coded(arena, &meta, data, meta.item(id) orelse return Error.InvalidHeader);
    } else if (std.mem.eql(u8, &src.type, "hvc1")) {
        img.tiles = try arena.alloc(Coded, 1);
        img.tiles[0] = try coded(arena, &meta, data, src);
        img.width = img.tiles[0].width;
        img.height = img.tiles[0].height;
    } else return Error.UnsupportedFeature; // e.g. av01 (AVIF), iovl overlays, unci

    if (meta.prop(primary, "clap") orelse meta.prop(src, "clap")) |b| img.crop = try parseClap(b, img.width, img.height);

    // colour: from the primary item, else from the coded image
    if (meta.prop(primary, "colr") orelse meta.prop(src, "colr")) |b| img.color = parseColr(b) orelse img.color;
    img.alpha = try findAlpha(arena, &meta, data, src.id) orelse try findAlpha(arena, &meta, data, primary.id);
    return img;
}

/// Clean aperture (ISO/IEC 14496-12 12.1.4): a width x height window centred
/// at the image centre plus (horizOff, vertOff), all as rationals.
fn parseClap(body: []const u8, image_w: u32, image_h: u32) !Image.Crop {
    var r: Reader = .{ .data = body };
    var v: [8]i64 = undefined;
    for (&v, 0..) |*x, i| {
        // numerators are signed for the offsets; denominators are unsigned
        x.* = if (i % 2 == 0 and i >= 4) try r.int(i32) else try r.int(u32);
    }
    for ([_]usize{ 1, 3, 5, 7 }) |d| if (v[d] == 0) return Error.InvalidHeader;
    const cw = @divFloor(v[0], v[1]);
    const ch = @divFloor(v[2], v[3]);
    // left = (W - cw) / 2 + horizOff, rounded half up (as libheif does)
    const left = roundHalfUp((@as(i64, image_w) - cw) * v[5] + 2 * v[4], 2 * v[5]);
    const top = roundHalfUp((@as(i64, image_h) - ch) * v[7] + 2 * v[6], 2 * v[7]);
    if (cw <= 0 or ch <= 0 or left < 0 or top < 0 or left + cw > image_w or top + ch > image_h) return Error.InvalidHeader;
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(cw), .height = @intCast(ch) };
}

fn roundHalfUp(num: i64, den: i64) i64 {
    return @divFloor(2 * num + den, 2 * den);
}

/// Records an item's rotation / mirroring properties.
fn applyTransforms(meta: *const Meta, it: *const Item, img: *Image) !void {
    if (meta.prop(it, "irot")) |b| {
        if (b.len < 1) return Error.InvalidChunkLen;
        img.rotation = @truncate(b[0]);
    }
    if (meta.prop(it, "imir")) |b| {
        if (b.len < 1) return Error.InvalidChunkLen;
        img.mirror = if (b[0] & 1 == 0) .vertical_axis else .horizontal_axis;
    }
}

fn isHeif(ftyp: []const u8) bool {
    const brands = [_]*const [4]u8{ "heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1" };
    var i: usize = 0;
    while (i + 4 <= ftyp.len) : (i += 4) {
        if (i == 4) continue; // minor version
        for (brands) |b| if (std.mem.eql(u8, ftyp[i..][0..4], b)) return true;
    }
    return false;
}

fn parseMeta(arena: Allocator, body: []const u8) !Meta {
    var meta: Meta = .{};
    var it: BoxIterator = .{ .data = body[4..] }; // meta is a FullBox
    if (body.len < 4) return Error.InvalidChunkLen;
    while (try it.next()) |box| {
        var r: Reader = .{ .data = box.body };
        if (std.mem.eql(u8, &box.type, "pitm")) {
            const fb = try r.fullBox();
            meta.primary = try r.itemId(fb.version != 0);
        } else if (std.mem.eql(u8, &box.type, "iinf")) {
            const fb = try r.fullBox();
            const count: u32 = if (fb.version == 0) try r.int(u16) else try r.int(u32);
            var entries: BoxIterator = .{ .data = box.body[r.pos..] };
            var n: u32 = 0;
            while (try entries.next()) |infe| : (n += 1) {
                if (n >= count or !std.mem.eql(u8, &infe.type, "infe")) continue;
                var ir: Reader = .{ .data = infe.body };
                const ifb = try ir.fullBox();
                if (ifb.version < 2) continue; // pre-HEIF item info
                const id = try ir.itemId(ifb.version == 3);
                _ = try ir.int(u16); // protection index
                const item_type = (try ir.bytes(4))[0..4].*;
                (try upsertItem(arena, &meta, id)).type = item_type;
            }
        } else if (std.mem.eql(u8, &box.type, "iloc")) {
            try parseIloc(arena, &meta, box.body);
        } else if (std.mem.eql(u8, &box.type, "iref")) {
            const fb = try r.fullBox();
            var refs: BoxIterator = .{ .data = box.body[r.pos..] };
            while (try refs.next()) |ref| {
                var rr: Reader = .{ .data = ref.body };
                const from = try rr.itemId(fb.version != 0);
                const n = try rr.int(u16);
                const to = try arena.alloc(u32, n);
                for (to) |*t| t.* = try rr.itemId(fb.version != 0);
                try meta.refs.append(arena, .{ .type = ref.type, .from = from, .to = to });
            }
        } else if (std.mem.eql(u8, &box.type, "iprp")) {
            var children: BoxIterator = .{ .data = box.body };
            while (try children.next()) |c| {
                if (std.mem.eql(u8, &c.type, "ipco")) {
                    var props: BoxIterator = .{ .data = c.body };
                    while (try props.next()) |p| try meta.props.append(arena, p);
                } else if (std.mem.eql(u8, &c.type, "ipma")) {
                    try parseIpma(arena, &meta, c.body);
                }
            }
        } else if (std.mem.eql(u8, &box.type, "idat")) {
            meta.idat = box.body;
        }
    }
    return meta;
}

/// Returns the item with `id`, creating it if needed (boxes may come in any order).
fn upsertItem(arena: Allocator, meta: *Meta, id: u32) !*Item {
    if (meta.item(id)) |it| return it;
    try meta.items.append(arena, .{ .id = id });
    return &meta.items.items[meta.items.items.len - 1];
}

fn parseIloc(arena: Allocator, meta: *Meta, body: []const u8) !void {
    var r: Reader = .{ .data = body };
    const fb = try r.fullBox();
    const sizes = try r.int(u16);
    const offset_size: u8 = @truncate(sizes >> 12);
    const length_size: u8 = @truncate((sizes >> 8) & 0xF);
    const base_size: u8 = @truncate((sizes >> 4) & 0xF);
    const index_size: u8 = if (fb.version >= 1) @truncate(sizes & 0xF) else 0;
    const count: u32 = if (fb.version < 2) try r.int(u16) else try r.int(u32);
    for (0..count) |_| {
        const id = try r.itemId(fb.version >= 2);
        var loc: Location = .{};
        if (fb.version >= 1) loc.construction = @truncate(try r.int(u16));
        _ = try r.int(u16); // data reference index: 0 = this file
        loc.base = try r.sized(base_size);
        const n = try r.int(u16);
        loc.extents = try arena.alloc(Extent, n);
        for (loc.extents) |*e| {
            if (index_size > 0) _ = try r.sized(index_size);
            e.offset = try r.sized(offset_size);
            e.length = try r.sized(length_size);
        }
        (try upsertItem(arena, meta, id)).location = loc;
    }
}

fn parseIpma(arena: Allocator, meta: *Meta, body: []const u8) !void {
    var r: Reader = .{ .data = body };
    const fb = try r.fullBox();
    const count = try r.int(u32);
    for (0..count) |_| {
        const id = try r.itemId(fb.version >= 1);
        const n = try r.int(u8);
        const props = try arena.alloc(u16, n);
        for (props) |*p| {
            // high bit = "essential"; the rest is the 1-based ipco index
            p.* = if (fb.flags & 1 != 0) (try r.int(u16)) & 0x7FFF else (try r.int(u8)) & 0x7F;
        }
        (try upsertItem(arena, meta, id)).props = props;
    }
}

/// The bytes of an item (contiguous extents are returned in place, others copied).
fn itemData(meta: *const Meta, file: []const u8, it: *const Item) ![]const u8 {
    const src = switch (it.location.construction) {
        0 => file,
        1 => meta.idat,
        else => return Error.UnsupportedFeature, // item-offset construction
    };
    const exts = it.location.extents;
    if (exts.len == 0) return Error.InvalidHeader;
    if (exts.len == 1) {
        const off = it.location.base + exts[0].offset;
        // length 0 = to the end of the source
        const len = if (exts[0].length == 0) src.len - @min(src.len, off) else exts[0].length;
        if (off + len > src.len) return Error.UnexpectedEndOfData;
        return src[@intCast(off)..][0..@intCast(len)];
    }
    return Error.UnsupportedFeature; // multi-extent items: rare in HEIC
}

fn coded(arena: Allocator, meta: *const Meta, file: []const u8, it: *const Item) !Coded {
    if (!std.mem.eql(u8, &it.type, "hvc1")) return Error.UnsupportedFeature;
    const hvcc = meta.prop(it, "hvcC") orelse return Error.InvalidHeader;
    var c: Coded = .{ .param_sets = &.{}, .length_size = 4, .data = try itemData(meta, file, it), .width = 0, .height = 0 };
    try parseHvcc(arena, hvcc, &c);
    if (meta.prop(it, "ispe")) |b| {
        var r: Reader = .{ .data = b };
        _ = try r.fullBox();
        c.width = try r.int(u32);
        c.height = try r.int(u32);
    }
    return c;
}

/// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15 8.3.3.1).
fn parseHvcc(arena: Allocator, body: []const u8, c: *Coded) !void {
    if (body.len < 23) return Error.InvalidChunkLen;
    c.length_size = (body[21] & 3) + 1;
    var r: Reader = .{ .data = body, .pos = 22 };
    const n_arrays = try r.int(u8);
    var sets: std.ArrayList([]const u8) = .empty;
    for (0..n_arrays) |_| {
        _ = try r.int(u8); // completeness + NAL unit type
        const n = try r.int(u16);
        for (0..n) |_| try sets.append(arena, try r.bytes(try r.int(u16)));
    }
    c.param_sets = sets.items;
}

fn parseColr(body: []const u8) ?ColorInfo {
    if (body.len < 11 or !std.mem.eql(u8, body[0..4], "nclx")) return null; // ICC profiles: keep defaults
    return .{
        .primaries = std.mem.readInt(u16, body[4..6], .big),
        .transfer = std.mem.readInt(u16, body[6..8], .big),
        .matrix = std.mem.readInt(u16, body[8..10], .big),
        .full_range = body[10] & 0x80 != 0,
        .explicit = true,
    };
}

/// An `auxl` reference to the image whose `auxC` says "alpha".
fn findAlpha(arena: Allocator, meta: *const Meta, file: []const u8, image_id: u32) !?[]Coded {
    for (meta.refs.items) |ref| {
        if (!std.mem.eql(u8, &ref.type, "auxl")) continue;
        if (std.mem.indexOfScalar(u32, ref.to, image_id) == null) continue;
        const aux = meta.item(ref.from) orelse continue;
        const auxc = meta.prop(aux, "auxC") orelse continue;
        if (std.mem.indexOf(u8, auxc, "auxid:1") == null and std.mem.indexOf(u8, auxc, "alpha") == null) continue;
        if (std.mem.eql(u8, &aux.type, "grid")) {
            const ids = meta.references("dimg", aux.id);
            const tiles = try arena.alloc(Coded, ids.len);
            for (ids, tiles) |id, *t| t.* = try coded(arena, meta, file, meta.item(id) orelse return Error.InvalidHeader);
            return tiles;
        }
        const one = try arena.alloc(Coded, 1);
        one[0] = try coded(arena, meta, file, aux);
        return one;
    }
    return null;
}

test "parse HEIF structure of the conformance samples" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // sizes as reported by Windows' HEIF decoder
    const cases = [_]struct { []const u8, u32, u32 }{
        .{ "src/Data/Read/heic/C002.heic", 1280, 720 },
        .{ "src/Data/Read/heic/C014.heic", 300, 300 },
        .{ "src/Data/Read/heic/C021.heic", 1280, 720 },
    };
    for (cases) |c| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, c[0], arena, .unlimited);
        const img = try parse(arena, data);
        // every coded image carries its VPS, SPS and PPS
        for (img.tiles) |t| try std.testing.expect(t.param_sets.len >= 3 and t.data.len > 0);
        const w, const h = img.outputSize();
        try std.testing.expectEqual(c[1], w);
        try std.testing.expectEqual(c[2], h);
    }
}
