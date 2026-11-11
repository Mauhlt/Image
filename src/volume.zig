//! Volume = a 3D/4D grid of scalar voxels (medical / scientific formats:
//! NRRD, NIfTI, DICOM series). Voxels keep their stored type (i16, f32, ...)
//! in native endianness; x varies fastest, then y, z, t.
//!
//! A volume is also a "series of images": `sliceImage` windows one z-slice
//! into an 8-bit gray `Image` for display, `sliceBytes` gives the raw slice.
const std = @import("std");
const vk = @import("Vulkan");
const Image = @import("root.zig");

pub const DType = enum(u8) {
    u8,
    i8,
    u16,
    i16,
    u32,
    i32,
    u64,
    i64,
    f32,
    f64,

    pub fn size(self: DType) u8 {
        return switch (self) {
            .u8, .i8 => 1,
            .u16, .i16 => 2,
            .u32, .i32, .f32 => 4,
            .u64, .i64, .f64 => 8,
        };
    }

    pub fn Type(comptime self: DType) type {
        return switch (self) {
            .u8 => u8,
            .i8 => i8,
            .u16 => u16,
            .i16 => i16,
            .u32 => u32,
            .i32 => i32,
            .u64 => u64,
            .i64 => i64,
            .f32 => f32,
            .f64 => f64,
        };
    }

    /// Single-channel Vulkan format for uploading a slice / 3D texture as-is.
    pub fn fmt(self: DType) vk.Format {
        return switch (self) {
            .u8 => .r8_uint,
            .i8 => .r8_sint,
            .u16 => .r16_uint,
            .i16 => .r16_sint,
            .u32 => .r32_uint,
            .i32 => .r32_sint,
            .u64 => .r64_uint,
            .i64 => .r64_sint,
            .f32 => .r32_sfloat,
            .f64 => .r64_sfloat,
        };
    }
};

const Volume = @This();

/// x, y, z, t (unused trailing dims are 1).
dims: [4]u32,
dtype: DType,
/// Physical voxel size along x, y, z (mm for medical data; 1 if unknown).
spacing: [3]f64 = .{ 1, 1, 1 },
/// Voxel index (i, j, k) -> world (RAS+ for NIfTI, LPS+ for DICOM/most NRRD):
/// world = affine[r][0]*i + affine[r][1]*j + affine[r][2]*k + affine[r][3].
affine: [3][4]f64 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } },
/// Real value = stored * slope + intercept (NIfTI scl_*, DICOM Rescale*).
slope: f64 = 1,
intercept: f64 = 0,
/// Voxel bytes, native endian, packed, len == nVoxels() * dtype.size().
data: []u8,

pub fn nVoxels(self: *const Volume) usize {
    return @as(usize, self.dims[0]) * self.dims[1] * self.dims[2] * self.dims[3];
}

pub fn sliceVoxels(self: *const Volume) usize {
    return @as(usize, self.dims[0]) * self.dims[1];
}

/// Total bytes for the given shape, or error on overflow / zero dims.
pub fn byteLenFor(dims: [4]u32, dtype: DType) !usize {
    var n: usize = dtype.size();
    for (dims) |d| {
        if (d == 0) return error.InvalidDimensions;
        n, const of = @mulWithOverflow(n, @as(usize, d));
        if (of != 0) return error.InvalidDimensions;
    }
    return n;
}

pub fn nSlices(self: *const Volume) usize {
    return @as(usize, self.dims[2]) * self.dims[3];
}

/// Raw bytes of slice z of volume t.
pub fn sliceBytes(self: *const Volume, z: u32, t: u32) []u8 {
    std.debug.assert(z < self.dims[2] and t < self.dims[3]);
    const len = self.sliceVoxels() * self.dtype.size();
    const idx = @as(usize, t) * self.dims[2] + z;
    return self.data[idx * len ..][0..len];
}

/// Typed view of all voxels.
pub fn voxels(self: *const Volume, comptime dt: DType) []align(1) dt.Type() {
    std.debug.assert(self.dtype == dt);
    return @ptrCast(self.data);
}

/// Stored-value range mapped to 0..255 by `window`.
pub const Window = struct {
    lo: f64,
    hi: f64,
};

/// Min / max stored value over the whole volume (handy default window).
pub fn range(self: *const Volume) Window {
    switch (self.dtype) {
        inline else => |dt| {
            const v = self.voxels(dt);
            var lo: dt.Type() = v[0];
            var hi: dt.Type() = v[0];
            for (v) |x| {
                if (x < lo) lo = x;
                if (x > hi) hi = x;
            }
            return .{ .lo = toF64(lo), .hi = toF64(hi) };
        },
    }
}

/// Window a slice of stored values into 8-bit gray: lo -> 0, hi -> 255, clamped.
/// `out.len` must equal `sliceVoxels()`.
pub fn windowInto(self: *const Volume, z: u32, t: u32, win: Window, out: []u8) void {
    std.debug.assert(out.len == self.sliceVoxels());
    const bytes = self.sliceBytes(z, t);
    switch (self.dtype) {
        inline else => |dt| {
            const src: []align(1) const dt.Type() = @ptrCast(bytes);
            windowScalar(dt.Type(), src, win, out);
        },
    }
}

/// Reference implementation (kept as the oracle for any SIMD version).
pub fn windowScalar(comptime T: type, src: []align(1) const T, win: Window, out: []u8) void {
    const span = win.hi - win.lo;
    const scale: f64 = if (span > 0) 255.0 / span else 0;
    for (src, out) |x, *o| {
        const v = (toF64(x) - win.lo) * scale;
        o.* = if (v <= 0) 0 else if (v >= 255) 255 else @intFromFloat(v + 0.5);
    }
}

/// One z-slice as an 8-bit gray Image (allocated; free with `img.deinit(gpa)`).
pub fn sliceImage(self: *const Volume, gpa: std.mem.Allocator, z: u32, t: u32, win: Window) !Image {
    const out = try gpa.alloc(u8, self.sliceVoxels());
    self.windowInto(z, t, win, out);
    return .{
        .width = self.dims[0],
        .height = self.dims[1],
        .pixels = .fromBytes(.g, out),
        .fmt = .r8_unorm,
    };
}

pub fn deinit(self: Volume, gpa: std.mem.Allocator) void {
    gpa.free(self.data);
}

fn toF64(x: anytype) f64 {
    return switch (@typeInfo(@TypeOf(x))) {
        .float => @floatCast(x),
        else => @floatFromInt(x),
    };
}

test "window slice" {
    const gpa = std.testing.allocator;
    var vals = [_]i16{ -100, 0, 100, 200, 300, 400 };
    const vol: Volume = .{ .dims = .{ 3, 1, 2, 1 }, .dtype = .i16, .data = std.mem.sliceAsBytes(&vals) };
    try std.testing.expectEqual(Window{ .lo = -100, .hi = 400 }, vol.range());
    const img = try vol.sliceImage(gpa, 1, 0, .{ .lo = 0, .hi = 400 });
    defer img.deinit(gpa);
    // 200 * (255 / 400) rounds to 127.4999.. in f64
    try std.testing.expectEqualSlices(u8, &.{ 127, 191, 255 }, img.pixels.asBytes());
}
