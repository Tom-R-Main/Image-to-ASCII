//! Glyph-tone rendering: choosing a glyph by its measured ink coverage.
//!
//! This is the calibrated version of a density ramp. Instead of indexing a
//! hand-authored ramp string linearly, a target tone selects the glyph whose
//! real ink fraction (measured by tools/calibrate_font.zig) is closest. The
//! core stays dependency-free: it consumes a precomputed coverage table, it does
//! not rasterize fonts.

const std = @import("std");

const default_atlas_data = @import("glyph_atlas.zig");

pub const ToneGlyph = struct {
    codepoint: u21,
    /// Ink fraction in [0, 1] (a glyph rarely exceeds ~0.3 at typical cells).
    coverage: f32,
};

pub const Atlas = struct {
    /// Glyphs sorted by ascending coverage.
    glyphs: []const ToneGlyph,
    /// Coverage of the densest glyph; tone is scaled into [0, max] so the full
    /// glyph set is used rather than saturating at mid grays.
    max_coverage: f32,

    pub fn fromSorted(glyphs: []const ToneGlyph) Atlas {
        return .{ .glyphs = glyphs, .max_coverage = glyphs[glyphs.len - 1].coverage };
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
        for (self.glyphs) |g| {
            if (g.codepoint == codepoint) return g.coverage;
        }
        return null;
    }
};

pub fn defaultAtlas() Atlas {
    return Atlas.fromSorted(&default_atlas_data.glyphs);
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
