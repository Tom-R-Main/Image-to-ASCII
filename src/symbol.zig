pub fn quadrantCodepoint(mask: u4) u21 {
    return switch (mask) {
        0x0 => ' ',
        0x1 => '▘',
        0x2 => '▝',
        0x3 => '▀',
        0x4 => '▖',
        0x5 => '▌',
        0x6 => '▞',
        0x7 => '▛',
        0x8 => '▗',
        0x9 => '▚',
        0xa => '▐',
        0xb => '▜',
        0xc => '▄',
        0xd => '▙',
        0xe => '▟',
        0xf => '█',
    };
}

pub fn brailleDotMask(x: u32, y: u32) u8 {
    return switch (y) {
        0 => if (x == 0) 0x01 else 0x08,
        1 => if (x == 0) 0x02 else 0x10,
        2 => if (x == 0) 0x04 else 0x20,
        3 => if (x == 0) 0x40 else 0x80,
        else => unreachable,
    };
}

pub fn brailleCodepoint(mask: u8) u21 {
    return 0x2800 + @as(u21, mask);
}

test "quadrant masks map to expected block glyphs" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u21, ' '), quadrantCodepoint(0x0));
    try testing.expectEqual(@as(u21, '▘'), quadrantCodepoint(0x1));
    try testing.expectEqual(@as(u21, '▝'), quadrantCodepoint(0x2));
    try testing.expectEqual(@as(u21, '▀'), quadrantCodepoint(0x3));
    try testing.expectEqual(@as(u21, '▄'), quadrantCodepoint(0xc));
    try testing.expectEqual(@as(u21, '█'), quadrantCodepoint(0xf));
}

test "braille dot masks match Unicode layout" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u8, 0x01), brailleDotMask(0, 0));
    try testing.expectEqual(@as(u8, 0x08), brailleDotMask(1, 0));
    try testing.expectEqual(@as(u8, 0x40), brailleDotMask(0, 3));
    try testing.expectEqual(@as(u8, 0x80), brailleDotMask(1, 3));
}
