const std = @import("std");

pub const GrayOrder = enum(u8) {
    g,
};

// stores position as u6 (every 2 bytes = position)
pub const RgbOrder = enum(u8) {
    rgb = 0b0000_0110,
    rbg = 0b0000_1001,
    grb = 0b0001_0010,
    brg = 0b0001_1000,
    gbr = 0b0010_0001,
    bgr = 0b0010_0100,

    pub fn toRgb(order: @This()) RGB {
        const value: u8 = @intFromEnum(order);
        return .{
            .red = (value & 0b0011_0000) >> 4,
            .green = (value & 0b0000_1100) >> 2,
            .blue = (value & 0b0000_0011),
        };
    }

    pub fn toBgr(order: @This()) BGR {
        const value: u8 = @intFromEnum(order);
        return .{
            .blue = (value & 0b0000_0011),
            .green = (value & 0b0000_1100) >> 2,
            .red = (value & 0b0011_0000) >> 4,
        };
    }
};

pub const RgbaOrder = enum(u8) {
    rgba = 0b0001_1011,
    rgab = 0b0001_1110,
    rbga = 0b0010_0111,
    rbag = 0b0011_0110,
    ragb = 0b0010_1101,
    rabg = 0b0011_1001,

    grba = 0b0100_1011,
    grab = 0b0100_1110,
    brga = 0b0110_0011,
    brag = 0b0111_0010,
    argb = 0b0110_1100,
    arbg = 0b0111_1000,

    gbra = 0b1000_0111,
    garb = 0b1000_1101,
    bgra = 0b1001_0011,
    barg = 0b1011_0001,
    agrb = 0b1001_1100,
    abrg = 0b1011_0100,

    gbar = 0b1100_0110,
    gabr = 0b1100_1001,
    bgar = 0b1101_0010,
    bagr = 0b1110_0001,
    agbr = 0b1101_1000,
    abgr = 0b1110_0100,

    pub fn toRgba(order: @This()) RGBA {
        const value: u8 = @intFromEnum(order);
        return .{
            .red = (value & 0b1100_0000) >> 6,
            .green = (value & 0b0011_0000) >> 4,
            .blue = (value & 0b0000_1100) >> 2,
            .alpha = (value & 0b0000_0011),
        };
    }

    pub fn toBgra(order: @This()) BGRA {
        const value: u8 = @intFromEnum(order);
        return .{
            .blue = (value & 0b0000_1100) >> 2,
            .green = (value & 0b0011_0000) >> 4,
            .red = (value & 0b1100_0000) >> 6,
            .alpha = (value & 0b0000_0011),
        };
    }
};

pub const GRAY = extern struct {
    gray: u8,

    pub fn init(data: u8) GRAY {
        return .{ .gray = data };
    }

    pub fn initOrder(data: u8, order: GrayOrder) GRAY {
        _ = order;
        return .{ .gray = data };
    }

    pub fn luminance(self: GRAY) u8 {
        return self.gray;
    }

    pub fn luminanceNtsc(self: GRAY) u8 {
        return self.gray;
    }

    pub fn toGray(self: GRAY) GRAY {
        return self;
    }

    pub fn toGray8(self: GRAY) GRAY {
        return self;
    }
    pub fn toGray16(self: GRAY) GRAY {
        return self;
    }

    pub fn toRgb(self: GRAY) RGB {
        return .{
            .red = self.gray,
            .green = self.gray,
            .blue = self.gray,
        };
    }

    pub fn toBgr(self: GRAY) BGR {
        return .{
            .blue = self.gray,
            .green = self.gray,
            .red = self.gray,
        };
    }

    pub fn toRgba(self: GRAY) RGBA {
        return .{
            .red = self.gray,
            .green = self.gray,
            .blue = self.gray,
        };
    }

    pub fn toBgra(self: GRAY) BGRA {
        return .{
            .blue = self.gray,
            .green = self.gray,
            .red = self.gray,
        };
    }

    pub fn eql(self: GRAY, other: GRAY) bool {
        return self.gray == other.gray;
    }
};

pub const RGB = extern struct {
    red: u8,
    green: u8,
    blue: u8,

    pub fn init(data: *const [3]u8) RGB {
        return .{
            .red = data[0],
            .green = data[1],
            .blue = data[2],
        };
    }

    pub fn initOrder(data: *const [3]u8, order: RgbOrder) RGB {
        const idx = order.toRgb();
        return .{
            .red = data[idx.red],
            .green = data[idx.green],
            .blue = data[idx.blue],
        };
    }

    pub fn luminance(self: RGB) f32 {
        return 0.299 * @as(f32, @floatFromInt(self.red)) + //
            0.587 * @as(f32, @floatFromInt(self.green)) +
            0.114 * @as(f32, @floatFromInt(self.blue));
    }

    pub fn luminanceNtsc(self: RGB) u32 {
        return @intFromFloat( //
        0.3 * @as(f32, @floatFromInt(self.red)) + //
            0.59 * @as(f32, @floatFromInt(self.green)) + //
            0.11 * @as(f32, @floatFromInt(self.blue)) //
        );
    }

    pub fn toGray(self: RGB) GRAY {
        return .{
            .gray = @intFromFloat( //
            0.2989 * @as(f32, @floatFromInt(self.red)) + //
                0.587 * @as(f32, @floatFromInt(self.green)) + //
                0.1140 * @as(f32, @floatFromInt(self.blue)) //
            ),
        };
    }
    pub fn toGray8(self: RGB) GRAY {
        return .{
            .gray = @truncate( //
            (77 *% @as(u32, self.red) +% //
                150 *% @as(u32, self.green) +% //
                29 *% @as(u32, self.blue)) //
                >> 8),
        };
    }

    pub fn toGray16(self: RGB) GRAY {
        return .{
            .gray = @truncate( //
            (19595 *% @as(u32, self.red) +% //
                38470 *% @as(u32, self.green) +% //
                7471 *% @as(u32, self.blue)) //
                >> 16),
        };
    }

    pub fn toRgb(self: RGB) RGB {
        return self;
    }

    pub fn toBgr(self: RGB) BGR {
        return .{
            .blue = self.blue,
            .green = self.green,
            .red = self.red,
        };
    }

    pub fn toRgba(self: RGB) RGBA {
        return .{
            .red = self.red,
            .green = self.green,
            .blue = self.blue,
        };
    }

    pub fn toBgra(self: RGB) BGRA {
        return .{
            .blue = self.blue,
            .green = self.green,
            .red = self.red,
        };
    }

    pub fn eql(self: RGB, other: RGB) bool {
        return @as(u24, @bitCast(self)) == @as(u24, @bitCast(other));
    }
};

pub const BGR = extern struct {
    blue: u8,
    green: u8,
    red: u8,

    pub fn init(data: *const [3]u8) BGR {
        return .{
            .blue = data[0],
            .green = data[1],
            .red = data[2],
        };
    }

    pub fn initOrder(data: *const [3]u8, order: RgbOrder) BGR {
        const idx = order.toBgr();
        return .{
            .blue = data[idx.blue],
            .green = data[idx.green],
            .red = data[idx.red],
        };
    }

    pub fn luminance(self: BGR) f32 {
        return 0.114 * @as(f32, @floatFromInt(self.blue)) +
            0.587 * @as(f32, @floatFromInt(self.green)) +
            0.299 * @as(f32, @floatFromInt(self.red));
    }

    pub fn luminanceNtsc(self: BGR) u32 {
        return @intFromFloat( //
        0.11 * @as(f32, @floatFromInt(self.blue)) + //
            0.59 * @as(f32, @floatFromInt(self.green)) + //
            0.3 * @as(f32, @floatFromInt(self.red)) //
        );
    }

    pub fn toGray(self: BGR) GRAY {
        return .{
            .gray = @intFromFloat( //
            0.1140 * @as(f32, @floatFromInt(self.blue)) + //
                0.587 * @as(f32, @floatFromInt(self.green)) + //
                0.2989 * @as(f32, @floatFromInt(self.red)) //
            ),
        };
    }
    pub fn toGray8(self: BGR) GRAY {
        return .{
            .gray = @truncate( //
            (29 *% @as(u32, self.blue) +%
                150 *% @as(u32, self.green) +% //
                77 *% @as(u32, self.red)) >> 8),
        };
    }

    pub fn toGray16(self: BGR) GRAY {
        return .{
            .gray = @truncate( //
            (7471 *% @as(u32, self.blue)) +% //
                38470 *% @as(u32, self.green) +% //
                19595 *% @as(u32, self.red) >> 16),
        };
    }

    pub fn toRgb(self: BGR) RGB {
        return .{
            .red = self.red,
            .green = self.green,
            .blue = self.blue,
        };
    }

    pub fn toBgr(self: BGR) BGR {
        return self;
    }

    pub fn toRgba(self: BGR) RGBA {
        return .{
            .red = self.red,
            .green = self.green,
            .blue = self.blue,
        };
    }

    pub fn toBgra(self: BGR) BGRA {
        return .{
            .blue = self.blue,
            .green = self.green,
            .red = self.red,
        };
    }

    pub fn eql(self: BGR, other: BGR) bool {
        return @as(u24, @bitCast(self)) == @as(u24, @bitCast(other));
    }
};

pub const RGBA = extern struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8 = 0xFF,

    pub fn init(data: *const [4]u8) RGBA {
        return .{
            .red = data[0],
            .green = data[1],
            .blue = data[2],
            .alpha = data[3],
        };
    }

    pub fn initOrder(data: *const [4]u8, order: RgbaOrder) RGBA {
        const idx = order.toRgba();
        return .{
            .red = data[idx.red],
            .green = data[idx.green],
            .blue = data[idx.blue],
            .alpha = data[idx.alpha],
        };
    }

    pub fn luminance(self: RGBA) f32 {
        return 0.299 * @as(f32, @floatFromInt(self.red)) + //
            0.587 * @as(f32, @floatFromInt(self.green)) +
            0.114 * @as(f32, @floatFromInt(self.blue));
    }

    pub fn luminanceNtsc(self: RGBA) u32 {
        return @intFromFloat( //
        0.3 * @as(f32, @floatFromInt(self.red)) + //
            0.59 * @as(f32, @floatFromInt(self.green)) + //
            0.11 * @as(f32, @floatFromInt(self.blue)) //
        );
    }

    pub fn toGray(self: RGBA) GRAY {
        return .{
            .gray = @intFromFloat( //
            0.2989 * @as(f32, @floatFromInt(self.red)) + //
                0.587 * @as(f32, @floatFromInt(self.green)) + //
                0.1140 * @as(f32, @floatFromInt(self.blue)) //
            ),
        };
    }

    pub fn toGray8(self: RGBA) GRAY {
        return .{
            .gray = @truncate( //
            (77 *% @as(u32, self.red) +% //
                150 *% @as(u32, self.green) +% //
                29 *% @as(u32, self.blue)) //
                >> 8),
        };
    }

    pub fn toGray16(self: RGBA) GRAY {
        return .{
            .gray = @truncate( //
            19595 *% @as(u32, self.red) +% //
                38470 *% @as(u32, self.green) +% //
                7471 *% @as(u32, self.blue) //
            >> 16),
        };
    }

    pub fn toRgb(self: RGBA) RGB {
        return .{
            .red = self.red,
            .green = self.green,
            .blue = self.blue,
        };
    }

    pub fn toBgr(self: RGBA) BGR {
        return .{
            .blue = self.blue,
            .green = self.green,
            .red = self.red,
        };
    }

    pub fn toRgba(self: RGBA) RGBA {
        return self;
    }

    pub fn toBgra(self: RGBA) BGRA {
        return .{
            .blue = self.blue,
            .green = self.green,
            .red = self.red,
            .alpha = self.alpha,
        };
    }

    pub fn eql(self: RGBA, other: RGBA) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(other));
    }
};

pub const BGRA = extern struct {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8 = 0xFF,

    pub fn init(data: *const [4]u8) BGRA {
        return .{
            .blue = data[0],
            .green = data[1],
            .red = data[2],
            .alpha = data[3],
        };
    }

    pub fn initOrder(data: *const [4]u8, order: RgbaOrder) BGRA {
        const idx = order.toBgra();
        return .{
            .blue = data[idx.blue],
            .green = data[idx.green],
            .red = data[idx.red],
            .alpha = data[idx.alpha],
        };
    }

    pub fn luminance(self: BGRA) f32 {
        return 0.114 * @as(f32, @floatFromInt(self.blue)) + //
            0.587 * @as(f32, @floatFromInt(self.green)) + //
            0.299 * @as(f32, @floatFromInt(self.red));
    }

    pub fn luminanceNtsc(self: BGRA) u32 {
        return @intFromFloat( //
        0.11 * @as(f32, @floatFromInt(self.blue)) + //
            0.3 * @as(f32, @floatFromInt(self.red)) + //
            0.59 * @as(f32, @floatFromInt(self.green)) //
        );
    }

    pub fn toGray(self: BGRA) GRAY {
        return .{
            .gray = @intFromFloat( //
            0.1140 * @as(f32, @floatFromInt(self.blue)) + //
                0.587 * @as(f32, @floatFromInt(self.green)) +
                0.2989 * @as(f32, @floatFromInt(self.red)) //
            ),
        };
    }

    pub fn toGray8(self: BGRA) GRAY {
        return .{
            .gray = @truncate( //
            29 *% @as(u32, self.blue) +% //
                150 *% @as(u32, self.green) +%
                77 *% @as(u32, self.red) //
            >> 8),
        };
    }

    pub fn toGray16(self: BGRA) GRAY {
        return .{
            .gray = @truncate( //
            7471 *% @as(u32, self.blue) +% //
                38470 *% @as(u32, self.green) +% //
                19595 *% @as(u32, self.red) //
            >> 16),
        };
    }

    pub fn toRgb(self: BGRA) RGB {
        return .{
            .red = self.red,
            .green = self.green,
            .blue = self.blue,
        };
    }

    pub fn toBgr(self: BGRA) BGR {
        return .{
            .blue = self.blue,
            .green = self.green,
            .red = self.red,
        };
    }

    pub fn toRgba(self: BGRA) RGBA {
        return .{
            .red = self.red,
            .green = self.green,
            .blue = self.blue,
            .alpha = self.alpha,
        };
    }

    pub fn toBgra(self: BGRA) BGRA {
        return self;
    }

    pub fn eql(self: BGRA, other: BGRA) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(other));
    }
};

test "GRAY" {
    // check order
    inline for (comptime std.meta.fields(GrayOrder)) |order_field| {
        const name = order_field.name;
        const value = order_field.value;
        const g: u8 = @truncate(std.mem.indexOfScalar(u8, name, 'g').?);
        const new_value = g;
        try std.testing.expectEqual(value, new_value);
    }

    // init
    const data: u8 = 255;
    const gray1: GRAY = .init(data);

    // initOrder
    const gray2: GRAY = .initOrder(data, .g);
    try std.testing.expectEqualDeep(gray1, gray2);

    // lum
    const lum = gray1.luminance();
    try std.testing.expectEqual(255, lum);

    // lum ntsc
    const lum_ntsc = gray1.luminanceNtsc();
    try std.testing.expectEqual(lum, lum_ntsc);

    // gray
    const gray3 = gray1.toGray();
    const gray4 = gray1.toGray8();
    const gray5 = gray1.toGray16();
    try std.testing.expect(gray3.eql(gray4));
    try std.testing.expect(gray3.eql(gray5));

    // toRgb
    const rgb = gray1.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .red = 0xFF,
        .green = 0xFF,
        .blue = 0xFF,
    }, rgb);

    // toBgr
    const bgr = gray1.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .red = 0xFF,
        .green = 0xFF,
        .blue = 0xFF,
    }, bgr);

    // toRgba
    const rgba = gray1.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .red = 0xFF,
        .green = 0xFF,
        .blue = 0xFF,
        .alpha = 0xFF,
    }, rgba);

    // toBgra
    const bgra = gray1.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .blue = 0xFF,
        .green = 0xFF,
        .red = 0xFF,
        .alpha = 0xFF,
    }, bgra);

    // eql
    try std.testing.expect(gray1.eql(gray2));
}

test "RGB" {
    // check that field orders are correct
    inline for (comptime std.meta.fields(RgbOrder)) |order_field| {
        const name = order_field.name;
        const value = order_field.value;
        const r: u8 = @truncate(std.mem.indexOfScalar(u8, name, 'r').?);
        const g: u8 = @truncate(std.mem.indexOfScalar(u8, name, 'g').?);
        const b: u8 = @truncate(std.mem.indexOfScalar(u8, name, 'b').?);
        const new_value = r << 4 | g << 2 | b;
        try std.testing.expectEqual(value, new_value);
    }

    const data = [_]u8{ 255, 100, 0 };

    // init
    const rgb1 = RGB.init(&data);
    try std.testing.expectEqualDeep(RGB{
        .red = data[0],
        .green = data[1],
        .blue = data[2],
    }, rgb1);

    // initOrder
    const rgb2 = RGB.initOrder(&data, .bgr);
    try std.testing.expectEqualDeep(RGB{
        .red = data[2],
        .green = data[1],
        .blue = data[0],
    }, rgb2);

    // lum
    const lum: u8 = @intFromFloat(rgb1.luminance());
    try std.testing.expectEqual(134, lum);

    // lum ntsc
    const lum_ntsc = rgb1.luminanceNtsc();
    try std.testing.expectEqual(135, lum_ntsc);

    // gray
    const gray = rgb1.toGray();
    try std.testing.expectEqualDeep(GRAY{ .gray = 134 }, gray);

    // gray 8
    const gray8 = rgb1.toGray8();
    try std.testing.expectEqualDeep(GRAY{ .gray = 135 }, gray8);

    // gray 16
    const gray16 = rgb1.toGray16();
    try std.testing.expectEqualDeep(GRAY{ .gray = 134 }, gray16);

    // rgb
    const rgb3 = rgb1.toRgb();
    try std.testing.expectEqualDeep(rgb1, rgb3);

    // rgba
    const rgba = rgb1.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .red = rgb1.red,
        .green = rgb1.green,
        .blue = rgb1.blue,
    }, rgba);

    // bgr
    const bgr1 = rgb1.toBgr();
    try std.testing.expect(rgb1.red == bgr1.red and //
        rgb1.green == bgr1.green and //
        rgb1.blue == bgr1.blue);

    // bgra
    const bgra1 = rgb1.toBgra();
    try std.testing.expect(rgb1.red == bgra1.red and //
        rgb1.green == bgra1.green and //
        rgb1.blue == bgra1.blue and //
        0xFF == bgra1.red);

    // eql
    try std.testing.expect(rgb1.eql(rgb3));
}

test "BGR" {
    const data = [_]u8{ 0, 100, 255 };

    // init
    const bgr1 = BGR.init(&data);
    try std.testing.expectEqualDeep(BGR{
        .red = data[2],
        .green = data[1],
        .blue = data[0],
    }, bgr1);

    // initOrder
    const bgr2 = BGR.initOrder(&data, .rgb);
    try std.testing.expectEqualDeep(BGR{
        .blue = data[2],
        .green = data[1],
        .red = data[0],
    }, bgr2);

    // lum
    const lum: u8 = @intFromFloat(bgr1.luminance());
    try std.testing.expectEqual(134, lum);

    // lum ntsc
    const lum_ntsc = bgr1.luminanceNtsc();
    try std.testing.expectEqual(135, lum_ntsc);

    // gray
    const gray = bgr1.toGray();
    try std.testing.expectEqualDeep(GRAY{ .gray = 134 }, gray);

    // gray 8
    const gray8 = bgr1.toGray8();
    try std.testing.expectEqualDeep(GRAY{ .gray = 135 }, gray8);

    // gray 16
    const gray16 = bgr1.toGray16();
    try std.testing.expectEqualDeep(GRAY{ .gray = 134 }, gray16);

    // rgb
    const rgb = bgr1.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .red = bgr1.red,
        .green = bgr1.green,
        .blue = bgr1.blue,
    }, rgb);

    // bgr
    const bgr3 = bgr1.toBgr();
    try std.testing.expectEqualDeep(bgr1, bgr3);

    // rgba
    const rgba = bgr1.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .red = bgr1.red,
        .green = bgr1.green,
        .blue = bgr1.blue,
    }, rgba);

    // bgra
    const bgra1 = bgr1.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .red = bgr1.red,
        .green = bgr1.green,
        .blue = bgr1.blue,
        .alpha = 0xFF,
    }, bgra1);

    // eql
    try std.testing.expect(bgr1.eql(bgr3));
}

test "RGBA" {
    const data = [_]u8{ 255, 100, 0, 255 };

    // init
    const rgba1: RGBA = .init(&data);
    try std.testing.expect(rgba1.red == data[0] and //
        rgba1.green == data[1] and //
        rgba1.blue == data[2] and //
        rgba1.alpha == data[3]);

    // initOrder
    const rgba2: RGBA = .initOrder(&data, .bgra);
    try std.testing.expectEqualDeep(RGBA{
        .red = data[2],
        .green = data[1],
        .blue = data[0],
    }, rgba2);

    // lum
    const lum: u8 = @intFromFloat(rgba1.luminance());
    try std.testing.expectEqual(134, lum);

    // lum ntsc
    const lum_ntsc = rgba1.luminanceNtsc();
    try std.testing.expectEqual(135, lum_ntsc);

    // gray
    const gray = rgba1.toGray();
    try std.testing.expectEqual(134, gray.gray);

    // gray 8
    const gray8 = rgba1.toGray8();
    try std.testing.expectEqual(135, gray8.gray);

    // gray 16
    const gray16 = rgba1.toGray16();
    try std.testing.expectEqual(134, gray16.gray);

    // rgb
    const rgb = rgba1.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .red = data[0],
        .green = data[1],
        .blue = data[2],
    }, rgb);

    // bgr
    const bgr = rgba1.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .red = data[0],
        .green = data[1],
        .blue = data[2],
    }, bgr);

    // rgba
    const rgba3 = rgba1.toRgba();
    try std.testing.expectEqualDeep(rgba1, rgba3);

    // bgra
    const bgra = rgba1.toBgra();
    try std.testing.expect(bgra.red == rgba1.red and //
        bgra.green == rgba1.green and //
        bgra.blue == rgba1.blue and //
        bgra.alpha == rgba1.alpha);

    // eql
    try std.testing.expect(rgba1.eql(rgba3));
}

test "BGRA" {
    const data = [_]u8{ 0, 100, 255, 255 };

    // init
    const bgra1: BGRA = .init(&data);
    try std.testing.expect(bgra1.red == data[2] and //
        bgra1.green == data[1] and //
        bgra1.blue == data[0] and //
        bgra1.alpha == data[3] //
    );

    // initOrder
    const bgra2: BGRA = .initOrder(&data, .rgba);
    try std.testing.expectEqualDeep(BGRA{
        .blue = data[2],
        .green = data[1],
        .red = data[0],
        .alpha = data[3],
    }, bgra2);

    // lum
    const lum: u8 = @intFromFloat(bgra1.luminance());
    try std.testing.expectEqual(134, lum);

    // lum ntsc
    const lum_ntsc: u8 = @truncate(bgra1.luminanceNtsc());
    try std.testing.expectEqual(135, lum_ntsc);

    // gray
    const gray = bgra1.toGray();
    try std.testing.expectEqual(134, gray.gray);

    // gray 8
    const gray8 = bgra1.toGray8();
    try std.testing.expectEqual(135, gray8.gray);

    // gray 16
    const gray16 = bgra1.toGray16();
    try std.testing.expectEqual(134, gray16.gray);

    // rgb
    const rgb = bgra1.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .red = data[2],
        .green = data[1],
        .blue = data[0],
    }, rgb);

    // bgr
    const bgr = bgra1.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .blue = data[0],
        .green = data[1],
        .red = data[2],
    }, bgr);

    // rgba
    const rgba = bgra1.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .red = bgra1.red,
        .green = bgra1.green,
        .blue = bgra1.blue,
        .alpha = bgra1.alpha,
    }, rgba);

    // bgra
    const bgra3 = bgra1.toBgra();
    try std.testing.expectEqualDeep(bgra1, bgra3);

    // eql
    try std.testing.expect(bgra1.eql(bgra3));
}
