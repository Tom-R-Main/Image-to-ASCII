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

/// Sextant (2x3) sub-cell glyph. Unicode 13 "Block Sextants" (U+1FB00..U+1FB3B)
/// encode the 60 patterns that are not already a half/full block, in increasing
/// pattern order; the four exceptions map to space / left-half / right-half /
/// full. Bit layout (row-major, x fastest): bit0 bit1 / bit2 bit3 / bit4 bit5,
/// so the left column is 0x15 and the right column 0x2A.
pub fn sextantCodepoint(mask: u6) u21 {
    return switch (mask) {
        0x00 => ' ',
        0x15 => '▌', // left column  -> LEFT HALF BLOCK
        0x2A => '▐', // right column -> RIGHT HALF BLOCK
        0x3F => '█',
        else => blk: {
            // Index within the block = pattern minus 1, skipping the two
            // mid-range patterns (0x15, 0x2A) that are encoded elsewhere.
            var offset: u21 = @as(u21, mask) - 1;
            if (mask > 0x15) offset -= 1;
            if (mask > 0x2A) offset -= 1;
            break :blk 0x1FB00 + offset;
        },
    };
}

/// Octant (2x4) sub-cell glyph. Unicode 16 "Symbols for Legacy Computing
/// Supplement" encodes 230 block octants (U+1CD00..U+1CDE5) in an irregular
/// order; the other 26 patterns reuse pre-existing block/quadrant chars. The 230
/// live in `octant_block` (generated from the UnicodeData 16.0 `BLOCK OCTANT-*`
/// names); every other pattern is resolved by collapsing the 2x4 grid to a
/// quadrant glyph — exact for the 16 quadrant-expressible patterns, a safe
/// coarsening for the ~10 irregular borrows. Bit layout: bit0 bit1 / bit2 bit3 /
/// bit4 bit5 / bit6 bit7.
pub fn octantCodepoint(mask: u8) u21 {
    const cp = octant_block[mask];
    if (cp != 0) return cp;
    var q: u4 = 0;
    if ((mask & 0x05) != 0) q |= 0x1; // upper-left  (rows 0-1, col 0)
    if ((mask & 0x0A) != 0) q |= 0x2; // upper-right (rows 0-1, col 1)
    if ((mask & 0x50) != 0) q |= 0x4; // lower-left  (rows 2-3, col 0)
    if ((mask & 0xA0) != 0) q |= 0x8; // lower-right (rows 2-3, col 1)
    return quadrantCodepoint(q);
}

/// 0 marks a pattern not encoded in the block octant range (resolved via the
/// quadrant collapse in `octantCodepoint`). Generated from UnicodeData 16.0.
const octant_block = [256]u21{
    0x00000, 0x00000, 0x00000, 0x00000, 0x1CD00, 0x00000, 0x1CD01, 0x1CD02,
    0x1CD03, 0x1CD04, 0x00000, 0x1CD05, 0x1CD06, 0x1CD07, 0x1CD08, 0x00000,
    0x1CD09, 0x1CD0A, 0x1CD0B, 0x1CD0C, 0x00000, 0x1CD0D, 0x1CD0E, 0x1CD0F,
    0x1CD10, 0x1CD11, 0x1CD12, 0x1CD13, 0x1CD14, 0x1CD15, 0x1CD16, 0x1CD17,
    0x1CD18, 0x1CD19, 0x1CD1A, 0x1CD1B, 0x1CD1C, 0x1CD1D, 0x1CD1E, 0x1CD1F,
    0x00000, 0x1CD20, 0x1CD21, 0x1CD22, 0x1CD23, 0x1CD24, 0x1CD25, 0x1CD26,
    0x1CD27, 0x1CD28, 0x1CD29, 0x1CD2A, 0x1CD2B, 0x1CD2C, 0x1CD2D, 0x1CD2E,
    0x1CD2F, 0x1CD30, 0x1CD31, 0x1CD32, 0x1CD33, 0x1CD34, 0x1CD35, 0x00000,
    0x00000, 0x1CD36, 0x1CD37, 0x1CD38, 0x1CD39, 0x1CD3A, 0x1CD3B, 0x1CD3C,
    0x1CD3D, 0x1CD3E, 0x1CD3F, 0x1CD40, 0x1CD41, 0x1CD42, 0x1CD43, 0x1CD44,
    0x00000, 0x1CD45, 0x1CD46, 0x1CD47, 0x1CD48, 0x00000, 0x1CD49, 0x1CD4A,
    0x1CD4B, 0x1CD4C, 0x00000, 0x1CD4D, 0x1CD4E, 0x1CD4F, 0x1CD50, 0x00000,
    0x1CD51, 0x1CD52, 0x1CD53, 0x1CD54, 0x1CD55, 0x1CD56, 0x1CD57, 0x1CD58,
    0x1CD59, 0x1CD5A, 0x1CD5B, 0x1CD5C, 0x1CD5D, 0x1CD5E, 0x1CD5F, 0x1CD60,
    0x1CD61, 0x1CD62, 0x1CD63, 0x1CD64, 0x1CD65, 0x1CD66, 0x1CD67, 0x1CD68,
    0x1CD69, 0x1CD6A, 0x1CD6B, 0x1CD6C, 0x1CD6D, 0x1CD6E, 0x1CD6F, 0x1CD70,
    0x00000, 0x1CD71, 0x1CD72, 0x1CD73, 0x1CD74, 0x1CD75, 0x1CD76, 0x1CD77,
    0x1CD78, 0x1CD79, 0x1CD7A, 0x1CD7B, 0x1CD7C, 0x1CD7D, 0x1CD7E, 0x1CD7F,
    0x1CD80, 0x1CD81, 0x1CD82, 0x1CD83, 0x1CD84, 0x1CD85, 0x1CD86, 0x1CD87,
    0x1CD88, 0x1CD89, 0x1CD8A, 0x1CD8B, 0x1CD8C, 0x1CD8D, 0x1CD8E, 0x1CD8F,
    0x00000, 0x1CD90, 0x1CD91, 0x1CD92, 0x1CD93, 0x00000, 0x1CD94, 0x1CD95,
    0x1CD96, 0x1CD97, 0x00000, 0x1CD98, 0x1CD99, 0x1CD9A, 0x1CD9B, 0x00000,
    0x1CD9C, 0x1CD9D, 0x1CD9E, 0x1CD9F, 0x1CDA0, 0x1CDA1, 0x1CDA2, 0x1CDA3,
    0x1CDA4, 0x1CDA5, 0x1CDA6, 0x1CDA7, 0x1CDA8, 0x1CDA9, 0x1CDAA, 0x1CDAB,
    0x00000, 0x1CDAC, 0x1CDAD, 0x1CDAE, 0x1CDAF, 0x1CDB0, 0x1CDB1, 0x1CDB2,
    0x1CDB3, 0x1CDB4, 0x1CDB5, 0x1CDB6, 0x1CDB7, 0x1CDB8, 0x1CDB9, 0x1CDBA,
    0x1CDBB, 0x1CDBC, 0x1CDBD, 0x1CDBE, 0x1CDBF, 0x1CDC0, 0x1CDC1, 0x1CDC2,
    0x1CDC3, 0x1CDC4, 0x1CDC5, 0x1CDC6, 0x1CDC7, 0x1CDC8, 0x1CDC9, 0x1CDCA,
    0x1CDCB, 0x1CDCC, 0x1CDCD, 0x1CDCE, 0x1CDCF, 0x1CDD0, 0x1CDD1, 0x1CDD2,
    0x1CDD3, 0x1CDD4, 0x1CDD5, 0x1CDD6, 0x1CDD7, 0x1CDD8, 0x1CDD9, 0x1CDDA,
    0x00000, 0x1CDDB, 0x1CDDC, 0x1CDDD, 0x1CDDE, 0x00000, 0x1CDDF, 0x1CDE0,
    0x1CDE1, 0x1CDE2, 0x00000, 0x1CDE3, 0x00000, 0x1CDE4, 0x1CDE5, 0x00000,
};

/// Inverse of `sextantCodepoint` for the block-sextant range (U+1FB00..U+1FB3B).
/// Returns null for anything else (the space/half/full exceptions are recovered
/// via the quadrant inverse). Used by the offline quality harness.
pub fn sextantMask(cp: u21) ?u6 {
    if (cp < 0x1FB00 or cp > 0x1FB3B) return null;
    const offset = cp - 0x1FB00;
    const pat = if (offset <= 0x13) offset + 1 else if (offset <= 0x27) offset + 2 else offset + 3;
    return @intCast(pat);
}

/// Inverse of `octantCodepoint` for the block-octant range (U+1CD00..U+1CDE5).
/// Returns null otherwise (fallback patterns are quadrant chars, recovered via
/// the quadrant inverse). Used by the offline quality harness.
pub fn octantMask(cp: u21) ?u8 {
    if (cp < 0x1CD00 or cp > 0x1CDE5) return null;
    for (octant_block, 0..) |c, pat| {
        if (c == cp) return @intCast(pat);
    }
    return null;
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

test "sextant masks map to block sextants with the right exceptions" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u21, ' '), sextantCodepoint(0x00));
    try testing.expectEqual(@as(u21, 0x1FB00), sextantCodepoint(0x01)); // first block sextant
    try testing.expectEqual(@as(u21, '▌'), sextantCodepoint(0x15)); // left column
    try testing.expectEqual(@as(u21, '▐'), sextantCodepoint(0x2A)); // right column
    try testing.expectEqual(@as(u21, '█'), sextantCodepoint(0x3F));
    try testing.expectEqual(@as(u21, 0x1FB13), sextantCodepoint(0x14)); // just below left col
    try testing.expectEqual(@as(u21, 0x1FB14), sextantCodepoint(0x16)); // just above left col
    try testing.expectEqual(@as(u21, 0x1FB3B), sextantCodepoint(0x3E)); // last block sextant
}

test "octant masks: block table for the 230, quadrant collapse otherwise" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u21, 0x1CD00), octantCodepoint(0x04)); // BLOCK OCTANT-3
    try testing.expectEqual(@as(u21, 0x1CD01), octantCodepoint(0x06)); // BLOCK OCTANT-23
    try testing.expectEqual(@as(u21, 0x1CD02), octantCodepoint(0x07)); // BLOCK OCTANT-123
    try testing.expectEqual(@as(u21, 0x1CDE5), octantCodepoint(0xFE)); // last block octant
    // Fallback patterns collapse to quadrant glyphs (never a wrong codepoint):
    try testing.expectEqual(@as(u21, ' '), octantCodepoint(0x00));
    try testing.expectEqual(@as(u21, '█'), octantCodepoint(0xFF));
    try testing.expectEqual(@as(u21, '▘'), octantCodepoint(0x05)); // upper-left vertical pair
    try testing.expectEqual(@as(u21, '▌'), octantCodepoint(0x55)); // left column
    try testing.expectEqual(@as(u21, '▀'), octantCodepoint(0x0F)); // top two rows
}

test "sextant/octant inverses round-trip the block ranges" {
    const testing = @import("std").testing;
    var m: u6 = 1;
    while (m < 0x3F) : (m += 1) {
        if (m == 0x15 or m == 0x2A) continue; // encoded outside the block
        try testing.expectEqual(@as(?u6, m), sextantMask(sextantCodepoint(m)));
    }
    var o: u32 = 0;
    while (o < 256) : (o += 1) {
        const cp = octantCodepoint(@intCast(o));
        if (cp >= 0x1CD00 and cp <= 0x1CDE5) {
            try testing.expectEqual(@as(?u8, @intCast(o)), octantMask(cp));
        }
    }
    try testing.expectEqual(@as(?u6, null), sextantMask('X'));
    try testing.expectEqual(@as(?u8, null), octantMask('X'));
}

test "braille dot masks match Unicode layout" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u8, 0x01), brailleDotMask(0, 0));
    try testing.expectEqual(@as(u8, 0x08), brailleDotMask(1, 0));
    try testing.expectEqual(@as(u8, 0x40), brailleDotMask(0, 3));
    try testing.expectEqual(@as(u8, 0x80), brailleDotMask(1, 3));
}
