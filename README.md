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

## Current Status

Bootstrap is in place. The package currently exposes public types, validation helpers, aspect-aware sampling
(`contain`/`cover`/`stretch`, with `cover` cropping the source rather than distorting it), density rendering, truecolor
half-block rendering, quadrant rendering, monochrome Braille rendering, ordered dithering, a configurable
representative-color solve for two-color symbol families (`Options.color_stat`: `mean`/`trimmed_mean`/`median`), ANSI
writer output, a synthetic-image CLI, PPM/PAM fixture input, and a small synthetic benchmark command.

A quality harness scaffold lives under `tools/` (`zig build compare`): it renders an image, reconstructs it from the
emitted cells using the known block/Braille masks, and scores it with PSNR/SSIM/edge-correlation — no font rasterizer
required. `tools/calibrate_font.zig` defines the glyph-atlas format for the upcoming glyph modes and stubs the
rasterization step.
