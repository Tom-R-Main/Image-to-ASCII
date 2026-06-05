const glyph = @import("glyph_set.zig");

pub const north: u4 = 0b0001;
pub const east: u4 = 0b0010;
pub const south: u4 = 0b0100;
pub const west: u4 = 0b1000;

/// Stroke weight for drawn lines. `light` is the default box-drawing weight;
/// `heavy` and `dotted` map to Mermaid's thick (`==>`) and dotted (`-.->`) edges.
/// Dotted only has straight-run glyphs in Unicode, so dotted corners/junctions
/// fall back to light.
pub const Stroke = enum {
    light,
    heavy,
    dotted,
};

pub fn resolve(mask: u4, glyph_set: glyph.GlyphSet, stroke: Stroke) u21 {
    if (glyph_set == .ascii) return resolveAscii(mask, stroke);
    return switch (stroke) {
        .light => resolveLight(mask),
        .heavy => resolveHeavy(mask),
        .dotted => resolveDotted(mask),
    };
}

fn resolveLight(mask: u4) u21 {
    return switch (mask) {
        east, west, east | west => 0x2500, // ─ LIGHT HORIZONTAL
        north, south, north | south => 0x2502, // │ LIGHT VERTICAL
        south | east => 0x250c, // ┌
        south | west => 0x2510, // ┐
        north | east => 0x2514, // └
        north | west => 0x2518, // ┘
        north | south | east => 0x251c, // ├
        north | south | west => 0x2524, // ┤
        south | east | west => 0x252c, // ┬
        north | east | west => 0x2534, // ┴
        north | east | south | west => 0x253c, // ┼
        else => '+',
    };
}

fn resolveHeavy(mask: u4) u21 {
    return switch (mask) {
        east, west, east | west => 0x2501, // ━ HEAVY HORIZONTAL
        north, south, north | south => 0x2503, // ┃ HEAVY VERTICAL
        south | east => 0x250f, // ┏
        south | west => 0x2513, // ┓
        north | east => 0x2517, // ┗
        north | west => 0x251b, // ┛
        north | south | east => 0x2523, // ┣
        north | south | west => 0x252b, // ┫
        south | east | west => 0x2533, // ┳
        north | east | west => 0x253b, // ┻
        north | east | south | west => 0x254b, // ╋
        else => '+',
    };
}

fn resolveDotted(mask: u4) u21 {
    return switch (mask) {
        east, west, east | west => 0x2504, // ┄ LIGHT TRIPLE DASH HORIZONTAL
        north, south, north | south => 0x2506, // ┆ LIGHT TRIPLE DASH VERTICAL
        // No dotted corners/junctions exist; use light shapes so joins stay clean.
        else => resolveLight(mask),
    };
}

fn resolveAscii(mask: u4, stroke: Stroke) u21 {
    const horizontal: u21 = switch (stroke) {
        .light => '-',
        .heavy => '=',
        .dotted => '.',
    };
    const vertical: u21 = switch (stroke) {
        .light, .heavy => '|',
        .dotted => ':',
    };
    return switch (mask) {
        east, west, east | west => horizontal,
        north, south, north | south => vertical,
        else => '+',
    };
}
