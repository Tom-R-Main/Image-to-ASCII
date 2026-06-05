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

## Current Status

Bootstrap is in place. The package currently exposes public types, validation helpers, aspect-aware sampling, density
rendering, truecolor half-block rendering, quadrant rendering, monochrome Braille rendering, ordered dithering, ANSI
writer output, a synthetic-image CLI, and a small synthetic benchmark command.
