const core = @import("core.zig");

pub fn threshold(mode: core.DitherMode, x: u32, y: u32) f32 {
    return switch (mode) {
        .none, .floyd_steinberg => 0.5,
        .ordered_2x2 => ordered2x2(x, y),
        .ordered_4x4 => ordered4x4(x, y),
    };
}

fn ordered2x2(x: u32, y: u32) f32 {
    const matrix = [_]f32{
        0.125, 0.625,
        0.875, 0.375,
    };
    return matrix[((y & 1) * 2) + (x & 1)];
}

fn ordered4x4(x: u32, y: u32) f32 {
    const matrix = [_]f32{
        0.03125, 0.53125, 0.15625, 0.65625,
        0.78125, 0.28125, 0.90625, 0.40625,
        0.21875, 0.71875, 0.09375, 0.59375,
        0.96875, 0.46875, 0.84375, 0.34375,
    };
    return matrix[((y & 3) * 4) + (x & 3)];
}

test "ordered dithering is deterministic" {
    try @import("std").testing.expectEqual(threshold(.ordered_2x2, 0, 0), threshold(.ordered_2x2, 2, 2));
    try @import("std").testing.expectEqual(threshold(.ordered_4x4, 1, 2), threshold(.ordered_4x4, 5, 6));
}
