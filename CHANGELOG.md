# Changelog

## Unreleased

### Performance

- sRGB->linear conversion is now a compile-time 256-entry lookup table instead of
  a per-pixel `pow`. Because the input domain is a byte, the table is
  bit-identical to the previous formula (verified by test). This is the hot path
  (the sampler revisits it for every source pixel) and is ~7-10x faster across
  modes (e.g. density 2.57ms -> 0.25ms, braille truecolor 5.75ms -> 0.79ms for
  400x240 -> 80x30 in ReleaseFast).
- `areaSample` no longer eagerly encodes sRGB for every subcell sample;
  `Sample.rgb()` is deferred to the point a color is actually emitted, removing
  3 `pow` per subcell on the block/Braille paths (further ~1.3-1.6x there).
- Reworked `zig build bench` into a render-kernel matrix (density / half /
  quadrant / Braille, mono and truecolor, plus an ANSI-writer row) reporting
  ns/cell, cells/sec, and bytes.
- Added an integral-image (summed-area table) luma sampler for monochrome modes,
  selectable via `Options.sample_strategy` (`auto` / `direct_box` /
  `integral_luma`). Fractional bilinear queries make it equal to the direct
  sampler to floating-point rounding (verified by unit, render-level, and quality
  harness A/B tests). `auto` stays on the direct sampler because building the
  table is itself an O(image) pass — it only pays off when reused across renders
  (live resize), which is what the explicit `integral_luma` strategy is for. The
  harness gained `--strategy`.

### Added

- Configurable representative-color solve for two-color symbol families
  (`Options.color_stat`: `mean`, `trimmed_mean`, `median`) in linear light, per
  RESEARCH.md "Color Strategy". Quadrant and Braille foreground/background
  colors now default to the robust `trimmed_mean` instead of a plain mean.
- Quality-harness scaffold under `tools/`: `zig build compare` renders an image,
  reconstructs it from the emitted cells (block/Braille masks; density halftone
  approximation), and scores PSNR/SSIM/edge-correlation with no font rasterizer.
- `tools/calibrate_font.zig` now rasterizes real glyphs via stb_truetype
  (public domain, vendored under `tools/stb/`, linked only into the tool). It
  computes per-glyph coverage, ink centroid/spread, a quantized dominant edge
  orientation, and a packed 1-bit mask, buckets glyphs by coverage, and can emit
  a self-contained Zig atlas literal (`--out`) for the upcoming glyph modes.

### Fixed

- `FitMode.cover` now fills the output grid by cropping the source to the grid's
  display aspect (centered) instead of stretching it like `stretch`.

## v0.1.0 - 2026-06-05

### Added

- Zig package bootstrap for `image_to_ascii`.
- Raw RGBA `ImageView` input and SoA `Frame` output.
- Density rendering.
- Truecolor half-block rendering.
- Quadrant rendering.
- Monochrome Braille rendering.
- Ordered dithering with 2x2 and 4x4 matrices.
- Streaming ANSI writer with SGR coalescing.
- Synthetic CLI inputs for gradient, checkerboard, and color bars.
- Test-support PPM/PAM fixture decoding outside the core library.
- CLI `--input` support for PPM/PAM fixtures.
- Synthetic benchmark command.

### Release Notes

- Keep the public API small and documented.
- Keep core decoder-free and terminal-probing-free.
- Add basic package examples.
