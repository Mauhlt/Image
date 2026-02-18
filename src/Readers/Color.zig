r: u8,
g: u8,
b: u8,
a: u8,

pub fn createColor(size: type) type {
    switch (@typeInfo(size)) {
        .int => |int| {
            switch (int.signedness) {
                .signed => @compileError("Only accepts unsigned ints."),
                .unsigned => {},
            }
        },
        else => @compileError("Only accepts unsigned ints."),
    }

    return struct {
        r: size,
        g: size,
        b: size,
        a: size,
    };
}
