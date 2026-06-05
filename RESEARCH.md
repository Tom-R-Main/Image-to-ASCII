# High-Fidelity Image To ASCII Research

Date: 2026-06-05

## Verdict

Build this as a Zig-first terminal image rendering library, not as another "upload image and print ASCII" app.

The differentiator is:

1. Raw-pixel input so embedders do not inherit decoder dependencies.
2. TUI-native cell output so Siftable can render through its own cell buffer.
3. A shared partition/color pipeline that covers density, half-blocks, quadrants, sextants, octants, and glyphs.
4. Font-calibrated glyph scoring as the long-term quality moat.
5. A CLI that is only one consumer of the core.

The first shippable target should be:

```text
raw RGBA -> aspect-correct area sampler -> {density, half-block} -> Frame / ANSI writer
```

Glyph mode is strategically important, but it should wait until there is a metric harness that can measure text rendered
back through the target font. Otherwise the scorer will become weight tuning by feel.

## Core Design Rules

The core library must:

- accept caller-owned raw pixels,
- avoid file decoding,
- avoid terminal probing,
- avoid stdout/stderr writes,
- avoid per-cell heap allocation,
- expose allocator-owned cell output,
- expose streaming ANSI output through a caller-supplied writer,
- keep deterministic modes for tests.

The CLI may decode images, inspect the terminal, choose defaults from environment, and write to stdout. Those behaviors
do not belong in the reusable library.

## The Conceptual Model

Rendering modes are not separate algorithms. They are points on two axes.

### Axis 1: Partition Resolution

This is how finely one terminal cell can be subdivided:

| Family | Subcells | Notes |
| --- | ---: | --- |
| Density | 1x1 | One region; choose by tone. |
| Half-block | 1x2 | Top and bottom regions. |
| Quadrant | 2x2 | Basic block quadrant combinations. |
| Sextant | 2x3 | Symbols for Legacy Computing; support is terminal/font-sensitive. |
| Octant/Braille | 2x4 | Braille is widely available; octants are newer and less portable. |
| Glyph | arbitrary | Font mask defines the partition shape. |

### Axis 2: Shape Freedom

This is which foreground/background masks a symbol family can draw.

- Density has one region and no real shape freedom.
- Half-block has a 1x2 grid but effectively one split shape.
- Quadrants, sextants, octants, and Braille can draw table-driven binary masks.
- Glyphs can draw whatever masks the calibrated font provides.

This means the shared internal primitive is:

```text
source pixels under a cell
  -> sample into a partition grid
  -> choose an allowed foreground/background mask
  -> solve representative fg/bg colors
  -> emit one codepoint plus optional colors
```

The renderer should therefore be organized around `PartitionModel` and shared sampling/color/scoring code, not a pile of
independent mode-specific implementations.

## Public API Shape

The API should be explicit, allocator-owned, and writer-first for ANSI output.

```zig
pub const RenderMode = enum {
    density,
    partition,
    braille,
    glyph_tone,
    glyph_structure,
};

pub const PartitionKind = enum {
    density_1x1,
    half_1x2,
    quadrant_2x2,
    sextant_2x3,
    octant_2x4,
};

pub const Quality = enum {
    preview,
    balanced,
    high,
};

pub const ColorMode = enum {
    none,
    ansi16,
    ansi256,
    truecolor,
};

pub const TerminalSymbols = enum {
    ascii_only,
    block_basic,
    block_legacy,
    braille,
    glyphs,
};

pub const FitMode = enum {
    contain,
    cover,
    stretch,
};

pub const DitherMode = enum {
    none,
    ordered_2x2,
    ordered_4x4,
    floyd_steinberg,
};

pub const Rgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Rgb8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const ImageView = struct {
    width: u32,
    height: u32,
    stride: usize,
    pixels: []const Rgba8,
};

pub const TerminalProfile = struct {
    columns: u32,
    rows: u32,
    cell_aspect: f32 = 0.5, // terminal cell width / height
    color: ColorMode = .truecolor,
    symbols: TerminalSymbols = .block_basic,
    background: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
};

pub const Options = struct {
    mode: RenderMode = .partition,
    partition: PartitionKind = .half_1x2,
    quality: Quality = .balanced,
    fit: FitMode = .contain,
    dither: DitherMode = .none,
    invert: bool = false,
    contrast: f32 = 1.0,
    brightness: f32 = 0.0,
    ramp: []const u21 = default_density_ramp,
};

pub const Frame = struct {
    columns: u32,
    rows: u32,
    color: ColorMode,
    codepoints: []u21,
    fg: []Rgb8,
    bg: []Rgb8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.codepoints);
        allocator.free(self.fg);
        allocator.free(self.bg);
        self.* = undefined;
    }
};

pub fn renderToCells(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !Frame;

pub fn renderToWriter(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !void;
```

`renderToCells` is the TUI primitive. `renderToWriter` is the CLI/logging primitive. Do not make the primary writer API
return an owned ANSI byte slice; Zig 0.15/0.16 moved toward `std.Io.Reader`/`std.Io.Writer` interfaces with explicit
flush behavior, and streaming output composes better with large frames and animation.

Tests can still wrap `renderToWriter` with a fixed-buffer or allocating writer helper.

## Frame Layout

Use a structure-of-arrays frame, not a fat per-cell struct with optional colors.

```zig
pub const Frame = struct {
    columns: u32,
    rows: u32,
    color: ColorMode,
    codepoints: []u21,
    fg: []Rgb8, // empty when color == .none
    bg: []Rgb8, // empty when color == .none
};
```

Color-ness is a frame property. If the frame is truecolor, every cell has colors. If the frame is monochrome, no cell
does. This avoids optionals, padding, and branchy encode loops. Alpha is not stored in cells; source alpha is composited
against `TerminalProfile.background` during sampling because terminals cannot display per-cell alpha.

The SoA layout also supports later frame diffing for animation or live resize: Siftable can compare a new `Frame`
against the previous one and emit only changed cells through its own renderer.

## Aspect Ratio And Sampling

Let:

```text
a = terminal cell width / terminal cell height
```

Typical terminals are roughly `a = 0.5`. A box of `C x R` cells has physical aspect:

```text
(C / R) * a
```

To preserve a source image aspect `W / H` with contain-fit, choose the largest `C' x R' <= C x R` such that:

```text
C' / R' = (W / H) / a
```

With `a = 0.5`, this is why terminal image renderers usually need about twice as many columns as rows.

Subcell sampling is separate from output-cell fitting. A partition model with `sx x sy` subcells samples into a virtual
grid:

```text
(columns * sx) x (rows * sy)
```

For undistorted subcells, the physical subpixel should be square:

```text
a * (sy / sx) = 1
```

At `a = 0.5`:

| Family | Subcells | Square subcells? |
| --- | ---: | --- |
| Half-block | 1x2 | yes |
| Braille/octant | 2x4 | yes |
| Quadrant | 2x2 | no |
| Sextant | 2x3 | closer, but no |

Half-block is therefore the right first color mode because it turns a normal terminal into a square-pixel framebuffer at
`columns x (rows * 2)`. Quadrants and sextants need sampler compensation or they will stretch shapes vertically. Put
this compensation in `sample.zig` keyed by `PartitionModel`; do not make it a mode-specific footgun.

## Partition Models

Represent block, Braille, and legacy-computing families with one table-driven model:

```zig
pub const PartitionModel = struct {
    sx: u8,
    sy: u8,
    masks: []const MaskGlyph,
    min_symbols: TerminalSymbols,
};

pub const MaskGlyph = struct {
    codepoint: u21,
    mask: u16,
};
```

Examples:

- `density_1x1`: one region, density ramp handles codepoint selection.
- `half_1x2`: upper-half/lower-half/full/space variants.
- `quadrant_2x2`: 16 mask entries.
- `sextant_2x3`: 64 mask entries, gated by `block_legacy`.
- `octant_2x4`: 256 mask entries, gated by modern symbol support.
- `braille_2x4`: 256 mask entries, but treated as a monochrome/1-bit path.

`msoap/tcg` is useful here as a reference, not as a converter competitor: it treats terminal graphics as a virtual
subcell framebuffer plus glyph lookup tables. That model should inform `symbol.zig`/`subcell.zig`.

## Color Strategy

Do color math in linear light:

```text
sample sRGB -> linearize -> average/cluster in linear -> encode sRGB for terminal output
```

Ramp indexing should still use perceptual lightness, or at least gamma-corrected luminance, because linear luminance
steps look uneven as glyph density choices.

Representative colors:

- Use median for line art and hard-edged content.
- Use trimmed mean as the cheaper default for photographic content.
- Avoid plain mean as the only policy because it bleeds edge colors into fills.

For two-color symbol families, write one shared solve:

```text
sampled subcells
  -> choose allowed mask
  -> foreground set and background set
  -> representative fg color and bg color
```

The color solve is shared by half-block, quadrant, sextant, octant, and glyph modes. Density is the degenerate case.
Braille is the exception: it is a 1-bit dot path with a single foreground color and one background, not a full-color
partition solver.

Only quantize to ANSI 256 or ANSI 16 when requested through `TerminalProfile.color`. The core should not inspect
`$TERM`.

## Dithering

Dither on the virtual resolution implied by the selected symbol family:

| Family | Dither grid |
| --- | --- |
| Density | 1 sample per cell |
| Half-block | 1x2 samples per cell |
| Quadrant | 2x2 samples per cell |
| Sextant | 2x3 samples per cell |
| Braille/octant | 2x4 samples per cell |
| Glyph | source mask/candidate field, not only final brightness |

Ordering matters:

- Ordered dithering is stateless, parallel, deterministic, and preview-friendly. Apply it to subpixel luminance before
  the partition decision.
- Floyd-Steinberg error diffusion is serial and crosses cell boundaries. It belongs only in `quality = high` still-image
  paths, as a separate pass over the virtual subpixel grid before cells are formed. Do not diffuse over final `Frame`
  cells.

Gate Floyd-Steinberg out of deterministic test mode.

## Glyph Mode

Split glyph mode into two traditions instead of one blended scorer.

### Glyph Tone

`glyph_tone` is the fast calibrated-density path:

- precompute glyph coverage for the target font,
- bucket by coverage,
- choose a glyph primarily by perceptual tone,
- solve colors under the glyph mask if color is enabled.

This is the better version of a density ramp.

### Glyph Structure

`glyph_structure` is the differentiator:

- precompute glyph masks and structural features from the target font,
- extract edge/contour features from the source cell,
- prefilter to a small candidate set by coverage and dominant orientation,
- score only survivors with an alignment-tolerant shape metric.

Do not use one fixed-position weighted sum of coverage error, mask SAD/SSE, edge error, color error, and continuity as
the final scorer. That conflates tone matching with structure matching and will produce blurry halftone. The compact
features are for pruning; the mask is for final scoring.

The structure scorer should start with a cheap alignment-tolerant proxy:

```text
min distance over small offsets, e.g. dx/dy in {-1, 0, 1}
```

Later it can move toward an AISS-style directional shape similarity inspired by Xu, Zhang, and Wong, "Structure-based
ASCII Art" (SIGGRAPH 2010). Build the metric harness before spending serious time here.

## Font Calibration

Do not hardcode one "perfect" character ramp.

Calibration levels:

```text
Level 0: built-in generic monospace glyph table
Level 1: bundled profiles for common terminal fonts
Level 2: user-generated profile from a font file
```

Atlas shape:

```zig
pub const GlyphAtlas = struct {
    cell_width: u8,
    cell_height: u8,
    glyphs: []const GlyphFeature,
    buckets: []const GlyphBucket,
};

pub const GlyphFeature = struct {
    codepoint: u21,
    coverage: f32,
    dominant_orientation: u8,
    centroid_x: f32,
    centroid_y: f32,
    spread_x: f32,
    spread_y: f32,
    mask_offset: u32,
    mask_len: u16,
};
```

Validate during atlas generation:

- every codepoint is width-1,
- no combining characters,
- no ambiguous-width or double-width glyphs unless the profile explicitly marks and excludes them,
- cell dimensions match the terminal profile used for scoring.

FreeType, stb_truetype, or any heavier rasterization dependency belongs in `tools/`, not the dependency-free core.

## ANSI Emission

SGR run coalescing is mandatory.

Naive truecolor output emits a foreground/background escape per cell and can spend more bytes on escape sequences than
on text. `renderToWriter` should track current SGR state and only emit color changes when fg or bg changes. Reset once
per row or track state across rows, then flush the writer at the CLI boundary.

Future animation output can take an optional previous frame:

```zig
pub fn renderDiffToWriter(
    writer: *std.Io.Writer,
    previous: *const Frame,
    current: *const Frame,
) !void;
```

Siftable does not need this if its own TUI renderer owns diffing.

## Zig Implementation Notes

Pin the Zig version in `build.zig.zon` and verify exact `std.Io` names against the pinned stdlib. The local machine has
Zig 0.16.0 available in the pasted reference material.

Use comptime specialization for the hot path:

```zig
fn renderImpl(
    comptime color: ColorMode,
    comptime partition: PartitionKind,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !Frame {
    // No per-pixel branch on color or partition.
}

pub fn renderToCells(...) !Frame {
    return switch (options.partition) {
        inline else => |partition| switch (terminal.color) {
            inline else => |color| renderImpl(color, partition, allocator, image, terminal, options),
        },
    };
}
```

Function pointers are a fallback only if the specialization matrix becomes too large.

## Module Breakdown

Use modules by shared responsibility, not by one file per apparent mode.

```text
src/root.zig
  public exports

src/core.zig
  public API structs, errors, validation

src/pixel.zig
  Rgba8, Rgb8, linear color structs, alpha compositing

src/luma.zig
  sRGB -> linear, perceptual luma/lightness, contrast, brightness

src/sample.zig
  fit calculations, source region mapping, square-subpixel compensation, area sampler, summed-area tables

src/symbol.zig
  PartitionModel, mask tables, symbol capability gates

src/color.zig
  2-means color solve, median, trimmed mean, ANSI 16/256 quantization

src/render.zig
  comptime-specialized render loops

src/ramp.zig
  density ramps and custom ramp validation

src/glyph.zig
  GlyphAtlas, feature buckets, glyph-tone and glyph-structure matching

src/dither.zig
  ordered dithering and high-quality virtual-grid error diffusion

src/ansi.zig
  UTF-8 codepoint emission, SGR state coalescing, reset handling

src/cli.zig
  command parser, decoder adapters, terminal probing, stdout/stderr
```

`ppm.zig` does not belong in core. PPM/PAM reading is decoding. Put it under `testdata` support, `tools/`, or the CLI
adapter layer.

## Referenced Projects And Lessons

### Chafa

Chafa is the benchmark/reference for quality: symbol ranges, color modes, color spaces, dithering, preprocessing, work
factor, and library-plus-CLI shape. Treat it as a benchmark and API reference, not a dependency or code source. Its
LGPL/GPL-family licensing is inconvenient for a permissively licensed static Zig dependency.

Key lessons to keep:

- median color can preserve line art better than average,
- dithering grain should align with symbol geometry,
- work factor is a useful public API,
- font/glyph import matters for high fidelity.

### AAlib / libcaca

These older libraries reinforce the same design pattern:

- expose fast and high-quality paths,
- precompute lookup tables,
- keep charset and color choices explicit.

### TheZoraiz/ascii-image-converter

Useful CLI reference:

- width/height controls,
- full-terminal mode,
- color/grayscale/negative/flip,
- custom character map,
- save output,
- Braille,
- thresholding and dithering.

Avoid carrying over density-only design as the core quality ceiling.

### vietnh1009/ASCII-generator

Useful as the simplest brightness-sorted font prototype. Its image-to-image path demonstrates measured glyph brightness,
but Python/OpenCV/PIL are not appropriate for the Siftable hot path.

### msoap/tcg

Useful as a subcell framebuffer reference:

- `PixelMode` is width, height, and complete glyph mapping,
- 1x1, 1x2, 2x2, 2x3, and 2x4 modes map cleanly to `PartitionModel`,
- 2x3 and newer symbols expose real font/terminal compatibility risk.

It is a drawing library, not a converter competitor.

### user-simon/asciify

Take the lesson that font-specific tuning matters. Do not vendor or copy GPL-3.0 code.

### hatkidchan/asciify

The dependency-light C/stb approach is useful for the CLI decoder path. Keep that optional and outside core.

### spiraldb/ziggy-pydust

Useful later for Python notebooks, PyPI experiments, or bindings. Do not make Python part of the core.

## Testing And Benchmarks

Unit tests:

```text
luminance conversion
linear <-> sRGB round trips
alpha compositing against terminal background
fit/aspect calculations
square-subpixel compensation
ramp index boundaries
ASCII printable validation
partition mask lookup
Braille dot mask mapping
half-block top/bottom color mapping
2-means color solve on tiny fixtures
ordered dithering determinism
ANSI SGR coalescing and reset handling
allocator ownership/deinit
```

Golden tests:

```text
tiny 4x4 image -> density output
tiny 2x4 image -> half-block output
tiny 4x4 image -> quadrant output
tiny 4x8 image -> Braille output
gradient -> stable text
checkerboard -> stable block/Braille
```

Quality harness:

```text
render source image to text
render text back to image with target font
compare against resized source
track SSIM/PSNR as coarse metrics
track edge-preservation score for line art and UI screenshots
```

This harness needs a glyph rasterizer dependency and should live under `tools/`. Do not pull FreeType or stb_truetype
into core to satisfy quality tests.

Benchmarks:

```text
400x240 -> 80x30 preview density
400x240 -> 80x30 truecolor half-block
1024x768 -> 100x40 density
1024x768 -> 100x40 glyph-tone balanced
1024x768 -> 100x40 glyph-structure high
ANSI encoding only
color quantization only
glyph pruning only
glyph final scoring only
```

Measure decode separately from core render time.

Summed-area tables should be justified by reuse across scales, especially live TUI resizing. For a one-shot render at
one scale, a fused area sampler may be faster and smaller. Use `u32` accumulators for large `u8` sums and `u64` if a
squared table is ever added for variance.

## CLI Design

The CLI should wrap the core:

```text
ascii-render image.png
  --mode density|partition|braille|glyph-tone|glyph-structure
  --partition density|half|quadrant|sextant|octant
  --width 80
  --height 30
  --fit contain|cover|stretch
  --color none|16|256|truecolor
  --symbols ascii|block-basic|block-legacy|braille|glyphs
  --quality preview|balanced|high
  --dither none|ordered-2x2|ordered-4x4|fs
  --ramp " .:-=+*#%@"
  --invert
  --profile xterm-truecolor
  --out output.txt
```

First release CLI support:

```text
raw RGBA fixtures
synthetic gradients for benchmarks
PPM/PAM only as CLI/test-support decoding
optional zigimg or zignal adapter later
```

## Siftable Integration Contract

Siftable should call `renderToCells` and render the returned frame through its own TUI renderer:

```zig
var frame = try ascii.renderToCells(
    allocator,
    image_view,
    .{
        .columns = tui_width,
        .rows = tui_height,
        .cell_aspect = terminal_cell_aspect,
        .color = .truecolor,
        .symbols = .block_basic,
    },
    .{
        .mode = .partition,
        .partition = .half_1x2,
        .quality = .preview,
    },
);
defer frame.deinit(allocator);
```

For standalone output, the CLI should call `renderToWriter` with a buffered stdout writer and explicitly flush.

Required integration properties:

- no global terminal probing inside core,
- no stdout writes from core,
- caller controls allocator,
- caller controls terminal profile,
- cancellation/deadline hook before long-running glyph work,
- deterministic mode for tests.

## Milestone Plan

### Phase 0: Documentation And Harness Shape

Deliver:

```text
revised architecture document
benchmark fixture plan
quality metric plan
Zig version decision
```

### Phase 1: Core Skeleton And Density/Half-Block

Build:

```text
build.zig
build.zig.zon
src/root.zig
src/core.zig
src/pixel.zig
src/luma.zig
src/sample.zig
src/symbol.zig
src/color.zig
src/render.zig
src/ramp.zig
src/ansi.zig
src/cli.zig
```

Deliver:

```text
raw RGBA ImageView
SoA Frame
renderToCells
renderToWriter
fit/aspect handling
density partition
truecolor half-block
SGR coalescing
unit tests
synthetic gradient benchmark
```

### Phase 2: Binary Subcell Families

Build:

```text
quadrant 2x2 table
sextant 2x3 table
Braille 2x4 table
ordered dithering
symbol capability fallback
```

Deliver:

```text
deterministic golden tests
monochrome Braille thumbnails
legacy symbol fallback behavior
```

### Phase 3: Glyph-Tone

Build:

```text
GlyphAtlas format
built-in generic glyph table
coverage buckets
glyph-tone scorer
```

Deliver:

```text
calibrated density-like glyph mode
ASCII-only profile
quality benchmark hook
```

### Phase 4: Quality Harness And Calibration Tools

Build:

```text
tools/calibrate_font.zig
tools/render_compare.zig
font rasterizer adapter
SSIM/PSNR/edge metric runner
```

Deliver:

```text
font-specific glyph atlas
visual comparison output
baseline comparisons against Chafa and simple converters
```

### Phase 5: Glyph-Structure

Build:

```text
structure feature extraction
candidate prefilter by coverage/orientation
alignment-tolerant final scorer
optional continuity refinement
```

Deliver:

```text
high-quality structure mode
measured improvement on edge-preservation corpus
```

### Phase 6: Decoder Adapters And Packaging

Build:

```text
adapters/zigimg.zig or adapters/zignal.zig
optional Python/Pydust experiment
optional C ABI only if downstream users need it
```

Deliver:

```text
PNG/JPEG/GIF still-image CLI support
comparative CLI benchmarks
library package docs
```

## Licensing

Use MIT, Apache-2.0, or 0BSD.

Recommendation:

- Apache-2.0 if explicit patent language matters.
- MIT or 0BSD if maximum simplicity is preferred.

Do not vendor GPL-3.0 projects. Treat Chafa as a reference/benchmark rather than a linked dependency. Keep decoder
dependencies optional and outside core so the embeddable library remains permissive and small.

## Immediate Next Step

Implement Phase 1 as the smallest useful Zig package:

```text
raw RGBA -> aspect-correct area sampling -> density/half-block -> Frame / coalesced ANSI writer
```

This proves the API, memory model, aspect math, linear-light color path, partition tables, and ANSI writer on the mode
that gives immediate Siftable value. Density is the trivial one-region partition. Quadrants, sextants, octants, and
Braille then become table additions rather than new renderer architectures.
