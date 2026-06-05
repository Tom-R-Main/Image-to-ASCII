pub const GlyphSet = enum {
    unicode_box,
    ascii,
};

pub fn arrowHead(glyph_set: GlyphSet, dx: i32, dy: i32) u21 {
    if (@abs(dx) >= @abs(dy)) {
        if (dx >= 0) return switch (glyph_set) {
            .unicode_box => 0x25ba, // BLACK RIGHT-POINTING POINTER
            .ascii => '>',
        };
        return switch (glyph_set) {
            .unicode_box => 0x25c4, // BLACK LEFT-POINTING POINTER
            .ascii => '<',
        };
    }

    if (dy >= 0) return switch (glyph_set) {
        .unicode_box => 0x25bc, // BLACK DOWN-POINTING TRIANGLE
        .ascii => 'v',
    };
    return switch (glyph_set) {
        .unicode_box => 0x25b2, // BLACK UP-POINTING TRIANGLE
        .ascii => '^',
    };
}
