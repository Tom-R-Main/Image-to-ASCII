# Changelog

## Unreleased

### Library

- Broadened the project scope from image-only ASCII conversion toward Cell
  Render: a terminal visual rendering library for images, diagrams, and TUI
  surfaces. Added `CellCanvas` as the shared terminal drawing substrate for
  boxes, orthogonal lines, polylines, arrows, labels, Unicode box drawing, ASCII
  fallback, and N/E/S/W line-join resolution. `CellCanvas` exports to the
  existing `Frame` contract, so the ANSI writer and ANSI diff writer work
  unchanged. Mermaid remains a future frontend over `Diagram IR -> layout ->
  CellCanvas`, not an SVG/PNG/image-renderer path.
- Added the first diagram input frontend: a hand-written Mermaid **flowchart
  subset** lexer and parser (`src/diagram/mermaid/`) compiling to a semantic
  graph IR (`src/diagram/ir/graph.zig`). Supports `flowchart`/`graph` headers,
  directions (TD/TB/LR/RL/BT), node shapes (`[rect]`, `(round)`, `((circle))`,
  `{diamond}`), quoted labels, edge strokes (`-->`, `---`, `-.->`, `==>`),
  circle/cross ends (`--o`, `--x`), edge chains, pipe edge labels (`-->|...|`),
  and `%%` comments. The lexer reproduces Mermaid's `A---oB` circle-edge trap,
  and the parser rejects lowercase `end` as a node id with a precise diagnostic
  rather than emitting a broken graph. Syntax errors return `error.MermaidSyntax`
  with a `MermaidError` carrying kind and 1-based line/column. New public API:
  `parseFlowchart`, `FlowchartResult`, `GraphDiagram`, `Node`, `Edge`,
  `Direction`, `NodeShape`, `LineKind`, `ArrowKind`, `NodeId`, `MermaidError`,
  `MermaidErrorKind`. Layout and rendering of the IR are the next slices.
- Added a **layered (Sugiyama-style) graph layout** (`src/diagram/layout/`) and a
  **flowchart renderer** (`src/diagram/render/`) that turn the graph IR into
  terminal cells via `CellCanvas` → `Frame`. The layout does DFS cycle-breaking,
  longest-path ranking (honoring per-edge `min_len`), dummy-node insertion for
  multi-rank edges, median-heuristic in-rank ordering, neighbor-mean coordinate
  assignment, direction-aware mapping for all four directions, and orthogonal
  (Manhattan) edge routing. Output is overlap-free by construction and
  deterministic (not crossing-minimal). New public API: `renderMermaidFlowchart`,
  `renderGraph`, `GraphRenderOptions`, `GraphRenderError`, `layoutFlowchart`,
  `Layout`, `LayoutOptions`, `LaidOutNode`, `RoutedEdge`. Golden fixtures live in
  `testdata/mermaid/flowchart/` and are checked by `zig build test`. v0
  limitations: all node shapes render as boxes; dotted/thick strokes render with
  the same light glyphs; edge labels sit on the routing line; self-loops render
  as a small stub.

### CLI and Tooling

- Added `docs/TUI_INTEGRATION.md` with the intended live TUI embedding model:
  decoded pixels stay app-owned, `PreparedImage` owns source-derived analysis,
  `RenderWorkspace` owns output/render-shape scratch, `Frame` represents a
  rendered cell state, and `renderFrameDiffToWriter` emits dirty ANSI updates.
  The guide includes Siftable-oriented boundaries, resize rules, and mode
  recommendations for screenshots, previews, monochrome output, and line art.
- Refined the TUI integration guide with the allocation-optimal double-workspace
  diff loop and OpenTUI-specific embedding guidance: OpenTUI should own layout,
  clipping, frame pacing, and stdout, while an app-local bridge copies rendered
  `Frame` cells into an `OptimizedBuffer` instead of routing ANSI through text
  renderables.
- Added a CLI/tool-layer real image adapter using `zigimg` for PNG and JPEG
  input. The adapter converts decoded pixels into owned `[]Rgba8` and exposes
  only `ImageView` to the renderer, so `src/root.zig` and the core API remain
  decoder-free. The CLI still supports PPM/PAM fixtures unchanged, and
  `bench/results/real-image-smoke.json` records small PNG/JPEG smoke fixtures
  with decoded format, sampler policy, PSNR, SSIM, and edge-correlation.
  Third-party attribution is tracked in `THIRD_PARTY_NOTICES.md`.

### Performance

- sRGB->linear conversion is now a compile-time 256-entry lookup table instead of
  a per-pixel `pow`. Because the input domain is a byte, the table is
  bit-identical to the previous formula (verified by test). This is the hot path
  (the sampler revisits it for every source pixel) and is ~7-10x faster across
  modes (e.g. density 2.57ms -> 0.25ms, braille truecolor 5.75ms -> 0.79ms for
  400x240 -> 80x30 in ReleaseFast).
- `areaSample` no longer eagerly encodes sRGB for every subcell sample;
  `Sample.rgb()` is deferred to the point a color is actually emitted, removing
  3 `pow` per subcell on the block/Braille paths (further ~1.3-1.6x there).
- Reworked `zig build bench` into a render-kernel matrix (density / half /
  quadrant / Braille, mono and truecolor, plus an ANSI-writer row) reporting
  ns/cell, cells/sec, and bytes.
- Expanded `zig build bench` into a v0.2 performance-lab harness: it still emits
  CSV for humans, and now accepts `--out bench/results/baseline.json` to write a
  tracked machine-readable baseline with mean/median/p95 timing, estimated frame
  allocation bytes, ANSI bytes, Zig version, OS, and CPU architecture. The matrix
  now includes glyph-tone truecolor, glyph-structure truecolor, prepared
  integral-luma reuse, ANSI encode only, and a small quality-compare proxy row.
- Added an integral-image (summed-area table) luma sampler for monochrome modes,
  selectable via `Options.sample_strategy` (`auto` / `direct_box` /
  `integral_luma`). Fractional bilinear queries make it equal to the direct
  sampler to floating-point rounding (verified by unit, render-level, and quality
  harness A/B tests). `auto` stays on the direct sampler because building the
  table is itself an O(image) pass — it only pays off when reused across renders
  (live resize), which is what the explicit `integral_luma` strategy is for. The
  harness gained `--strategy`.
- Added `PreparedImage`, `prepareImage`, and `renderPreparedToCells` so callers
  can build the integral-luma table once and reuse it across output sizes. The
  benchmark matrix now tracks this reuse path separately from one-shot rendering.
- Added `AxisSpan` / `SamplePlan` source sampling span precomputation. Renderers
  now build shape-specific x/y span arrays for their virtual subcell grids
  (`1x1`, `1x2`, `2x2`, `2x4`, or the calibrated `8x16` glyph grid) and consume
  them via a span-based direct-box sampler. The old direct sampler remains as the
  reference path; unit coverage proves span parity to `0.0001`. ReleaseFast
  comparison against `bench/results/baseline.json` is tracked in
  `bench/results/span-precompute.json`; the largest measured wins in this run are
  density mono (-29.60%), glyph-structure truecolor (-12.10%),
  glyph-structure mono (-10.23%), quadrant mono (-8.76%), and Braille truecolor
  (-7.82%). Half-block truecolor (+4.74%), quadrant truecolor (+6.22%), Braille
  mono (+11.59%), and prepared integral-luma (+30.98%) are current regressions,
  mostly reflecting span-plan allocation overhead and benchmark noise in smaller
  rows.
- Tuned the internal `auto` sampler policy after the first span-precompute run:
  spans are now used for density, glyph-tone, glyph-structure, quadrant mono, and
  Braille truecolor, while half-block, quadrant truecolor, and Braille mono stay
  on the direct-box path. Explicit `integral_luma` and prepared integral-luma
  reuse no longer build span arrays. The benchmark now records each row's
  resolved policy (`direct_box`, `span_precompute`, `integral_luma`, or
  `prepared_integral_luma`) and writes `bench/results/span-tuned.json`. In the
  current run, the forced-span regressions are eliminated by policy (half
  truecolor direct: -0.82% vs baseline; Braille mono direct: -2.08%; quadrant
  truecolor direct: +2.27% benchmark noise), glyph-structure keeps a larger win
  than the first span run (-15.68% truecolor, -16.06% mono), density truecolor
  keeps a strong win (-22.07%), and prepared integral-luma drops its span-plan
  allocation and improves vs the forced-span artifact (-17.56%) while remaining
  slightly above the older baseline in this run.
- Added `RenderWorkspace`, `renderIntoWorkspace`, and
  `renderPreparedIntoWorkspace` for repeated-render reuse. The ergonomic
  `renderToCells` and `renderPreparedToCells` wrappers now move a frame out of an
  internal workspace, preserving public API behavior while exposing a no-realloc
  path for TUIs. `RenderWorkspace` owns only output/render-shape memory (`Frame`
  buffers and `SamplePlan` spans); source-derived precompute remains owned by
  `PreparedImage`. The repeated-render benchmark writes
  `bench/results/workspace-reuse.json` and records first-render vs steady-state
  allocation counts/bytes. Current workspace rows reach zero steady-state
  allocations for same-shape renders, including prepared integral-luma reuse
  without span construction.
- Added `AnsiDiffOptions`, `AnsiDiffStats`, and `renderFrameDiffToWriter` for
  frame-to-frame dirty ANSI output. The diff compares `Frame` cell arrays
  directly, rewrites cells on glyph or fg/bg changes, preserves background
  spaces, coalesces row-contiguous dirty runs, and errors on shape/color mismatch
  unless explicitly configured to full-render. `bench/results/ansi-diff.json`
  adds diff-only and render-plus-diff repeat rows; current ReleaseFast output is
  0 bytes for noop, 44 bytes for a single-cell change, 52 bytes for an 8-cell
  run, 123 bytes for one changed row, and zero steady-state allocations for the
  render-plus-diff repeat rows.
- Added a checked-in quality corpus under `testdata/corpus` and extended
  `zig build compare` with corpus mode:
  `--corpus testdata/corpus --out bench/results/quality-corpus.json`. The corpus
  covers slash glyph-structure, checkerboard Braille, thin-line quadrant,
  density gradient, truecolor half-block color bars, glyph-tone shape edges, and
  a low-contrast glyph-structure edge. The harness keeps the explicit `--input`
  path, adds a default color-bars plus slash-golden smoke, writes finite
  PSNR/SSIM/edge-correlation JSON rows with sampler policy, and exits nonzero on
  slash-golden or threshold failures.
- Optimized the `glyph_structure` span path by sampling its 8x16 luma grid with a
  luma-only direct span sampler and avoiding a redundant atlas lookup for flat
  fallback cells. The quality corpus remains unchanged to the recorded precision
  and `bench/results/glyph-structure-optimized.json` shows current ReleaseFast
  median wins against `bench/results/ansi-diff.json`: glyph-structure mono
  -15.88%, glyph-structure truecolor -9.48%, workspace glyph-structure mono
  repeat -14.45%, and workspace glyph-structure truecolor repeat -8.10%.
- Moved ANSI emission to `src/ansi.zig` with a hand-rolled SGR encoder (manual
  decimal into a stack buffer, one `writeAll` per color change) instead of
  formatted `print`. Output is byte-identical; the encode step is ~2.5x faster on
  color-churn frames (~69us -> ~27us for a 98 KB frame).
- Added a high-contrast fast path for `glyph_structure`: source cells are packed
  into 128-bit masks and scored with XOR/popcount against pre-shifted glyph masks.
  The benchmarked structural row drops from ~19ms to ~6.5ms per 80x30 frame while
  preserving the slash-line glyph result.

### Added

- Glyph-tone render mode (`RenderMode.glyph_tone`): a calibrated density path that
  selects a glyph by its measured ink coverage rather than indexing a hand-authored
  ramp linearly. Ships a built-in Level-0 atlas (`src/glyph_atlas.zig`, coverage per
  printable ASCII glyph, generated from Monaco by `calibrate_font`). Monochrome and
  truecolor; integral-sampler capable. Exposed as `--mode glyph-tone` in the CLI and
  the harness. In quality-harness A/B it beats the linear density ramp (gradient
  PSNR 13.7 -> 16.0 dB, SSIM 0.70 -> 0.87).
- Glyph-structure render mode (`RenderMode.glyph_structure`): samples each output
  cell at the calibrated 8x16 atlas grid, extracts coverage/centroid/spread/orientation,
  and picks a printable ASCII glyph by packed-mask distance with a small alignment
  tolerance. Low-contrast cells fall back to glyph-tone. Exposed as `--mode
  glyph-structure` in the CLI and harness.
- Harness reconstruction now models tonal glyphs (density / glyph-tone) as a uniform
  linear blend by measured coverage, block/Braille by exact masks, and
  `glyph_structure` by calibrated ASCII glyph masks at the atlas cell resolution.
- Configurable representative-color solve for two-color symbol families
  (`Options.color_stat`: `mean`, `trimmed_mean`, `median`) in linear light, per
  RESEARCH.md "Color Strategy". Quadrant and Braille foreground/background
  colors now default to the robust `trimmed_mean` instead of a plain mean.
- Quality-harness scaffold under `tools/`: `zig build compare` renders an image,
  reconstructs it from the emitted cells (block/Braille masks; density halftone
  approximation), and scores PSNR/SSIM/edge-correlation with no font rasterizer.
- `tools/calibrate_font.zig` now rasterizes real glyphs via stb_truetype
  (public domain, vendored under `tools/stb/`, linked only into the tool). It
  computes per-glyph coverage, ink centroid/spread, a quantized dominant edge
  orientation, and a packed 1-bit mask, buckets glyphs by coverage, and can emit
  a self-contained Zig atlas literal (`--out`) for the upcoming glyph modes.

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
