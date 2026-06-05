# Tools

Tooling that would make the core library heavier belongs here. The core package
must not depend on font rasterizers, image decoders, or Python tooling; these
tools may.

## Quality harness (`render_compare`)

Renders a PPM/PAM image through the core library, reconstructs an approximate
image from the resulting cells, and scores it against the source with PSNR,
windowed SSIM, and a Sobel edge-correlation proxy.

```sh
zig build compare -- --input testdata/color-bars.ppm \
    --width 80 --height 40 \
    --mode partition --partition quadrant --color truecolor \
    --fit contain --stat median \
    --write-recon recon.ppm --write-ref ref.ppm
```

Reconstruction is faithful for the block and Braille families because their
glyph masks are known, so the harness needs **no font rasterizer**. Density (and
any unknown codepoint) is reconstructed as a tone halftone from the default ramp
coverage — an approximation a real glyph atlas will replace.

`--stat mean|trimmed|median` selects the representative-color policy, so the
harness can numerically compare color solves (see RESEARCH.md "Color Strategy").

Files:

- `common.zig` — image buffer, colorspace, fit-aware reference resampling, PPM writer.
- `metrics.zig` — MSE/PSNR, windowed SSIM, Sobel edge correlation.
- `reconstruct.zig` — `Frame` → image using known block/Braille masks.
- `render_compare.zig` — CLI orchestrator.

## Font calibration (`calibrate_font`) — scaffold

Defines the `GlyphAtlas` format and the generation pipeline for the glyph render
modes. The rasterization step is stubbed: it requires a permissive font
rasterizer (FreeType or stb_truetype) wired in here as a tools-only dependency.

```sh
zig build calibrate
```

## Planned

- font rasterizer integration + real atlas generation,
- a small line-art / UI / photo / logo quality corpus,
- optional decoder experiments.
