const std = @import("std");
const Format = @import("Vulkan").Format;
// Colors
const GRAY = @import("color.zig").GRAY;
const RGB = @import("color.zig").RGB;
const RGBA = @import("color.zig").RGBA;
const Pixels = @import("color.zig").Pixels;

width: u32,
height: u32,
pixels: Pixels,
fmt: Format,

/// performs a deep copy of the data
pub fn copy(img: *const @This(), gpa: std.mem.Allocator) !@This() {
    const pixels = blk: switch (img.pixels) {
        inline else => |data, tag| {
            const new_data = try gpa.dupe(@TypeOf(data[0]), data);
            errdefer gpa.free(new_data);
            break :blk @unionInit(Pixels, @tagName(tag), new_data);
        }
    };
    return .{
        .width = img.width,
        .height = img.height,
        .pixels = pixels,
        .fmt = img.fmt,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.pixels.deinit(gpa);
}

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    try w.print("\nImage:\n", .{});
    try w.print("Width: {}\n", .{self.width});
    try w.print("Height: {}\n", .{self.height});
    switch (self.pixels) {
        .gray => |gray| try w.print("Pixels ({}):\n", .{gray.items.len}),
        inline else => |tag| try w.print("Pixels ({}):\n", .{tag.slice().len}),
    }
    switch (self.pixels) {
        .gray => |gray| try w.print("{}\n", .{gray.items[0]}),
        inline else => |tag| try w.print("{}\n", .{tag.get(0)}),
    }
    try w.print("Format: {t}\n", .{self.fmt});
}
