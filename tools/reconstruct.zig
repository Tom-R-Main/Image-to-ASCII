//! Reconstruct an approximate image from a rendered `Frame`.
//!
//! For the table-driven block and Braille families we know each glyph's exact
//! subcell fill, so reconstruction is faithful and needs no font rasterizer.
//! Density (and any unknown codepoint) is reconstructed as a tone halftone from
//! the default ramp coverage — this is an approximation, and is the part that a
//! real font atlas will replace once `calibrate_font.zig` is implemented.

const std = @import("std");
const ascii = @import("image_to_ascii");
const common = @import("common.zig");

const ImageBuf = common.ImageBuf;
const Rgb = common.Rgb;

/// Subpixels per cell. 2x4 matches Braille granularity and reproduces quadrant
/// (2x2) and half-block (1x2) fills exactly by row/column duplication.
pub const block_cell_w = 2;
pub const block_cell_h = 4;

pub fn reconstruct(allocator: std.mem.Allocator, frame: ascii.Frame) !ImageBuf {
    return reconstructForMode(allocator, frame, .density);
}

pub fn reconstructForMode(allocator: std.mem.Allocator, frame: ascii.Frame, mode: ascii.RenderMode) !ImageBuf {
    const dims = cellDims(mode);
    const out_w = frame.columns * dims.w;
    const out_h = frame.rows * dims.h;
    var out = try ImageBuf.alloc(allocator, out_w, out_h);
    errdefer out.deinit(allocator);

    var row: u32 = 0;
    while (row < frame.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < frame.columns) : (col += 1) {
            const idx = @as(usize, row) * frame.columns + col;
            const cp = frame.codepoints[idx];
            const fg: Rgb = if (frame.color != .none) frame.fg[idx] else .{ .r = 255, .g = 255, .b = 255 };
            const bg: Rgb = if (frame.color != .none) frame.bg[idx] else .{ .r = 0, .g = 0, .b = 0 };

            if (structuralMask(cp, mode)) |kind| {
                // Block / Braille glyphs have real sub-cell structure: paint each
                // subpixel fg or bg per the glyph mask.
                var sy: u32 = 0;
                while (sy < dims.h) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < dims.w) : (sx += 1) {
                        const on = subpixelOn(kind, cp, sx, sy, dims);
                        out.set(col * dims.w + sx, row * dims.h + sy, if (on) fg else bg);
                    }
                }
            } else {
                // Tonal glyphs (density / glyph-tone) have no sub-cell structure;
                // reconstruct the cell as a uniform blend of bg->fg by perceived
                // tone, the property the renderer actually selected on.
                // Raw ink coverage IS the cell's linear-light fraction for ink
                // over background, so blend in linear. This honestly reflects the
                // limited dynamic range of glyph tone (a glyph rarely exceeds
                // ~0.3 coverage).
                const coverage = coverageOf(cp);
                const c = blendLinear(bg, fg, coverage);
                var sy: u32 = 0;
                while (sy < dims.h) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < dims.w) : (sx += 1) {
                        out.set(col * dims.w + sx, row * dims.h + sy, c);
                    }
                }
            }
        }
    }
    return out;
}

const StructuralKind = enum { braille, block, glyph };

const CellDims = struct { w: u32, h: u32 };

fn cellDims(mode: ascii.RenderMode) CellDims {
    return if (mode == .glyph_structure)
        .{ .w = ascii.default_glyph_cell_width, .h = ascii.default_glyph_cell_height }
    else
        .{ .w = block_cell_w, .h = block_cell_h };
}

fn structuralMask(cp: u21, mode: ascii.RenderMode) ?StructuralKind {
    if (cp >= 0x2800 and cp <= 0x28FF) return .braille;
    // Block glyphs carry structure; space is tonal (empty == black/bg either way).
    if (cp != ' ' and quadrantMaskOf(cp) != null) return .block;
    if (mode == .glyph_structure and ascii.defaultGlyphCoverage(cp) != null) return .glyph;
    return null;
}

fn subpixelOn(kind: StructuralKind, cp: u21, sx: u32, sy: u32, dims: CellDims) bool {
    switch (kind) {
        .braille => {
            const mask: u8 = @intCast(cp - 0x2800);
            const bx = (sx * block_cell_w) / dims.w;
            const by = (sy * block_cell_h) / dims.h;
            return (mask & brailleDotMask(bx, by)) != 0;
        },
        .block => {
            const mask = quadrantMaskOf(cp).?;
            const qx = (sx * 2) / dims.w;
            const qy = (sy * 2) / dims.h;
            const bit = @as(u4, 1) << @intCast(qy * 2 + qx);
            return (mask & bit) != 0;
        },
        .glyph => {
            const gx = (sx * ascii.default_glyph_cell_width) / dims.w;
            const gy = (sy * ascii.default_glyph_cell_height) / dims.h;
            return ascii.defaultGlyphMaskBit(cp, gx, gy) orelse false;
        },
    }
}

fn blendLinear(bg: Rgb, fg: Rgb, tone: f32) Rgb {
    const t = std.math.clamp(tone, 0.0, 1.0);
    return .{
        .r = common.linearToSrgb(common.srgbToLinear(bg.r) * (1.0 - t) + common.srgbToLinear(fg.r) * t),
        .g = common.linearToSrgb(common.srgbToLinear(bg.g) * (1.0 - t) + common.srgbToLinear(fg.g) * t),
        .b = common.linearToSrgb(common.srgbToLinear(bg.b) * (1.0 - t) + common.srgbToLinear(fg.b) * t),
    };
}

// Mirrors src/symbol.zig brailleDotMask (kept local; symbol.zig is core-internal).
fn brailleDotMask(x: u32, y: u32) u8 {
    return switch (y) {
        0 => if (x == 0) 0x01 else 0x08,
        1 => if (x == 0) 0x02 else 0x10,
        2 => if (x == 0) 0x04 else 0x20,
        3 => if (x == 0) 0x40 else 0x80,
        else => unreachable,
    };
}

// Reverse of src/symbol.zig quadrantCodepoint: bit layout is
// 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right.
fn quadrantMaskOf(cp: u21) ?u4 {
    return switch (cp) {
        ' ' => 0x0,
        '▘' => 0x1,
        '▝' => 0x2,
        '▀' => 0x3,
        '▖' => 0x4,
        '▌' => 0x5,
        '▞' => 0x6,
        '▛' => 0x7,
        '▗' => 0x8,
        '▚' => 0x9,
        '▐' => 0xa,
        '▜' => 0xb,
        '▄' => 0xc,
        '▙' => 0xd,
        '▟' => 0xe,
        '█' => 0xf,
        else => null,
    };
}

fn coverageOf(cp: u21) f32 {
    // Measured ink fraction from the built-in glyph atlas (covers all printable
    // ASCII, so it serves both density ramps and glyph-tone). Fall back to a
    // linear ramp position scaled into a plausible coverage range, then mid-gray.
    if (ascii.defaultGlyphCoverage(cp)) |cov| return cov;

    const ramp = ascii.default_density_ramp;
    for (ramp, 0..) |c, i| {
        if (@as(u21, c) == cp) {
            return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ramp.len - 1));
        }
    }
    return 0.5;
}

test "braille reconstruction respects dot layout" {
    const allocator = std.testing.allocator;
    // mask 0x47 = dots at (0,0),(0,1),(0,2),(0,3): full left column.
    var frame = ascii.Frame{
        .columns = 1,
        .rows = 1,
        .color = .none,
        .codepoints = try allocator.alloc(u21, 1),
        .fg = try allocator.alloc(common.Rgb, 0),
        .bg = try allocator.alloc(common.Rgb, 0),
    };
    defer frame.deinit(allocator);
    frame.codepoints[0] = 0x2800 + 0x47;

    var img = try reconstruct(allocator, frame);
    defer img.deinit(allocator);

    // Left column white (on), right column black (off).
    try std.testing.expectEqual(@as(u8, 255), img.at(0, 0).r);
    try std.testing.expectEqual(@as(u8, 0), img.at(1, 0).r);
    try std.testing.expectEqual(@as(u8, 255), img.at(0, 3).r);
}

test "half block reconstruction splits top and bottom" {
    const allocator = std.testing.allocator;
    var frame = ascii.Frame{
        .columns = 1,
        .rows = 1,
        .color = .truecolor,
        .codepoints = try allocator.alloc(u21, 1),
        .fg = try allocator.alloc(common.Rgb, 1),
        .bg = try allocator.alloc(common.Rgb, 1),
    };
    defer frame.deinit(allocator);
    frame.codepoints[0] = '▀';
    frame.fg[0] = .{ .r = 200, .g = 0, .b = 0 };
    frame.bg[0] = .{ .r = 0, .g = 0, .b = 200 };

    var img = try reconstruct(allocator, frame);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 200), img.at(0, 0).r); // top = fg
    try std.testing.expectEqual(@as(u8, 200), img.at(0, 3).b); // bottom = bg
}

test "glyph-structure reconstruction uses calibrated ascii masks" {
    const allocator = std.testing.allocator;
    var frame = ascii.Frame{
        .columns = 1,
        .rows = 1,
        .color = .none,
        .codepoints = try allocator.alloc(u21, 1),
        .fg = try allocator.alloc(common.Rgb, 0),
        .bg = try allocator.alloc(common.Rgb, 0),
    };
    defer frame.deinit(allocator);
    frame.codepoints[0] = '/';

    var tonal = try reconstruct(allocator, frame);
    defer tonal.deinit(allocator);
    var structural = try reconstructForMode(allocator, frame, .glyph_structure);
    defer structural.deinit(allocator);

    var differs = false;
    var y: u32 = 0;
    while (y < structural.height) : (y += 1) {
        var x: u32 = 0;
        while (x < structural.width) : (x += 1) {
            differs = differs or structural.at(x, y).r != tonal.at(x, y).r;
        }
    }
    try std.testing.expect(differs);
}
