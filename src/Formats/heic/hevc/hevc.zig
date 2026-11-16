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

// The tests decode pictures made by ../testgen.zig, whose decoded samples are
// known exactly (PCM samples, and predictions worked out by hand).
const testgen = @import("../testgen.zig");

fn expectPlanes(pic: *const Picture, expected: [3][]const u8) !void {
    for (0..3) |c| {
        try std.testing.expectEqual(expected[c].len, pic.planes[c].len);
        for (pic.planes[c], expected[c], 0..) |got, want, i| if (got != want) {
            std.debug.print("plane {} at ({}, {}): got {}, expected {}\n", .{ c, i % pic.width[c], i / pic.width[c], got, want });
            return error.TestExpectedEqual;
        };
    }
}

test "later slice segments must use the picture's PPS and SPS" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try testgen.encode(arena, (try testgen.sample(arena, false, false)).picture);
    const data = try s.lengthPrefixed(arena);

    // A second PPS (id 1, on SPS 0): pps_id ue(1), sps_id ue(0), flags off,
    // num_ref_idx ue(0) x2, init_qp se(0), cb / cr offsets se(0), ...,
    // log2_parallel_merge_level ue(0).
    const pps1 = try testNal(arena, .{ 34 << 1, 1 }, "010" ++ "1" ++ "00" ++ "000" ++ "00" ++ "11" ++ "1" ++ "000" ++ "11" ++ "0" ++ "00" ++ "000" ++ "0" ++ "0" ++ "0" ++ "0" ++ "1" ++ "0");
    const sets = try std.mem.concat(arena, []const u8, &.{ s.param_sets, &.{pps1} });
    // The picture still decodes with the extra PPS present ...
    _ = try decode(arena, sets, 4, data);

    // ... but a later slice segment (IDR, not first in the picture) that
    // names PPS 1 is rejected outright. Before the fix its header was
    // parsed with PPS 1 and PPS 1's SPS (its address checked against that
    // SPS's CTB count) while the picture's tables follow the first slice's.
    const bad = try testNal(arena, .{ 19 << 1, 1 }, "0" ++ "0" ++ "010");
    var stream: std.ArrayList(u8) = .empty;
    try stream.appendSlice(arena, data);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(bad.len), .big);
    try stream.appendSlice(arena, &len_be);
    try stream.appendSlice(arena, bad);
    try std.testing.expectError(Error.InvalidHeader, decode(arena, sets, 4, stream.items));
}

test "decode generated pictures: PCM, intra modes, a DC coefficient, two slices" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ false, true }) |two_slices| {
        const s = try testgen.sample(arena, two_slices, false);
        const stream = try testgen.encode(arena, s.picture);
        const pic = try decode(arena, stream.param_sets, 4, try stream.lengthPrefixed(arena));
        try std.testing.expectEqual(@as(usize, if (two_slices) 2 else 1), pic.slices.items.len);
        try expectPlanes(&pic, .{ s.expected[0], s.expected[1], s.expected[2] });
    }
}

test "decode a generated monochrome picture split at the picture edge" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 40 rows: the last CTU row is split implicitly into 8x8 coding units
    const p = try testgen.pcmPicture(arena, 48, 40, 7);
    const stream = try testgen.encode(arena, p);
    const pic = try decode(arena, stream.param_sets, 4, try stream.lengthPrefixed(arena));
    try std.testing.expectEqual(@as(u2, 0), pic.sps.chroma_format_idc);
    try expectPlanes(&pic, .{ p.y, &.{}, &.{} });
}

test "PCM samples after arithmetic codewords of every length" {
    // CTU 0 carries one DC coefficient of a different level each time, so
    // the codeword before CTU 1's pcm_flag ends at every bit position
    // (including on a byte boundary) and coeff_abs_level_remaining takes
    // each of its prefix lengths.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = try testgen.source(arena, 32, 16, 1, false, 99);
    var level: i32 = -70;
    while (level <= 70) : (level += 1) {
        if (level == 0) continue;
        const p: testgen.Picture = .{
            .width = 32,
            .height = 16,
            .ctus = &.{ .{ .intra = .{ .dc = level } }, .pcm },
            .y = src[0],
            .cb = src[1],
            .cr = src[2],
        };
        const stream = try testgen.encode(arena, p);
        const pic = decode(arena, stream.param_sets, 4, try stream.lengthPrefixed(arena)) catch |err| {
            std.debug.print("DC level {}\n", .{level});
            return err;
        };
        const expected: [3][]u8 = .{ try arena.dupe(u8, src[0]), try arena.dupe(u8, src[1]), try arena.dupe(u8, src[2]) };
        const flat: u8 = @intCast(std.math.clamp(128 + testgen.dcResidual(level, 4, p.qp), 0, 255));
        for (0..16) |y| @memset(expected[0][y * 32 ..][0..16], flat);
        for (1..3) |c| for (0..8) |y| @memset(expected[c][y * 16 ..][0..8], 128);
        expectPlanes(&pic, .{ expected[0], expected[1], expected[2] }) catch |err| {
            std.debug.print("DC level {}\n", .{level});
            return err;
        };
    }
}
