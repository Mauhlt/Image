const std = @import("std");
const vk = @import("Vulkan");
const RGB = @import("Color.zig").RGB;
const RGBA = @import("Color.zig").RGBA;
pub const BitType = union(enum) {
    rgb: [*]RGB,
    rgba: [*]RGBA,
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
