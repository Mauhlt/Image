const std = @import("std");

pub const Singlets = enum(u8) {
    g = 0,
};

pub const Doublets = enum(u8) {
    ga = 0b0000_0001,
    ag = 0b0000_0010,

    pub fn idx(order: @This()) [2]u8 {
        const value: u8 = @intFromEnum(order);
        return [2]u8{
            value >> 1,
            value & 1,
        };
    }
};

pub const Triplets = enum(u8) {
    rgb = 0b0000_0110,
    rbg = 0b0000_1001,
    grb = 0b0001_0010,
    brg = 0b0001_1000,
    gbr = 0b0010_0001,
    bgr = 0b0010_0100,

    pub fn idx(order: @This()) [3]u8 {
        const value: u8 = @intFromEnum(order);
        return [3]u8{
            value >> 4,
            (value >> 2) & @as(u8, 3),
            value & @as(u8, 3),
        };
    }
};

pub const Quadruplets = enum(u8) {
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

    pub fn idx(order: @This()) [4]u8 {
        const value: u8 = @intFromEnum(order);
        return [4]u8{
            (value >> 6),
            (value >> 4) & @as(u8, 3),
            (value >> 2) & @as(u8, 3),
            value & @as(u8, 3),
        };
    }
};

pub fn checkOrderFieldNames(
    gpa: std.mem.Allocator,
    exp_field_names: []const []const u8,
    act_field_names: []const [:0]const u8,
) !void {
    try std.testing.expect(exp_field_names.len <= act_field_names.len);
    var field_names = std.StringHashMap(void).init(gpa);
    defer field_names.deinit();
    for (exp_field_names) |efn| {
        try field_names.put(efn, {});
    }
    for (act_field_names) |afn| {
        if (field_names.get(afn) == null) {
            std.debug.print("Did not find: {s}\n", .{afn});
            return error.InvalidOrder;
        }
    }
}

/// Returns Enum that is a superset
fn MergeEnums(comptime types: []const type) !type {
    // check that all types are enums
    for (types) |t| {
        switch (@typeInfo(t)) {
            .@"enum" => {},
            else => @compileError("Invalid Type. Fn accepts enums only"),
        }
    }
    comptime {
        // check that backing integer for each enum is the same
        for (types[1..]) |t| {
            if (@typeInfo(t).@"enum".tag_type != @typeInfo(types[0]).@"enum".tag_type) {
                return error.MismatchingEnumTagType;
            }
        }
        // check that each enum field name and field value is unique
        for (0..types.len - 1) |i| {
            const field_names1 = std.meta.fieldNames(types[i]);
            for (i + 1..types.len) |j| {
                const field_names2 = std.meta.fieldNames(types[j]);
                for (field_names1) |fn1| {
                    for (field_names2) |fn2| {
                        if (std.mem.eql(u8, fn1, fn2)) //
                            return error.EnumNameIsNotUnique;
                        if (@intFromEnum(@field(types[i], fn1)) == @intFromEnum(@field(types[j], fn2))) //
                            return error.EnumValueIsNotUnique;
                    }
                }
            }
        }
        // compute total # of fields
        const n_fields = blk: {
            var n_fields: usize = 0;
            for (types) |t| {
                n_fields += std.meta.fieldNames(t).len;
            }
            break :blk n_fields;
        };
        // concatenate each field name + value
        var names: [n_fields][]const u8 = undefined;
        var values: [n_fields]u8 = undefined;
        var i: usize = 0;
        for (types) |t| {
            const field_names = std.meta.fieldNames(t);
            for (field_names) |field_name| {
                names[i] = field_name;
                values[i] = @intFromEnum(@field(t, field_name));
                i += 1;
            }
        }
        // reify enum
        return @Enum(
            @typeInfo(types[0]).@"enum".tag_type,
            .exhaustive,
            &names,
            &values,
        );
    }
}

pub const OrderTag: type = MergeEnums(&.{
    Singlets,
    Doublets,
    Triplets,
    Quadruplets,
}) catch unreachable;

fn checkSupersetEnumContainsSubsetEnum(SupersetEnumType: type, SubsetEnumType: type) bool {
    if (std.meta.activeTag(@typeInfo(SupersetEnumType)) != .@"enum") return false; // error.InvalidType;
    if (std.meta.activeTag(@typeInfo(SubsetEnumType)) != .@"enum") return false; // error.InvalidType;
    const subset_fns = comptime std.meta.fieldNames(SubsetEnumType);
    inline for (subset_fns) |subset_fn| {
        const value1 = @intFromEnum(@field(SubsetEnumType, subset_fn));
        const value2 = @intFromEnum(@field(SupersetEnumType, subset_fn));
        if (value1 != value2) return false;
    }
    return true;
}

test "Order" {
    // check that superset enum contains subsets
    inline for (comptime [_]type{
        Singlets,
        Doublets,
        Triplets,
        Quadruplets,
    }) |T| {
        const is_valid = checkSupersetEnumContainsSubsetEnum(OrderTag, T);
        if (!is_valid) std.debug.print("{any}: {}\n", .{ T, is_valid });
    }
}
