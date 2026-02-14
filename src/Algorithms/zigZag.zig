const std = @import("std");

pub fn zigZag() void {
    // 1. go right
    // 2. go downleft until left col or bot row
    // 3a. if bot row, go right
    // 3b. if left col, go down
    // 4. go upright until top row or right col
    // 5a. if top row, go right
    // 5b. if right col, go down
    // 6. if row 7, col 7, break
    // works!
    // for optimization: store indices as an array instead

    var i: usize = 0; // inc from [0-63]
    var s: SubIndex = .{ .row = 0, .col = 0 }; // guaranteed at top left
    var j: usize = s.subindex2Index(); // current pixel in 8x8 block = should be 0

    outer: switch (ZigZagDir.right) {
        .upright => {
            i += 1;
            // list_of_actions[i] = .upright;
            s.row -= 1;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .right;
            } else if (s.col == 7) {
                continue :outer .down;
            } else {
                continue :outer .upright;
            }
            unreachable;
        },
        .right => {
            i += 1;
            // list_of_actions[i] = .right;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .downleft;
            } else if (s.row == 7 and s.col != 7) {
                continue :outer .upright;
            } else break :outer;
            unreachable;
        },
        .downleft => {
            i += 1;
            // list_of_actions[i] = .downleft;
            s.row += 1;
            s.col -= 1;
            j = s.subindex2Index();
            if (s.row == 7) {
                continue :outer .right;
            } else if (s.col == 0) {
                continue :outer .down;
            } else {
                continue :outer .downleft;
            }
            unreachable;
        },
        .down => {
            i += 1;
            // list_of_actions[i] = .down;
            s.row += 1;
            j = s.subindex2Index();
            if (s.col == 0) {
                continue :outer .upright;
            } else if (s.col == 7) {
                continue :outer .downleft;
            }
            unreachable;
        },
        .up, .left => unreachable,
    }
}

pub fn undoZigZag() void {
    // 1. go left
    // 2. go upright until top row or right col
    // 3a. if top row, go left
    // 3b. if right col, go up
    // 4. go downleft until left col or bot row
    // 5a. if left col, go up
    // 5b. if bot row, go left
    // 6. if row 0, col 0, break!
    // works!
    // for optimization: store indices as an array instead

    var i: usize = 63; // inc from [63-0]
    var s: SubIndex = .{ .row = 7, .col = 7 }; // guaranteed at top left
    var j: usize = s.subindex2Index(); // current pixel in 8x8 block = should be 0

    outer: switch (ZigZagDir.left) {
        .upright => {
            i -= 1;
            // list_of_actions[i] = .upright;
            s.row -= 1;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .left;
            } else if (s.col == 7) {
                continue :outer .up;
            } else {
                continue :outer .upright;
            }
            unreachable;
        },
        .left => {
            i -= 1;
            // list_of_actions[i] = .right;
            s.col -= 1;
            j = s.subindex2Index();
            if (s.row == 7) {
                continue :outer .upright;
            } else if (s.row == 0 and s.col != 0) {
                continue :outer .downleft;
            } else break :outer;
            unreachable;
        },
        .downleft => {
            i -= 1;
            // list_of_actions[i] = .downleft;
            s.row += 1;
            s.col -= 1;
            j = s.subIndex2Index();
            if (s.row == 7) {
                continue :outer .left;
            } else if (s.col == 0) {
                continue :outer .up;
            } else {
                continue :outer .downleft;
            }
            unreachable;
        },
        .up => {
            i -= 1;
            // list_of_actions[i] = .down;
            s.row -= 1;
            j = s.subIndex2Index();
            if (s.col == 7) {
                continue :outer .downleft;
            } else if (s.col == 0) {
                continue :outer .upright;
            }
            unreachable;
        },
        .down, .right => unreachable,
    }
}

const ZigZagDir = enum(u8) {
    upright,
    right,
    downleft,
    down,
    up,
    left,
};

const SubIndex = struct {
    row: usize = 0,
    col: usize = 0,

    fn subIndex2Index(s: *const SubIndex) usize {
        return s.row * 8 + s.col;
    }
};

fn index2SubIndex(i: u8) SubIndex {
    const col = @mod(i, 8);
    const row = (i - col) / 8; // need checks here
    return .{
        .row = row,
        .col = col,
    };
}
