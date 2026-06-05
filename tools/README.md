# Tools

Tooling that would make the core library heavier belongs here. The core package
must not depend on font rasterizers, image decoders, or Python tooling; these
tools may.

## Quality harness (`render_compare`)

Renders a PPM/PAM image through the core library, reconstructs an approximate
image from the resulting cells, and scores it against the source with PSNR,
windowed SSIM, and a Sobel edge-correlation proxy.

```sh
zig build compare

zig build compare -- --input testdata/color-bars.ppm \
    --width 80 --height 40 \
    --mode partition --partition quadrant --color truecolor \
    --fit contain --stat median \
    --write-recon recon.ppm --write-ref ref.ppm
```

The no-arg command uses `testdata/color-bars.ppm` as a smoke fixture.

Reconstruction is faithful for the block and Braille families because their
glyph masks are known, so the harness needs **no font rasterizer**. Density and
glyph-tone are reconstructed as a uniform tone from measured coverage.
`glyph_structure` is reconstructed from the calibrated ASCII masks at the
atlas cell resolution.

`--stat mean|trimmed|median` selects the representative-color policy, so the
harness can numerically compare color solves (see RESEARCH.md "Color Strategy").

Files:

- `common.zig` — image buffer, colorspace, fit-aware reference resampling, PPM writer.
- `metrics.zig` — MSE/PSNR, windowed SSIM, Sobel edge correlation.
- `reconstruct.zig` — `Frame` → image using known block/Braille masks.
- `render_compare.zig` — CLI orchestrator.

## Font calibration (`calibrate_font`)

Generates a per-font `GlyphAtlas` for the glyph render modes. Rasterization is
provided by **stb_truetype** (public domain, vendored under `tools/stb/`), linked
only into this tool — never into the core.

For each codepoint it rasterizes the glyph into a cell-sized coverage bitmap and
computes coverage, ink centroid/spread, a quantized dominant edge orientation,
and a packed 1-bit mask; glyphs are then bucketed by coverage.

```sh
zig build calibrate -- --font /System/Library/Fonts/Monaco.ttf \
    --cell 8x16 --out src/generated_atlas.zig
```

Options: `--font path.ttf`, `--cell WxH`, `--out path.zig` (emits a self-contained
Zig atlas literal that `src/glyph.zig` can `@import` once the glyph render modes
land). `.ttc` collections use face 0.

The vendored `stb/stb_truetype.h` is upstream v1.26, unmodified; `stb_truetype_impl.c`
is the one-line implementation translation unit.

## Planned

- structural scorer refinements for `glyph_structure`,
- a small line-art / UI / photo / logo quality corpus,
- optional decoder experiments.
