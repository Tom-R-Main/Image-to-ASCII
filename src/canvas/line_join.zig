const glyph = @import("glyph_set.zig");

pub const north: u4 = 0b0001;
pub const east: u4 = 0b0010;
pub const south: u4 = 0b0100;
pub const west: u4 = 0b1000;

pub fn resolve(mask: u4, glyph_set: glyph.GlyphSet) u21 {
    if (glyph_set == .ascii) return switch (mask) {
        east, west, east | west => '-',
        north, south, north | south => '|',
        else => '+',
    };

    return switch (mask) {
        east, west, east | west => 0x2500, // BOX DRAWINGS LIGHT HORIZONTAL
        north, south, north | south => 0x2502, // BOX DRAWINGS LIGHT VERTICAL
        south | east => 0x250c, // BOX DRAWINGS LIGHT DOWN AND RIGHT
        south | west => 0x2510, // BOX DRAWINGS LIGHT DOWN AND LEFT
        north | east => 0x2514, // BOX DRAWINGS LIGHT UP AND RIGHT
        north | west => 0x2518, // BOX DRAWINGS LIGHT UP AND LEFT
        north | south | east => 0x251c, // BOX DRAWINGS LIGHT VERTICAL AND RIGHT
        north | south | west => 0x2524, // BOX DRAWINGS LIGHT VERTICAL AND LEFT
        south | east | west => 0x252c, // BOX DRAWINGS LIGHT DOWN AND HORIZONTAL
        north | east | west => 0x2534, // BOX DRAWINGS LIGHT UP AND HORIZONTAL
        north | east | south | west => 0x253c, // BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL
        else => '+',
    };
}
