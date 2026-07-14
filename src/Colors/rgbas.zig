// const std = @import("std");
//
// const POSITION = @import("position.zig");
// const GRAY = @import("gray.zig");
// const GRAYS = @import("grays.zig");
// const RGB = @import("rgb.zig");
// const RGBS = @import("rgbs.zig");
// const RGBA = @import("rgba.zig");
// const RGBAS = @This();
//
// const Order = RGBA.Order;
//
//
//
// test "RGBAS" {
//     const allo = std.testing.allocator;
//     const data = [_]u8{ 255, 100, 0, 10 };
//
//     const base: RGBAS = try .init(allo, &data, .rgba);
//     defer base.deinit(allo);
//
//     { // init
//         try std.testing.expectEqual(data.len / @sizeOf(RGBA), base.len);
//         const rgba = try base.get(0);
//         const ergba: RGBA = .{ .r = data[0], .g = data[1], .b = data[2], .a = data[3] };
//         try std.testing.expectEqualDeep(ergba, rgba);
//     }
//
//     { // flip order
//         const rgbas: RGBAS = try .init(allo, &data, .abgr);
//         defer rgbas.deinit(allo);
//         try std.testing.expectEqual(data.len / @sizeOf(RGBA), rgbas.len);
//         const rgba = try rgbas.get(0);
//         const ergba: RGBA = .{ .r = data[3], .g = data[2], .b = data[1], .a = data[0] };
//         try std.testing.expectEqualDeep(ergba, rgba);
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
//         const rgbs = try base.toRGBS(allo);
//         defer rgbs.deinit(allo);
//         const rgb = try rgbs.get(0);
//         const ergb: RGB = .{ .r = data[0], .g = data[1], .b = data[2] };
//         try std.testing.expectEqualDeep(ergb, rgb);
//     }
// }
