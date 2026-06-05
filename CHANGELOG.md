# Changelog

## Unreleased

### Added

- Configurable representative-color solve for two-color symbol families
  (`Options.color_stat`: `mean`, `trimmed_mean`, `median`) in linear light, per
  RESEARCH.md "Color Strategy". Quadrant and Braille foreground/background
  colors now default to the robust `trimmed_mean` instead of a plain mean.
- Quality-harness scaffold under `tools/`: `zig build compare` renders an image,
  reconstructs it from the emitted cells (block/Braille masks; density halftone
  approximation), and scores PSNR/SSIM/edge-correlation with no font rasterizer.
- `tools/calibrate_font.zig` scaffold defining the `GlyphAtlas` format and a
  stubbed rasterization step for the upcoming glyph modes.

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
