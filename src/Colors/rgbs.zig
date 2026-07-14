// const std = @import("std");
//
// const POSITION = @import("position.zig");
// const GRAY = @import("gray.zig");
// const GRAYS = @import("grays.zig");
// const RGB = @import("rgb.zig");
// const RGBA = @import("rgba.zig");
// const RGBAS = @import("rgbas.zig");
// const RGBS = @This();
//
// const Order = RGB.Order;
//
// test "RGBS" {
//     const allo = std.testing.allocator;
//     const data = [_]u8{ 255, 100, 0 };
//
//     const base: RGBS = try .init(allo, &data, .rgb);
//     defer base.deinit(allo);
//
//     { // init
//         try std.testing.expectEqual(data.len / @sizeOf(RGB), base.len);
//         const rgb = try base.get(0);
//         const ergb: RGB = .{ .r = data[0], .g = data[1], .b = data[2] };
//         try std.testing.expectEqualDeep(ergb, rgb);
//     }
//
//     { // flip order
//         const rgbs: RGBS = try .init(allo, &data, .bgr);
//         defer rgbs.deinit(allo);
//         try std.testing.expectEqual(data.len / @sizeOf(RGB), rgbs.len);
//         const rgb = try rgbs.get(0);
//         const ergb: RGB = .{ .r = data[2], .g = data[1], .b = data[0] };
//         try std.testing.expectEqualDeep(ergb, rgb);
//     }
//
//     { // convert + sliced
//         const grays = try base.toGRAYS(allo);
//         defer grays.deinit(allo);
//         try std.testing.expectEqual(base.len, grays.len);
//         const sliced = try grays.slice(allo, .{});
//         defer allo.free(sliced);
//         const gray = sliced[0];
//         const egray: GRAY = .{ .g = 134 };
//         try std.testing.expectEqualDeep(egray, gray);
//     }
//
//     {
//         const rgbas = try base.toRGBAS(allo);
//         defer rgbas.deinit(allo);
//         const rgba = try rgbas.get(0);
//         const ergba: RGBA = .{ .r = data[0], .g = data[1], .b = data[2], .a = 0xFF };
//         try std.testing.expectEqualDeep(ergba, rgba);
//     }
// }
