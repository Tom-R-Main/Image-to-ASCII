//! calibrate_font: SCAFFOLD for the glyph-atlas generator.
//!
//! Glyph modes (`glyph_tone`, `glyph_structure`) need per-font coverage and
//! structural features. Producing those requires rasterizing real font glyphs,
//! which means a font-rasterizer dependency (FreeType or stb_truetype) — and
//! per RESEARCH.md that dependency must live HERE in `tools/`, never in the
//! dependency-free core.
//!
//! This file currently codifies the atlas *format* and the generation pipeline
//! so the glyph work has a stable target. The rasterization step is stubbed.
//!
//! Planned pipeline (see RESEARCH.md "Font Calibration"):
//!   1. Load a TTF/OTF and a target cell size (width x height in px).
//!   2. For each candidate codepoint: validate width-1, non-combining,
//!      unambiguous width; rasterize to the cell; compute coverage + structural
//!      features (centroid, spread, dominant orientation); store the mask.
//!   3. Bucket glyphs by coverage for fast glyph-tone lookup.
//!   4. Serialize a GlyphAtlas the core can load (Level 1/2 calibration).

const std = @import("std");

/// A precomputed, font-specific glyph atlas. Mirrors the shape proposed in
/// RESEARCH.md so the serialized format and the core consumer can be developed
/// against a fixed contract.
pub const GlyphAtlas = struct {
    cell_width: u8,
    cell_height: u8,
    glyphs: []const GlyphFeature,
    buckets: []const GlyphBucket,
    /// Packed 1-bit masks (cell_width*cell_height bits per glyph), referenced by
    /// `GlyphFeature.mask_offset` / `mask_len`.
    masks: []const u8,
};

pub const GlyphFeature = struct {
    codepoint: u21,
    /// Ink fraction in [0, 1].
    coverage: f32,
    /// Quantized dominant edge orientation (0..N-1), for structure prefiltering.
    dominant_orientation: u8,
    centroid_x: f32,
    centroid_y: f32,
    spread_x: f32,
    spread_y: f32,
    mask_offset: u32,
    mask_len: u16,
};

pub const GlyphBucket = struct {
    /// Inclusive coverage range this bucket covers.
    coverage_min: f32,
    coverage_max: f32,
    /// Indices into `GlyphAtlas.glyphs`.
    first: u32,
    count: u32,
};

const CalibrateError = error{
    FontRasterizerNotImplemented,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
        \\calibrate_font (scaffold)
        \\
        \\This tool will generate a per-font GlyphAtlas for the glyph render modes.
        \\It is not yet implemented: it requires a font rasterizer (FreeType or
        \\stb_truetype) wired in as a tools-only dependency.
        \\
        \\Atlas format (already defined in tools/calibrate_font.zig):
        \\  GlyphAtlas { cell_width, cell_height, glyphs[], buckets[], masks[] }
        \\  GlyphFeature { codepoint, coverage, dominant_orientation,
        \\                 centroid_x/y, spread_x/y, mask_offset, mask_len }
        \\  GlyphBucket  { coverage_min, coverage_max, first, count }
        \\
        \\Next steps:
        \\  1. Add a permissive font rasterizer dependency under tools/.
        \\  2. Implement rasterize() + feature extraction.
        \\  3. Emit a serialized atlas consumable by src/glyph.zig.
        \\
    );
    try stdout.flush();
}

/// Placeholder for the rasterization step. Returns an explicit error until a
/// font rasterizer is wired in, so callers fail loudly rather than silently.
pub fn rasterize(_: []const u8, _: u8, _: u8) CalibrateError!GlyphAtlas {
    return CalibrateError.FontRasterizerNotImplemented;
}

test "atlas format is well defined and rasterize stub reports its status" {
    try std.testing.expectError(CalibrateError.FontRasterizerNotImplemented, rasterize("font.ttf", 8, 16));
    // The format must round-trip trivially as a value type.
    const atlas = GlyphAtlas{ .cell_width = 8, .cell_height = 16, .glyphs = &.{}, .buckets = &.{}, .masks = &.{} };
    try std.testing.expectEqual(@as(u8, 8), atlas.cell_width);
}
