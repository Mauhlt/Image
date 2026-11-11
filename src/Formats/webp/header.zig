//! RIFF container: simple (`VP8L` / `VP8 `) or extended (`VP8X` + chunks).
//! Locates the image bitstream and reads its dimensions.
const std = @import("std");
const Error = @import("../error.zig").Error;

pub const Codec = enum { lossless, lossy };

pub const VP8L_SIG: u8 = 0x2f;

width: u32,
height: u32,
alpha: bool,
codec: Codec,
/// the VP8L / VP8 bitstream (chunk payload)
bitstream: []const u8,
/// lossy only: the ALPH chunk payload, if the image has one
alpha_chunk: ?[]const u8 = null,

pub fn decode(data: []const u8) Error!@This() {
    if (data.len < 20 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WEBP"))
        return Error.UnexpectedSignature;
    const riff_size = std.mem.readInt(u32, data[4..8], .little);
    const end = @min(data.len, @as(usize, riff_size) + 8);

    var pos: usize = 12;
    var vp8x_alpha = false;
    var alpha_chunk: ?[]const u8 = null;
    while (pos + 8 <= end) {
        const tag = data[pos..][0..4];
        const len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        if (body_start + len > end) return Error.InvalidChunkLen;
        const body = data[body_start..][0..len];
        pos = body_start + len + (len & 1); // chunks are padded to even size

        if (std.mem.eql(u8, tag, "VP8X")) {
            if (len < 10) return Error.InvalidChunkLen;
            if (body[0] & 0x02 != 0) return Error.UnsupportedFeature; // animation
            vp8x_alpha = body[0] & 0x10 != 0;
        } else if (std.mem.eql(u8, tag, "VP8L")) {
            if (len < 5 or body[0] != VP8L_SIG) return Error.UnexpectedSignature;
            const bits = std.mem.readInt(u32, body[1..5], .little);
            const version = (bits >> 29) & 0x7;
            if (version != 0) return Error.UnsupportedFeature;
            return .{
                .width = (bits & 0x3FFF) + 1,
                .height = ((bits >> 14) & 0x3FFF) + 1,
                .alpha = (bits >> 28) & 1 != 0,
                .codec = .lossless,
                .bitstream = body,
            };
        } else if (std.mem.eql(u8, tag, "VP8 ")) {
            if (len < 10) return Error.InvalidChunkLen;
            return .{
                .width = std.mem.readInt(u16, body[6..8], .little) & 0x3FFF,
                .height = std.mem.readInt(u16, body[8..10], .little) & 0x3FFF,
                .alpha = vp8x_alpha,
                .codec = .lossy,
                .bitstream = body,
                .alpha_chunk = if (vp8x_alpha) alpha_chunk else null,
            };
        } else if (std.mem.eql(u8, tag, "ALPH")) {
            alpha_chunk = body; // precedes the VP8 chunk
        }
        // ICCP, EXIF, XMP, unknown: skip
    }
    return Error.MissingScan;
}

/// RIFF + VP8L chunk header around a lossless bitstream of `len` bytes.
pub fn encodeLossless(w: *std.Io.Writer, bitstream: []const u8) !void {
    const pad = bitstream.len & 1;
    try w.writeAll("RIFF");
    try w.writeInt(u32, @intCast(4 + 8 + bitstream.len + pad), .little);
    try w.writeAll("WEBPVP8L");
    try w.writeInt(u32, @intCast(bitstream.len), .little);
    try w.writeAll(bitstream);
    if (pad == 1) try w.writeByte(0);
}
