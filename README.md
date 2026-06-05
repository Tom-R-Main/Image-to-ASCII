# Image to ASCII

Zig-first terminal image rendering for libraries and TUIs.

This project is not a conventional "decode an image file and print ASCII" app. The core library accepts caller-owned raw
pixels and returns terminal-native cells or streams ANSI output through a caller-supplied writer. Image decoding,
terminal probing, and stdout handling belong to the CLI or adapter layer — not to core.

```text
raw RGBA -> aspect-correct sampler -> density / block / glyph renderer -> Frame / coalesced ANSI writer
```

The durable product is a small, embeddable renderer for TUI apps, with Siftable as the first integration target.

## Design Commitments

- raw RGBA `ImageView` input — the caller owns the pixels,
- caller-controlled `TerminalProfile` (dimensions, cell aspect, color, symbols, background),
- allocator-owned, structure-of-arrays `Frame` output (`codepoints` / `fg` / `bg`),
- color accumulation in linear light, encoded back to sRGB at emission,
- streaming `renderToWriter` for CLI/log use,
- **no decoder dependency, no terminal probing, and no font rasterizer in core** — those live in the CLI, adapters, or
  `tools/`.

See [RESEARCH.md](RESEARCH.md) for the architecture rationale and [PLAN.md](PLAN.md) for the milestone plan.

## Build

Requires Zig `0.16.0`.

```sh
zig build           # build the CLI
zig build test      # run all tests (library, CLI, bench, tools)
zig build run -- --help
zig build bench     # renderer benchmark matrix (CSV on stdout)
zig build compare   # quality harness: render -> reconstruct -> score
zig build calibrate # generate/inspect a glyph atlas (tools only)
```

## Core API

```zig
const ascii = @import("image_to_ascii");

var frame = try ascii.renderToCells(allocator, image, terminal, options);
defer frame.deinit(allocator);
```

A complete render from caller-owned pixels:

```zig
const ascii = @import("image_to_ascii");

const image: ascii.ImageView = .{
    .width = width,
    .height = height,
    .stride = width * @sizeOf(ascii.Rgba8),
    .pixels = pixels, // []const Rgba8, caller-owned
};

var frame = try ascii.renderToCells(
    allocator,
    image,
    .{ .columns = 80, .rows = 24, .color = .truecolor },
    .{ .mode = .partition, .partition = .half_1x2 },
);
defer frame.deinit(allocator);
// frame.codepoints / frame.fg / frame.bg are parallel SoA arrays.
```

Stream ANSI to any `std.Io.Writer` instead of materializing cells:

```zig
try ascii.renderToWriter(writer, allocator, image, terminal, options);
// or, if you already hold a Frame:
try ascii.renderFrameToWriter(writer, frame);
```

For TUI redraws, diff two frames and emit only changed row-contiguous runs:

```zig
const stats = try ascii.renderFrameDiffToWriter(
    writer,
    &previous_frame,
    &current_frame,
    .{ .origin_row = 1, .origin_col = 1 },
);
_ = stats.bytes_emitted;
```

### Render modes and support matrix

`Options.mode` selects the renderer:

| Mode              | What it does                                                       |
| ----------------- | ----------------------------------------------------------------- |
| `density`         | Maps cell luminance to a character ramp (`Options.ramp`).         |
| `partition`       | Block-cell renderer; `Options.partition` picks the subcell grid.  |
| `braille`         | Monochrome 2×4 Braille dots.                                      |
| `glyph_tone`      | Calibrated density path: selects a glyph by measured ink coverage. |
| `glyph_structure` | Alignment-tolerant glyph shape scorer (baseline; see Status).     |

What is wired today, and what is reserved but not yet implemented:

- **Partitions:** `density_1x1`, `half_1x2`, `quadrant_2x2` are implemented. `sextant_2x3` and `octant_2x4` are declared
  in the enum but return `error.UnsupportedRenderMode`.
- **Color:** `TerminalProfile.color` supports `none` and `truecolor`. `ansi16` / `ansi256` are reserved and currently
  return `error.UnsupportedColorMode`.
- **Dither:** `none`, `ordered_2x2`, `ordered_4x4`. `floyd_steinberg` is reserved and not yet implemented.

### Reuse APIs

For animation or live resize, the library separates **source-derived precompute** from **output scratch** so repeated
renders avoid re-allocating:

- `PreparedImage` (`prepareImage`) owns source-derived precompute such as the integral-luma summed-area table. Render
  from it with `renderPreparedToCells` / `renderPreparedIntoWorkspace`.
- `RenderWorkspace` owns output and render-shape scratch (`Frame` buffers and `SamplePlan` spans). Render into it with
  `renderIntoWorkspace` / `renderPreparedIntoWorkspace`; same-shape re-renders reuse the buffers with zero steady-state
  allocations.

Reuse luma precomputation across a resize loop (monochrome, integral sampling):

```zig
var prepared = try ascii.prepareImage(
    allocator,
    image_view,
    .{ .columns = 80, .rows = 24, .color = .none },
    .{ .sample_strategy = .integral_luma },
);
defer prepared.deinit(allocator);

var frame = try ascii.renderPreparedToCells(
    allocator,
    &prepared,
    .{ .columns = 100, .rows = 30, .color = .none },
    .{ .mode = .density, .sample_strategy = .integral_luma },
);
defer frame.deinit(allocator);
```

Reuse output and render-shape scratch for repeated same-shape renders:

```zig
var workspace: ascii.RenderWorkspace = .empty;
defer workspace.deinit(allocator);

for (frames) |image| {
    try ascii.renderIntoWorkspace(&workspace, allocator, image, terminal, options);
    try ascii.renderFrameToWriter(writer, workspace.frame);
}
```

### Sampling strategy

`Options.sample_strategy` selects how cells are sampled:

- `auto` (default) — exact direct-box sampling, with span precomputation chosen per mode where it measures faster.
- `direct_box` — the reference path; always exact.
- `integral_luma` — summed-area-table sampling for monochrome modes, intended for reuse across renders (live resize).
  Equal to the direct sampler to floating-point rounding.

`auto` uses span precomputation (`AxisSpan` / `SamplePlan`) for density, glyph-tone, glyph-structure, quadrant mono, and
Braille truecolor, and keeps direct-box for half-block, quadrant truecolor, and Braille mono. Explicit `integral_luma`
and prepared-integral reuse do not build span arrays. `resolveSamplerPolicy` reports the concrete `SamplerPolicy` the
renderer will use for a given `Options` / `TerminalProfile`. Span sampling is validated against the direct sampler with a
`0.0001` linear-RGB/luma epsilon.

## Current Status

The package is a working library plus a thin CLI. Implemented:

- public types, ownership model, and input validation,
- aspect-aware sampling (`contain` / `cover` / `stretch`; `cover` crops the source rather than distorting it),
- density rendering with a configurable character ramp and ordered dithering (`ordered_2x2` / `ordered_4x4`),
- truecolor half-block and quadrant rendering, monochrome Braille rendering,
- calibrated glyph-tone rendering and a baseline glyph-structure renderer,
- a configurable representative-color solve for two-color symbol families (`Options.color_stat`:
  `mean` / `trimmed_mean` / `median`), computed in linear light,
- selectable sampling strategy plus tuned span precomputation, reusable `PreparedImage` precompute, and reusable
  `RenderWorkspace` frame/scratch memory (zero steady-state allocations after the first same-shape render),
- a fast hand-rolled ANSI writer with SGR run coalescing and frame-to-frame diff output for dirty TUI redraws,
- a synthetic-image CLI and PPM/PAM fixture input (test-support, outside core),
- a benchmark matrix with CSV output and tracked JSON baseline artifacts.

### Performance

The hot path uses a compile-time, bit-identical sRGB→linear lookup table instead of a per-pixel `pow`; sRGB encoding of
subcell samples is deferred until a color is actually emitted. Together with span precomputation and the reuse APIs,
rendering is roughly **8× faster than the initial baseline**. `bench/results/baseline.json` is tracked as the local
reference; see [bench/README.md](bench/README.md) for the matrix, the tuned `auto` sampler policy, and `jq` recipes that
diff a new run against the baseline:

```sh
zig build -Doptimize=ReleaseFast bench -- --out bench/results/baseline.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/span-tuned.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/workspace-reuse.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/ansi-diff.json
```

### Quality harness

A measurement harness lives under `tools/` (`zig build compare`): it renders an image, reconstructs an approximate image
from the emitted cells (tonal glyphs as a linear coverage blend; block/Braille by their exact masks; `glyph_structure` by
calibrated ASCII masks), and scores it with PSNR / SSIM / edge-correlation — **no font rasterizer required**.
`tools/calibrate_font.zig` rasterizes a real font via stb_truetype (public domain, vendored under `tools/stb/`, linked
only into the tool) to generate the glyph atlas (per-glyph coverage + structural features) used by the glyph render
modes. In harness A/B, glyph-tone beats the linear density ramp (gradient PSNR 13.7 → 16.0 dB, SSIM 0.70 → 0.87).

## CLI

```sh
# Synthetic density preview (no input file needed):
zig build run -- --synthetic gradient --width 40 --height 12 --mode density --color none

# Render a checked-in PPM fixture with quadrant symbols:
zig build run -- --input testdata/diagonal.ppm --width 40 --height 20 --mode partition --partition quadrant --color truecolor
```

Flags: `--input` (PPM/PAM), `--synthetic gradient|checkerboard|color-bars`, `--width`, `--height`,
`--mode density|partition|braille|glyph-tone|glyph-structure`, `--partition density|half|quadrant`,
`--color none|truecolor`, `--fit contain|cover|stretch`, `--dither none|ordered-2x2|ordered-4x4`, `--invert`. If
`--input` is omitted, a synthetic gradient is rendered.
</content>
