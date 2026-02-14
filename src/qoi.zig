const std = @import("std");
// structure:
// 14 byte header
// X data chunks
// 8 byte end marker

pub const EncodeError = error{};
pub const DecodeError = error{ OutOfMemory, InvalidData, EndOfStream };

const Format = enum(u8) {
    rgb = 3,
    rbba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Header = struct {
    magic: [4]u8 = "qoif",
    width: u32 = 0,
    height: u32 = 0,
    format: Format = .rgb,
    colorspace: Colorspace = .srgb,
};

pub const Run = struct {
    color: Color,
    len: usize,
};

/// Color:
/// extern struct for rgba values
pub const Color3 = extern struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn hash(c: Color3) u8 {
        return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% 0xFF *% 11);
    }

    pub fn eql(a: Color3, b: Color3) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

pub const Color4 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    pub fn hash(c: Color4) u8 {
        return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
    }

    pub fn eql(a: Color4, b: Color4) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

/// Image:
/// contains width, height, modifiable pixels, and colorspace
pub const Image = struct {
    width: u32 = 1920,
    height: u32 = 1080,
    pixels: []Color,
    colorspace: Colorspace = .srgb,

    pub fn toConst(self: *const @This()) ConstImage {
        return ConstImage{
            .width = self.width,
            .height = self.height,
            .pixels = self.pixels,
            .colorspace = self.colorspace,
        };
    }

    pub fn deinit(self: *@This(), allo: std.mem.Allocator) void {
        allo.free(self.pixels);
        self.* = undefined;
    }
};

/// Constant Image:
/// same as Image but pixels are constant
pub const ConstImage = struct {
    width: u32 = 1920,
    height: u32 = 1080,
    pixels: []const Color,
    colorspace: Colorspace = .srgb,
};

/// Checks if magic bytes are qoif
pub fn isQOI(bytes: []const u8) bool {
    if (bytes.len < Header.size) return false;
    const header = Header.decode(bytes[0..Header.size].*) catch return false;
    return (bytes.len >= Header.size + header.size);
}

pub fn decodeBuffer(allo: std.mem.Allocator, buffer: []const u8) DecodeError!Image {
    if (buffer.len < Header.size) return DecodeError.InvalidData;

    var reader: std.Io.Reader = .fixed(buffer);
    return decodeStream(allo, &reader) catch |err| switch (err) {
        error.ReadFailed => unreachable,
        else => |other| return other,
    };
}

pub fn decodeStream() void {}
