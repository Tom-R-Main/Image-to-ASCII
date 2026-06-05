# Image to ASCII

Zig-first terminal image rendering for libraries and TUIs.

This project is not a conventional "decode an image file and print ASCII" app. The core library accepts caller-owned raw
pixels and returns terminal-native cells or streams ANSI output through a caller-supplied writer. Image decoding,
terminal probing, and stdout handling belong to the CLI or adapter layer.

## First Target

```text
raw RGBA -> aspect-correct sampler -> density/half-block renderer -> Frame / coalesced ANSI writer
```

The first useful release is a dependency-light Zig package that can be embedded by TUI apps such as Siftable.

## Core API Direction

```zig
const ascii = @import("image_to_ascii");

var frame = try ascii.renderToCells(allocator, image, terminal, options);
defer frame.deinit(allocator);
```

The core API is designed around:

- raw RGBA `ImageView` input,
- caller-controlled `TerminalProfile`,
- allocator-owned `Frame` output,
- structure-of-arrays cell storage,
- streaming `renderToWriter` output for CLI/log use,
- no decoder dependency in core.

See [RESEARCH.md](RESEARCH.md) for the architecture rationale and [PLAN.md](PLAN.md) for the implementation plan.

## Build

Requires Zig `0.16.0`.

```sh
zig build test
zig build
zig build bench
zig build -Doptimize=ReleaseFast bench -- --out bench/results/baseline.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/span-precompute.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/span-tuned.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/workspace-reuse.json
```

## Examples

Render a synthetic density preview:

```sh
zig build run -- --synthetic gradient --width 40 --height 12 --mode density --color none
```

Render a checked-in PPM fixture with quadrant symbols:

```sh
zig build run -- --input testdata/diagonal.ppm --width 1 --height 1 --mode partition --partition quadrant --color none
```

Use the library from Zig:

```zig
const ascii = @import("image_to_ascii");

var frame = try ascii.renderToCells(
    allocator,
    image_view,
    .{ .columns = 80, .rows = 24, .color = .truecolor },
    .{ .mode = .partition, .partition = .half_1x2 },
);
defer frame.deinit(allocator);
```

Reuse luma precomputation for resize or animation loops that opt into integral sampling:

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

try ascii.renderIntoWorkspace(
    &workspace,
    allocator,
    image_view,
    .{ .columns = 80, .rows = 24, .color = .truecolor },
    .{ .mode = .glyph_structure },
);

const frame = workspace.frame;
_ = frame;
```

`PreparedImage` owns source-derived precompute such as integral-luma tables. `RenderWorkspace` owns reusable output and
render-shape scratch such as `Frame` buffers and `SamplePlan` spans.

## Current Status

Bootstrap is in place. The package currently exposes public types, validation helpers, aspect-aware sampling
(`contain`/`cover`/`stretch`, with `cover` cropping the source rather than distorting it), density rendering, truecolor
half-block rendering, quadrant rendering, monochrome Braille rendering, calibrated glyph-tone rendering, baseline
glyph-structure rendering, ordered
dithering, a configurable representative-color solve for two-color symbol families (`Options.color_stat`:
`mean`/`trimmed_mean`/`median`), a selectable sampling strategy (`Options.sample_strategy`: `auto`/`direct_box`/
`integral_luma`), tuned source sampling span precomputation (`AxisSpan`/`SamplePlan`) for render-shape-specific direct-box
sampling, reusable `PreparedImage` luma precomputation for TUI resize loops, reusable `RenderWorkspace` frame/scratch
memory for repeated renders, a fast hand-rolled ANSI writer with SGR coalescing, a synthetic-image CLI, PPM/PAM fixture
input, and a render-kernel benchmark with CSV output plus tracked JSON baseline artifacts. `auto` uses spans for density,
glyph-tone, glyph-structure, quadrant mono, and Braille truecolor, but keeps direct-box for half-block, quadrant truecolor,
and Braille mono; explicit `integral_luma` and prepared integral reuse do not build span arrays. Span sampling is covered
against the old direct sampler with a `0.0001` float epsilon. Repeated workspace benchmarks show zero steady-state
allocations after the first same-shape render. The hot path uses a compile-time sRGB→linear lookup table; rendering is
~8× faster than the initial baseline.

A quality harness lives under `tools/` (`zig build compare`): it renders an image, reconstructs it from the emitted
cells (tonal glyphs as a coverage blend, block/Braille by exact masks, `glyph_structure` by calibrated ASCII masks), and
scores it with PSNR/SSIM/edge-correlation — no font rasterizer required. `tools/calibrate_font.zig` rasterizes a real
font via stb_truetype to generate a glyph atlas (coverage + structural features) for the glyph render modes.
