//! Calibrated glyph helpers: tone matching and structure masks.
//!
//! The core stays dependency-free: it consumes precomputed measurements emitted
//! by tools/calibrate_font.zig, and it does not rasterize fonts at runtime.

const std = @import("std");

const default_atlas_data = @import("glyph_atlas.zig");

pub const Glyph = default_atlas_data.Glyph;
pub const cell_width = default_atlas_data.cell_width;
pub const cell_height = default_atlas_data.cell_height;
pub const cell_bits = @as(usize, cell_width) * @as(usize, cell_height);
pub const shifted_mask_count = 9;

const default_shifted_masks = buildShiftedMasks();

pub const Atlas = struct {
    cell_width: u8,
    cell_height: u8,
    /// Glyphs sorted by ascending coverage.
    glyphs: []const Glyph,
    /// Packed 1-bit masks, row-major, LSB-first within each byte.
    masks: []const u8,
    /// Optional pre-shifted masks for dx/dy in -1..1, indexed by glyph index.
    shifted_masks: ?[]const [shifted_mask_count]u128 = null,
    /// Coverage of the densest glyph; tone is scaled into [0, max] so the full
    /// glyph set is used rather than saturating at mid grays.
    max_coverage: f32,

    pub fn fromSorted(
        glyphs: []const Glyph,
        masks: []const u8,
        shifted_masks: ?[]const [shifted_mask_count]u128,
        cw: u8,
        ch: u8,
    ) Atlas {
        return .{
            .cell_width = cw,
            .cell_height = ch,
            .glyphs = glyphs,
            .masks = masks,
            .shifted_masks = shifted_masks,
            .max_coverage = glyphs[glyphs.len - 1].coverage,
        };
    }

    /// Select the glyph whose coverage best matches `tone` in [0, 1], where 0 is
    /// the lightest (least ink) and 1 the darkest (most ink).
    pub fn selectByTone(self: Atlas, tone: f32) u21 {
        const target = std.math.clamp(tone, 0.0, 1.0) * self.max_coverage;
        const gs = self.glyphs;

        // First index whose coverage >= target.
        var lo: usize = 0;
        var hi: usize = gs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (gs[mid].coverage < target) lo = mid + 1 else hi = mid;
        }

        if (lo == 0) return gs[0].codepoint;
        if (lo >= gs.len) return gs[gs.len - 1].codepoint;
        const below = gs[lo - 1];
        const above = gs[lo];
        return if (target - below.coverage <= above.coverage - target)
            below.codepoint
        else
            above.codepoint;
    }

    pub fn coverageOf(self: Atlas, codepoint: u21) ?f32 {
        const g = self.glyphFor(codepoint) orelse return null;
        return g.coverage;
    }

    pub fn glyphFor(self: Atlas, codepoint: u21) ?Glyph {
        for (self.glyphs) |g| {
            if (g.codepoint == codepoint) return g;
        }
        return null;
    }

    pub fn maskBit(self: Atlas, g: Glyph, x: u32, y: u32) bool {
        std.debug.assert(x < self.cell_width and y < self.cell_height);
        const bit_index = @as(usize, y) * self.cell_width + x;
        std.debug.assert(bit_index / 8 < g.mask_len);
        const byte = self.masks[@as(usize, g.mask_offset) + bit_index / 8];
        return (byte & (@as(u8, 1) << @intCast(bit_index % 8))) != 0;
    }

    pub fn shiftedMask(self: Atlas, glyph_index: usize, g: Glyph, dx: i32, dy: i32) u128 {
        if (self.shifted_masks) |shifted| {
            if (glyph_index < shifted.len and dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1) {
                return shifted[glyph_index][shiftIndex(dx, dy)];
            }
        }
        return computeShiftedMask(self.masks, g, dx, dy);
    }
};

pub fn defaultAtlas() Atlas {
    return Atlas.fromSorted(
        &default_atlas_data.glyphs,
        &default_atlas_data.masks,
        &default_shifted_masks,
        default_atlas_data.cell_width,
        default_atlas_data.cell_height,
    );
}

fn buildShiftedMasks() [default_atlas_data.glyphs.len][shifted_mask_count]u128 {
    @setEvalBranchQuota(20_000);
    var out: [default_atlas_data.glyphs.len][shifted_mask_count]u128 = undefined;
    for (default_atlas_data.glyphs, 0..) |g, glyph_index| {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                out[glyph_index][shiftIndex(dx, dy)] = computeShiftedMask(&default_atlas_data.masks, g, dx, dy);
            }
        }
    }
    return out;
}

fn shiftIndex(dx: i32, dy: i32) usize {
    std.debug.assert(dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1);
    return @intCast((dy + 1) * 3 + (dx + 1));
}

fn computeShiftedMask(masks: []const u8, g: Glyph, dx: i32, dy: i32) u128 {
    var mask: u128 = 0;
    var y: u32 = 0;
    while (y < cell_height) : (y += 1) {
        const sy = @as(i32, @intCast(y)) - dy;
        if (sy < 0 or sy >= cell_height) continue;

        var row = masks[@as(usize, g.mask_offset) + @as(usize, @intCast(sy))];
        if (dx > 0) {
            row = @intCast((@as(u16, row) << @intCast(dx)) & 0xff);
        } else if (dx < 0) {
            row >>= @intCast(-dx);
        }
        mask |= @as(u128, row) << @intCast(y * cell_width);
    }
    return mask;
}

/// Coverage of a codepoint in the built-in atlas, for tools (e.g. the quality
/// harness reconstructing a glyph cell).
pub fn defaultCoverage(codepoint: u21) ?f32 {
    return defaultAtlas().coverageOf(codepoint);
}

/// Perceived tone in [0, 1] of a codepoint: its ink coverage normalized by the
/// densest glyph. This is the inverse of `selectByTone`'s mapping, so a tool
/// reconstructing a glyph cell reproduces the full black->white range the glyph
/// set spans (rather than capping at the densest glyph's raw ~0.3 fraction).
pub fn defaultTone(codepoint: u21) ?f32 {
    const atlas = defaultAtlas();
    const cov = atlas.coverageOf(codepoint) orelse return null;
    return if (atlas.max_coverage > 0.0) cov / atlas.max_coverage else 0.0;
}

pub fn defaultMaskBit(codepoint: u21, x: u32, y: u32) ?bool {
    const atlas = defaultAtlas();
    const g = atlas.glyphFor(codepoint) orelse return null;
    if (x >= atlas.cell_width or y >= atlas.cell_height) return null;
    return atlas.maskBit(g, x, y);
}

test "tone selection spans space to densest glyph" {
    const atlas = defaultAtlas();
    try std.testing.expectEqual(@as(u21, ' '), atlas.selectByTone(0.0));
    // The darkest tone selects the densest glyph (max coverage).
    const densest = atlas.glyphs[atlas.glyphs.len - 1].codepoint;
    try std.testing.expectEqual(densest, atlas.selectByTone(1.0));
}

test "tone selection is monotonic in coverage" {
    const atlas = defaultAtlas();
    var prev: f32 = -1.0;
    var t: f32 = 0.0;
    while (t <= 1.0) : (t += 0.05) {
        const cp = atlas.selectByTone(t);
        const cov = atlas.coverageOf(cp).?;
        try std.testing.expect(cov >= prev - 0.0001);
        prev = cov;
    }
}

test "default coverage lookup works for ascii" {
    try std.testing.expectEqual(@as(f32, 0.0), defaultCoverage(' ').?);
    try std.testing.expect(defaultCoverage('@') != null);
    try std.testing.expectEqual(@as(?f32, null), defaultCoverage(0x2588)); // not ascii
}

test "default mask lookup works for ascii" {
    try std.testing.expect(defaultMaskBit('/', 6, 3).? or defaultMaskBit('/', 5, 4).?);
    try std.testing.expectEqual(@as(?bool, null), defaultMaskBit(0x2588, 0, 0));
    try std.testing.expectEqual(@as(?bool, null), defaultMaskBit('/', cell_width, 0));
}

test "default shifted masks include centered glyph mask" {
    const atlas = defaultAtlas();
    const slash = atlas.glyphFor('/').?;
    const shifted = atlas.shiftedMask(14, slash, 0, 0);
    try std.testing.expect((shifted & (@as(u128, 1) << (3 * cell_width + 6))) != 0 or
        (shifted & (@as(u128, 1) << (4 * cell_width + 5))) != 0);
}
