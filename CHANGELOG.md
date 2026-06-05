# Changelog

## Unreleased

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

### Planned For v0.1.0

- Keep the public API small and documented.
- Keep core decoder-free and terminal-probing-free.
- Add basic package examples.
