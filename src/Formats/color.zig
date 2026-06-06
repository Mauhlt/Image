const std = @import("std");
pub const GRAY = u8;

pub const RGB = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

pub const RGBA = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0xFF,
};

const DataOrder = enum(u64) {
    gray,
    rgb,
    rbg,
    grb,
    gbr,
    brg,
    bgr,
    rgba,
    rbga,
    grba,
    gbra,
    brga,
    bgra,
    _,
};

const PixelOrder = enum(u64) {
    gray,
    rgb,
    rgba,
};

pub const Pixels = union(PixelOrder) {
    gray: []GRAY,
    rgb: []RGB,
    rgba: []RGBA,

    pub fn init(
        gpa: std.mem.Allocator,
        data: []u8,
        data_ordering: DataOrder,
        pixel_ordering: PixelOrder,
    ) @This() {
        return switch (pixel_ordering) {
            .gray => toGRAY(gpa, data, data_ordering),
            .rgb => toRGB(gpa, data, data_ordering),
            // .rgba => toRGBA(gpa, data, data_ordering),
            else => error.Unsupported,
        };
    }

    pub fn deinit(self: *Pixels, gpa: std.mem.Allocator) void {
        switch (self) {
            inline else => |data| gpa.free(data),
        }
    }
};

fn toGRAY(
    gpa: std.mem.Allocator,
    data: []const u8,
    data_order: DataOrder,
) ![]GRAY {
    const j_step: usize = 1;
    var i_step: usize = 0;
    switch (data_order) {
        .gray => i_step = 1,
        .rgb, .rbg, .grb, .gbr, .brg, .bgr => i_step = 3,
        .rgba, .rbga, .grba, .gbra, .brga, .bgra => i_step = 4,
        _ => return error.Unsupported,
    }
    if (@mod(data.len, i_step) != 0) //
        return error.InvalidDimensions;
    var new_data = try gpa.alloc(GRAY, data.len / i_step);
    errdefer gpa.free(new_data);
    var i: usize = 0;
    var j: usize = 0;
    while (i < data.len) : ({
        i += i_step;
        j += j_step;
    }) {
        switch (data_order) {
            .gray => new_data[j] = data[i],
            .rgb, .rgba => new_data[j] = grayFromRGB(.{
                .r = data[i],
                .g = data[i + 1],
                .b = data[i + 2],
            }),
            .rbg, .rbga => new_data[j] = grayFromRGB(.{
                .r = data[i],
                .g = data[i + 2],
                .b = data[i + 1],
            }),
            .grb, .grba => grayFromRGB(.{
                .r = data[i + 1],
                .g = data[i],
                .b = data[i + 2],
            }),
            .gbr, .gbra => grayFromRGB(.{
                .r = data[i + 2],
                .g = data[i],
                .b = data[i + 1],
            }),
            .brg, .brga => grayFromRGB(.{
                .r = data[i + 1],
                .g = data[i + 2],
                .b = data[i],
            }),
            .bgr, .bgra => grayFromRGB(.{
                .r = data[i + 2],
                .g = data[i + 1],
                .b = data[i],
            }),
            _ => return error.Unsupported,
        }
    }
    return new_data;
}

fn toRGB(
    gpa: std.mem.Allocator,
    data: []const u8,
    data_order: DataOrder,
) ![]RGB {
    const j_step: usize = 1;
    var i_step: usize = 0;
    switch (data_order) {
        .gray => i_step = 1,
        .rgb, .rgba => {},
        .rbg, .grb, .gbr, .brg, .bgr => i_step = 3,
        .rbga, .grba, .gbra, .brga, .bgra => i_step = 4,
        _ => return error.Unsupported,
    }
    if (@mod(data.len, i_step) != 0) //
        return error.InvalidDimensions;
    var new_data = switch (data_order) {
        .gray => return error.Unsupported,
        .rgb, .rgba => try gpa.dupe(RGB, @as([]const RGB, data)),
        .grb, .gbr, .brg, .bgr, .grba, .gbra, .brga, .bgra => try gpa.alloc(RGB, data.len / i_step),
        _ => return error.Unsupported,
    };
    errdefer gpa.free(new_data);
    var i: usize = 0;
    var j: usize = 0;
    blk: while (i < data.len) : ({
        i += i_step;
        j += j_step;
    }) {
        switch (data_order) {
            .gray => return error.Unsupported,
            .rgb, .rgba => break :blk,
        }
    }

    switch (data_order) {
        .gray => {
            new_data = try gpa.alloc(RGB, data.len);
            for (data, 0..) |gray, i| {
                new_data[i] = .{
                    .r = gray,
                    .g = gray,
                    .b = gray,
                };
            }
        },
        .rgb => {
            if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 3);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 3;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 0],
                    .g = data[i + 1],
                    .b = data[i + 2],
                };
            }
        },
        .rbg => {
            if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 3);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 3;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 0],
                    .g = data[i + 2],
                    .b = data[i + 1],
                };
            }
        },
        .grb => {
            if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 3);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 3;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 1],
                    .g = data[i + 0],
                    .b = data[i + 2],
                };
            }
        },
        .gbr => {
            if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 3);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 3;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 2],
                    .g = data[i + 0],
                    .b = data[i + 1],
                };
            }
        },
        .brg => {
            if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 3);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 3;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 1],
                    .g = data[i + 2],
                    .b = data[i + 0],
                };
            }
        },
        .bgr => {
            if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 3);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 3;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 2],
                    .g = data[i + 1],
                    .b = data[i + 0],
                };
            }
        },
        .rgba => {
            if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 4);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 4;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 0],
                    .g = data[i + 1],
                    .b = data[i + 2],
                };
            }
        },
        .rbga => {
            if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 4);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 4;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 0],
                    .g = data[i + 2],
                    .b = data[i + 1],
                };
            }
        },
        .grba => {
            if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 4);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 4;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 1],
                    .g = data[i + 0],
                    .b = data[i + 2],
                };
            }
        },
        .gbra => {
            if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 4);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 4;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 2],
                    .g = data[i + 0],
                    .b = data[i + 1],
                };
            }
        },
        .brga => {
            if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 4);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 4;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 1],
                    .g = data[i + 2],
                    .b = data[i + 0],
                };
            }
        },
        .bgra => {
            if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
            new_data = try gpa.alloc(RGB, data.len / 4);
            var i: usize = 0;
            var j: usize = 0;
            while (i < data.len) : ({
                i += 4;
                j += 1;
            }) {
                new_data[j] = .{
                    .r = data[i + 2],
                    .g = data[i + 1],
                    .b = data[i + 0],
                };
            }
        },
        else => return error.Unsupported,
    }
    return new_data;
}

// fn toRGBA(
//     gpa: std.mem.Allocator,
//     data: []const u8,
//     data_order: DataOrder,
// ) ![]RGBA {
//     var new_data: []RGB = undefined;
//     switch (data_order) {
//         .gray => {
//             new_data = try gpa.alloc(RGBA, data.len);
//             for (data, 0..) |gray, i| {
//                 new_data[i] = .{
//                     .r = gray,
//                     .g = gray,
//                     .b = gray,
//                     .a = 0xFF,
//                 };
//             }
//         },
//         .rgb => {
//             if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 3);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 3;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 0],
//                     .g = data[i + 1],
//                     .b = data[i + 2],
//                 };
//             }
//         },
//         .rbg => {
//             if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 3);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 3;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 0],
//                     .g = data[i + 2],
//                     .b = data[i + 1],
//                 };
//             }
//         },
//         .grb => {
//             if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 3);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 3;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 1],
//                     .g = data[i + 0],
//                     .b = data[i + 2],
//                 };
//             }
//         },
//         .gbr => {
//             if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 3);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 3;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 2],
//                     .g = data[i + 0],
//                     .b = data[i + 1],
//                 };
//             }
//         },
//         .brg => {
//             if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 3);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 3;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 1],
//                     .g = data[i + 2],
//                     .b = data[i + 0],
//                 };
//             }
//         },
//         .bgr => {
//             if (@mod(data.len, 3) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 3);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 3;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 2],
//                     .g = data[i + 1],
//                     .b = data[i + 0],
//                 };
//             }
//         },
//         .rgba => {
//             if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 4);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 4;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 0],
//                     .g = data[i + 1],
//                     .b = data[i + 2],
//                 };
//             }
//         },
//         .rbga => {
//             if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 4);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 4;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 0],
//                     .g = data[i + 2],
//                     .b = data[i + 1],
//                 };
//             }
//         },
//         .grba => {
//             if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 4);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 4;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 1],
//                     .g = data[i + 0],
//                     .b = data[i + 2],
//                 };
//             }
//         },
//         .gbra => {
//             if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 4);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 4;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 2],
//                     .g = data[i + 0],
//                     .b = data[i + 1],
//                 };
//             }
//         },
//         .brga => {
//             if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 4);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 4;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 1],
//                     .g = data[i + 2],
//                     .b = data[i + 0],
//                 };
//             }
//         },
//         .bgra => {
//             if (@mod(data.len, 4) != 0) return error.InvalidDimensions;
//             new_data = try gpa.alloc(RGB, data.len / 4);
//             var i: usize = 0;
//             var j: usize = 0;
//             while (i < data.len) : ({
//                 i += 4;
//                 j += 1;
//             }) {
//                 new_data[j] = .{
//                     .r = data[i + 2],
//                     .g = data[i + 1],
//                     .b = data[i + 0],
//                 };
//             }
//         },
//         else => return error.Unsupported,
//     }
//     return new_data;
// }

fn grayFromRGB(rgb: RGB) GRAY {
    return @as(u8, @intFromFloat(0.299 * @as(f32, @floatFromInt(rgb.r)) + 0.587 * @as(f32, @floatFromInt(rgb.g)) + 0.114 * @as(f32, @floatFromInt(rgb.b))));
}
