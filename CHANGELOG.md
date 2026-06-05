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
- Expanded `zig build bench` into a v0.2 performance-lab harness: it still emits
  CSV for humans, and now accepts `--out bench/results/baseline.json` to write a
  tracked machine-readable baseline with mean/median/p95 timing, estimated frame
  allocation bytes, ANSI bytes, Zig version, OS, and CPU architecture. The matrix
  now includes glyph-tone truecolor, glyph-structure truecolor, prepared
  integral-luma reuse, ANSI encode only, and a small quality-compare proxy row.
- Added an integral-image (summed-area table) luma sampler for monochrome modes,
  selectable via `Options.sample_strategy` (`auto` / `direct_box` /
  `integral_luma`). Fractional bilinear queries make it equal to the direct
  sampler to floating-point rounding (verified by unit, render-level, and quality
  harness A/B tests). `auto` stays on the direct sampler because building the
  table is itself an O(image) pass — it only pays off when reused across renders
  (live resize), which is what the explicit `integral_luma` strategy is for. The
  harness gained `--strategy`.
- Added `PreparedImage`, `prepareImage`, and `renderPreparedToCells` so callers
  can build the integral-luma table once and reuse it across output sizes. The
  benchmark matrix now tracks this reuse path separately from one-shot rendering.
- Moved ANSI emission to `src/ansi.zig` with a hand-rolled SGR encoder (manual
  decimal into a stack buffer, one `writeAll` per color change) instead of
  formatted `print`. Output is byte-identical; the encode step is ~2.5x faster on
  color-churn frames (~69us -> ~27us for a 98 KB frame).
- Added a high-contrast fast path for `glyph_structure`: source cells are packed
  into 128-bit masks and scored with XOR/popcount against pre-shifted glyph masks.
  The benchmarked structural row drops from ~19ms to ~6.5ms per 80x30 frame while
  preserving the slash-line glyph result.

### Added

- Glyph-tone render mode (`RenderMode.glyph_tone`): a calibrated density path that
  selects a glyph by its measured ink coverage rather than indexing a hand-authored
  ramp linearly. Ships a built-in Level-0 atlas (`src/glyph_atlas.zig`, coverage per
  printable ASCII glyph, generated from Monaco by `calibrate_font`). Monochrome and
  truecolor; integral-sampler capable. Exposed as `--mode glyph-tone` in the CLI and
  the harness. In quality-harness A/B it beats the linear density ramp (gradient
  PSNR 13.7 -> 16.0 dB, SSIM 0.70 -> 0.87).
- Glyph-structure render mode (`RenderMode.glyph_structure`): samples each output
  cell at the calibrated 8x16 atlas grid, extracts coverage/centroid/spread/orientation,
  and picks a printable ASCII glyph by packed-mask distance with a small alignment
  tolerance. Low-contrast cells fall back to glyph-tone. Exposed as `--mode
  glyph-structure` in the CLI and harness.
- Harness reconstruction now models tonal glyphs (density / glyph-tone) as a uniform
  linear blend by measured coverage, block/Braille by exact masks, and
  `glyph_structure` by calibrated ASCII glyph masks at the atlas cell resolution.
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
