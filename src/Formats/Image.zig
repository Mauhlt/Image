const std = @import("std");
const vk = @import("Vulkan");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");
pub const BitType = union(enum) {
    rgb: [*]const RGB,
    rgba: [*]const RGBA,
};

extent: vk.Extent3D = .{
    .width = 0,
    .height = 0,
    .depth = 1,
},
pixels: BitType, // stored as multi-item pointer as len is defined by extent
pixel_format: vk.Format,

/// Frees pixel data
pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
    const len = self.extent.width * self.extent.height * self.extent.depth;
    switch (self.pixels) {
        inline else => |data| gpa.free(data[0..len]),
    }
}
