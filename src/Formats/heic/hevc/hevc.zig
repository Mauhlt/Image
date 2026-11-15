//! Decodes one HEVC still picture (an intra-coded HEIF item) into sample planes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Error = @import("../../error.zig").Error;
const bits = @import("bits.zig");
const params = @import("params.zig");
const slice = @import("slice.zig");
const filters = @import("filters.zig");
pub const Picture = @import("picture.zig").Picture;

/// `param_sets` are VPS/SPS/PPS NAL units; `data` holds `length_size`-byte
/// length-prefixed NAL units. Everything is allocated in `arena`.
pub fn decode(arena: Allocator, param_sets: []const []const u8, length_size: u8, data: []const u8) !Picture {
    var sps_list: std.ArrayList(params.Sps) = .empty;
    var pps_list: std.ArrayList(params.Pps) = .empty;
    for (param_sets) |ps| try addParamSet(arena, try bits.parseNal(arena, ps), &sps_list, &pps_list);

    var pic: ?Picture = null;
    var carry: slice.Carry = .{};
    var pos: usize = 0;
    while (pos + length_size <= data.len) {
        var len: usize = 0;
        for (data[pos..][0..length_size]) |b| len = (len << 8) | b;
        pos += length_size;
        if (len > data.len - pos) return Error.UnexpectedEndOfData;
        const nal = try bits.parseNal(arena, data[pos..][0..len]);
        pos += len;
        if (!nal.type.isSlice()) {
            try addParamSet(arena, nal, &sps_list, &pps_list);
            continue;
        }
        if (sps_list.items.len == 0 or pps_list.items.len == 0) return Error.InvalidHeader;
        if (pic) |*p| {
            // Later slice segments: H.265 7.4.7.1 requires the same PPS (so the
            // same SPS) in every slice segment header of a picture. Parse them
            // against the picture's own SPS and PPS only, so the slice address
            // is checked against the CTB count the picture's tables were built
            // for; a different pps_id is rejected by parseSliceHeader.
            const i = p.sliceStart(@intCast(p.slices.items.len - 1));
            const prev = &p.slices.items[i];
            const hdr = try params.parseSliceHeader(arena, nal.rbsp, nal.type, p.sps, @as(*const [1]params.Pps, p.pps), prev);
            if (hdr.first_in_picture) return Error.InvalidHeader; // a second picture
            try p.slices.append(arena, hdr);
        } else {
            const pps_for = try findPps(pps_list.items, nal.rbsp);
            const sps = try findSps(sps_list.items, pps_for.sps_id);
            const hdr = try params.parseSliceHeader(arena, nal.rbsp, nal.type, sps, pps_list.items, null);
            if (!hdr.first_in_picture) return Error.InvalidHeader;
            // The picture keeps its own copies: later parameter-set NAL units
            // may grow (and move) the lists.
            const sps_copy = try arena.create(params.Sps);
            sps_copy.* = sps.*;
            const pps_copy = try arena.create(params.Pps);
            pps_copy.* = pps_for.*;
            pic = try .init(arena, sps_copy, pps_copy);
            try pic.?.slices.append(arena, hdr);
        }
        const p = &pic.?;
        try slice.decode(p, @intCast(p.slices.items.len - 1), nal, &carry);
    }
    var p = pic orelse return Error.InvalidHeader;
    try filters.apply(arena, &p);
    return p;
}

fn addParamSet(arena: Allocator, nal: bits.Nal, sps_list: *std.ArrayList(params.Sps), pps_list: *std.ArrayList(params.Pps)) !void {
    switch (nal.type) {
        .sps => {
            const s = try params.parseSps(nal.rbsp);
            if (s.chroma_format_idc > 1) return Error.UnsupportedFeature; // only 4:0:0 and 4:2:0
            try sps_list.append(arena, s);
        },
        .pps => try pps_list.append(arena, try params.parsePps(arena, nal.rbsp, sps_list.items)),
        else => {},
    }
}

/// The PPS a slice refers to: slice_pic_parameter_set_id follows the first
/// flag(s) of the slice header.
fn findPps(list: []const params.Pps, rbsp: []const u8) !*const params.Pps {
    var r: bits.BitReader = .{ .data = rbsp };
    _ = try r.bit(); // first_slice_segment_in_pic_flag
    // no_output_of_prior_pics_flag is present for IRAP pictures, which are the
    // only ones a still image has
    _ = try r.bit();
    const id = try r.ue();
    for (list) |*p| if (p.id == id) return p;
    return Error.InvalidHeader;
}

fn findSps(list: []const params.Sps, id: u32) !*const params.Sps {
    for (list) |*s| if (s.id == id) return s;
    return Error.InvalidHeader;
}

/// Wyhash of the 8-bit planes, to compare against reference decodes.
fn planeHashes(pic: *const Picture) [3]u64 {
    var out: [3]u64 = @splat(0);
    for (0..3) |c| {
        var h: std.hash.Wyhash = .init(0);
        for (pic.planes[c]) |v| h.update(&.{@as(u8, @intCast(v))});
        out[c] = h.final();
    }
    return out;
}

/// Test helper: a NAL unit from its 2-byte header and rbsp bits ("0"/"1"),
/// with rbsp_trailing_bits appended.
fn testNal(arena: Allocator, header: [2]u8, comptime rbsp_bits: []const u8) ![]u8 {
    const all = rbsp_bits ++ "1";
    const out = try arena.alloc(u8, 2 + (all.len + 7) / 8);
    @memset(out, 0);
    out[0..2].* = header;
    for (all, 0..) |c, i| {
        if (c == '1') out[2 + i / 8] |= @as(u8, 0x80) >> @intCast(i % 8);
    }
    return out;
}

test "later slice segments must use the picture's PPS and SPS" {
    const heif = @import("../heif.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const data = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "src/Data/Read/heic/C002.heic", arena, .unlimited);
    const t = (try heif.parse(arena, data)).tiles[0];

    // A second PPS (id 1, on SPS 0): pps_id ue(1), sps_id ue(0), flags off,
    // num_ref_idx ue(0) x2, init_qp se(0), cb / cr offsets se(0), ...,
    // log2_parallel_merge_level ue(0).
    const pps1 = try testNal(arena, .{ 34 << 1, 1 }, "010" ++ "1" ++ "00" ++ "000" ++ "00" ++ "11" ++ "1" ++ "000" ++ "11" ++ "0" ++ "00" ++ "000" ++ "0" ++ "0" ++ "0" ++ "0" ++ "1" ++ "0");
    const sets = try std.mem.concat(arena, []const u8, &.{ t.param_sets, &.{pps1} });
    // The picture still decodes with the extra PPS present ...
    _ = try decode(arena, sets, t.length_size, t.data);

    // ... but a later slice segment (IDR, not first in the picture) that
    // names PPS 1 is rejected outright. Before the fix its header was
    // parsed with PPS 1 and PPS 1's SPS (its address checked against that
    // SPS's CTB count) while the picture's tables follow the first slice's.
    const bad = try testNal(arena, .{ 19 << 1, 1 }, "0" ++ "0" ++ "010");
    var stream: std.ArrayList(u8) = .empty;
    try stream.appendSlice(arena, t.data);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(bad.len), .big);
    try stream.appendSlice(arena, len_be[4 - t.length_size ..]);
    try stream.appendSlice(arena, bad);
    try std.testing.expectError(Error.InvalidHeader, decode(arena, sets, t.length_size, stream.items));
}

test "decode the HEIC samples bit-exactly" {
    // Wyhash of each 8-bit plane as decoded by libde265 (used offline as a reference).
    const expected = [_]struct { []const u8, [3]u64 }{
        .{ "C002", .{ 0xe04fe6c3498b58c7, 0x6f7ae8a226803502, 0xb3ae31f324667045 } },
        .{ "C014", .{ 0x65467d6684132742, 0xf7c558a8a1e4e000, 0x47564d4903b7f327 } },
        .{ "C021", .{ 0xe04fe6c3498b58c7, 0x6f7ae8a226803502, 0xb3ae31f324667045 } },
    };
    const heif = @import("../heif.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (expected) |e| {
        const path = try std.fmt.allocPrint(arena, "src/Data/Read/heic/{s}.heic", .{e[0]});
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        const img = try heif.parse(arena, data);
        const t = img.tiles[0];
        const pic = try decode(arena, t.param_sets, t.length_size, t.data);
        try std.testing.expectEqual(e[1], planeHashes(&pic));
    }
}
