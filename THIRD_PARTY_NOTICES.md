# Third-Party Notices

This project keeps decoder and font-rasterizer dependencies outside the core
renderer. The core public module remains raw `ImageView` / `Rgba8` only.

## zigimg

- Project: https://github.com/zigimg/zigimg
- License: MIT
- Copyright: Copyright (c) 2019-2021 zigimg developers
- Use in this repo: CLI/tool-layer PNG and JPEG decoding in
  `test_support/image_loader.zig`.
- Boundary: imported by executables and support tools only; no `zigimg` types
  are exported from `src/root.zig`.

## stb_truetype

- Project: https://github.com/nothings/stb
- File: `tools/stb/stb_truetype.h`
- License: public domain / MIT dual-use upstream convention
- Author notice: Sean Barrett / RAD Game Tools
- Use in this repo: glyph atlas calibration tool only.
- Boundary: vendored under `tools/stb/` and linked only into
  `tools/calibrate_font.zig`; not part of the core renderer.

## zstbi

- Project: https://github.com/zig-gamedev/zstbi
- License: MIT
- Use in this repo: evaluated as a fallback candidate for future CLI/tool image
  decoding, but not currently imported or vendored.
