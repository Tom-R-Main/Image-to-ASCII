# Changelog

## Unreleased

### Tooling

- Added **`glyphshot`** (`zig build glyphshot`, `tools/glyphshot.zig`): rasterizes
  a render (image or Mermaid diagram) through a real TrueType/OpenType font via the
  vendored `stb_truetype`, compositing each cell's glyph fg-over-bg into a PPM. It
  is the headless equivalent of a terminal screenshot — the actual glyph shapes,
  with no display/window-server/screen-recording permission — so visual checks run
  unattended. Supports a `--fallback-font` chain (octants/sextants live in Unicode
  16's SMP while quadrants/space are BMP, so two font files cover an octant render)
  and reports how many code points the font lacks. Fonts are fetched locally, never
  committed. Also added `scripts/terminal-shot.sh` for a literal Terminal.app
  screenshot (requires the Mac awake/unlocked + Screen Recording permission).
- Added **`scripts/visual-gallery.sh`**: renders every diagram fixture and the
  image corpus (quadrant vs octant) through `glyphshot` and montages them into
  contact sheets under `tools/out/gallery/`, so a quality pass yields viewable
  PNGs. Used to visually confirm the whole diagram suite (containment boxes, C4
  stereotypes, class inheritance, ER cardinality, sequence blocks/notes) renders
  with real glyphs and no `.notdef`.

### Library

- Fixed a **mono sub-cell partition inversion** (quadrant/sextant/octant with
  `--color none` and no dither): the per-cell mean was used as the on/off
  threshold, but in mono there is no second tone to recover, so a flat cell tied
  every sub-pixel `>= avg` and filled solid — inverting flat/photographic
  regions (a dark field rendered as nearly all-white). Mono partitions now
  threshold at a fixed midpoint, matching the braille and half-block paths;
  ordered dithering is unchanged. Caught by a render→reconstruct→image visual
  test (a dark line-art's reconstruction mean was 0.93 vs the source's 0.22) and
  measured: mono partition PSNR jumped ~8× on the corpus (e.g. thin-lines and
  shape-edge now reconstruct exactly). Added a regression test and tightened the
  corpus SSIM/edge gates so a re-inversion fails. The quality harness now also
  accepts perfect (PSNR +inf) reconstructions instead of rejecting them.
- Added **sextant (2×3) and octant (2×4) sub-cell partitions** — the higher-
  resolution block-mosaic modes that pack 6 and 8 sub-pixels per cell (vs 4 for
  quadrant), for sharper image rendering. They reuse the quadrant pipeline
  (threshold each sub-pixel → bitmask → glyph + two representative colors).
  Sextant uses Unicode 13 "Block Sextants" (deterministic mapping); octant uses
  the Unicode 16 block-octant table (generated from UnicodeData 16.0 `BLOCK
  OCTANT-*` names), with the ~10 irregular non-block patterns resolved by a
  provably-safe quadrant collapse — never a wrong code point. New glyph helpers
  `symbol.sextantCodepoint`/`octantCodepoint` and inverses
  `sextantMask`/`octantMask` (exposed for the quality harness, which now scores
  both); CLI `--partition sextant|octant`. Both gate to the Unicode legacy-
  computing terminal tier (octants additionally want a Unicode 16 font). Corpus
  regression cases `checkerboard-sextant` and `shape-edge-octant` confirm the
  fidelity gain (octant ≥ quadrant on every fixture measured).

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
  `testdata/mermaid/flowchart/` and are checked by `zig build test`.
- Distinct node-shape and edge-stroke rendering. Nodes now draw shape-specific
  borders — square `rect`, rounded `round`, rounded+parenthesis `circle`
  (capsule), and diagonal-corner `diamond` — with ASCII fallbacks. `CellCanvas`
  gained a `Stroke` option (`light`/`heavy`/`dotted`) plus heavy and dotted
  box-drawing/ASCII join tables, so `thick` (`==>`) and `dotted` (`-.->`) edges
  render with their own glyphs. Edge labels are now placed beside the routing
  line (occupancy-aware: it tries above/below or left/right of the path midpoint
  and only overlaps the line if the graph is too dense for any clear slot), via a
  new `CellCanvas.isBlank` query. Remaining v0 limitation: self-loops render as a
  small stub.
- Added the **sequence-diagram** track: a line-based `sequenceDiagram` parser
  (`src/diagram/mermaid/sequence.zig`) → sequence IR (`src/diagram/ir/sequence.zig`)
  → lane/time layout (`src/diagram/layout/sequence_layout.zig`) → renderer
  (`src/diagram/render/sequence_renderer.zig`). Supports `participant`/`actor`
  with `as` aliases, implicit participants in first-seen order, all eight message
  arrows (`->`, `-->`, `->>`, `-->>`, `-)`, `--)`, `-x`, `--x`), self-messages, and
  `%%` comments. Participants get header boxes and dotted lifelines; messages
  stack top-to-bottom with labels above arrows and distinct heads (filled `►◄`,
  open async `▷◁`, cross `×`). Added a `renderMermaid` dispatcher that sniffs the
  header (`flowchart`/`graph`/`sequenceDiagram`) and routes to the right backend.
  New public API: `parseSequence`, `renderMermaid`, `renderMermaidSequence`,
  `renderSequence`, `layoutSequence`, `MermaidRenderOptions`,
  `SequenceRenderOptions`, `SequenceDiagram`, `SequenceLayout`,
  `SequenceParticipant`, `SequenceMessage`, `DiagramKind`. Golden fixtures in
  `testdata/mermaid/sequence/`.
- Deepened sequence diagrams with **notes** and **activations**. The IR is now an
  ordered `Event` stream (message/note/activate/deactivate). Notes parse as
  `Note left of A`, `Note right of A`, `Note over A`, and `Note over A,B`, and
  render as boxes overlaying the lifelines. Activations parse as the message
  suffixes `->>+` / `-->>-` and the standalone `activate`/`deactivate` statements
  (nestable); active lifeline spans render as a solid heavy segment (`┃` / `|`)
  against the dotted idle lifeline (`┆` / `:`). New IR/layout types:
  `Note`, `NotePlacement`, `Event`, plus `LaidNote` and lifeline `active`
  intervals.
- Added **block frames** to sequence diagrams: `alt`/`opt`/`loop`/`par` with
  `else`/`and` sections and `end`, including nesting. Each block renders as a
  labeled frame (`alt [is valid]`) around its events, sized to fit both the
  enclosed geometry and the title/section labels; nested frames are enclosed by
  their parents; `else`/`and` render as dotted dividers with their condition. The
  parser validates matched `end`s and rejects stray `end`/`else` and unclosed
  blocks. New IR/layout types: `BlockKind`, `Block`, the `block_start`/
  `block_else`/`block_end` events, `LaidBlock`, and `Divider`. v0 limitations
  remaining: header boxes are top-only, and `critical`/`break`/`rect` blocks are
  not parsed.
- Added a **state-diagram** frontend (`stateDiagram`/`stateDiagram-v2`). Because
  state diagrams are a graph-layout diagram, the parser
  (`src/diagram/mermaid/state.zig`) lowers directly to the existing graph IR and
  reuses the layered layout and graph renderer — no new layout or renderer.
  Supports states (rounded nodes), `[*]` start/end pseudo-states (rendered as
  circles; start and end are kept distinct so `[*] → … → [*]` stays a DAG rather
  than a cycle), transitions `A --> B` with optional `: label`, state
  descriptions (`S : text`), `direction`, and `%% comments`. The `renderMermaid`
  dispatcher now detects `stateDiagram`/`stateDiagram-v2` too. New public API:
  `parseState`, `renderMermaidState`. Golden fixture in `testdata/mermaid/state/`.
  Deferred: composite states, choice/fork/join, and notes.
- Added a **compartment-node renderer** and a **class-diagram** frontend
  (`classDiagram`). The graph IR `Node` gained optional `compartments` (a header
  plus stacked sections) and the renderer draws them as a "card"
  (`+----+ / name / +----+ / attrs / +----+ / methods / +----+`); `cardHeight`
  is shared by layout and renderer so the card exactly fills its rect. The graph
  IR also gained UML endpoint decorations (`ArrowKind.triangle`/`diamond`/
  `diamond_filled`) and `Edge.head_at_source`. The parser
  (`src/diagram/mermaid/class.zig`) lowers classes to compartment cards and
  relationships to edges — inheritance `<|--`/`--|>`, composition `*--`/`--*`,
  aggregation `o--`/`--o`, association `-->`/`<--`/`--`, dependency `..>`/`<..`,
  realization `..|>`/`<|..`, each with an optional `: label` — placing the
  parent/whole on top with its decoration. Reuses the layered layout and graph
  renderer. New public API: `parseClass`, `renderMermaidClass`. Golden fixture in
  `testdata/mermaid/class/`. v0 limitations: when a class has two source-decorated
  relationships they share the exit port (last-drawn decoration wins); generics,
  annotations, namespaces, and multiplicities are not parsed; aggregation
  `o--`/`--o` needs a space around the `o`.
- Added an **entity-relationship (ER) diagram** frontend (`erDiagram`), reusing
  the compartment-node renderer: entities are single-compartment cards (header +
  attribute lines). Relationships carry **cardinality at both ends**, supported by
  a new `Edge.from_end`/`Edge.to_end` (short text drawn beside each endpoint) and
  an end-label placement step in the renderer. Crow's-foot tokens
  (`||` `|o` `o|` `}o` `o{` `}|` `|{`) map to multiplicity text (`1`, `0..1`,
  `1..N`, `0..N`) — a cell grid can't draw crow's feet faithfully — joined by `--`
  (identifying, solid) or `..` (non-identifying, dashed), with an optional verb
  label. New public API: `parseEr`, `renderMermaidEr`. Golden fixture in
  `testdata/mermaid/er/`. v0 limitations: entity names are `[A-Za-z0-9_]`
  (hyphenated/quoted names unsupported); attribute key/comment columns render
  verbatim.
- Fixed graph layout bounds to include edge-label and endpoint-label candidate
  slots before shifting the diagram to the origin. ER cardinality labels now
  stay inside the canvas even for very narrow diagrams.
- Added a diagram benchmark lab (`zig build bench -- --diagram --out
  bench/results/diagram-optimized.json`) with parse/layout/render rows for small
  and medium flowcharts. The optimization pass eliminated the renderer's
  per-edge polyline conversion allocation by drawing routed edge segments
  directly into `CellCanvas`, then pre-sized known layout/rank/chaining
  structures. Against `bench/results/diagram-baseline.json`, the medium layout
  row drops from 12 to 10 allocations and from 27.8us to 20.6us median; medium
  render drops from 28 to 13 allocations and from 73.7us to 25.4us median. The
  small layout row drops from 9 to 8 allocations and from 33.2us to 14.8us
  median; small render drops from 13 to 11 allocations and from 34.6us to 18.6us
  median in this local ReleaseFast run.
- Added a **card-diagram** frontend (`cardDiagram`, `requirementDiagram`) — a
  repo-native generic compartment-card grammar (also parses real Mermaid
  requirement syntax). Cards (`card`, `requirement`, `element`, `person`,
  `system`, `container`, `component`, `database`, `queue`) lower to graph-IR
  compartment nodes, reusing the existing graph layout and card renderer.
  Relationships support `-->`, `--`, `..>`, `..`, and named requirement arrows
  such as `Agent - satisfies -> REQ-1`. New public API: `parseCard`,
  `renderMermaidCard`. Golden fixture in `testdata/mermaid/card/`.
- Added a **real Mermaid C4** frontend (`src/diagram/mermaid/c4.zig`) parsing the
  actual function-call syntax: `C4Context`/`C4Container`/`C4Component`/`C4Dynamic`/
  `C4Deployment` headers; `Person`/`System`/`Container`/`Component`/`Node` element
  calls (and `_Ext`/`Db`/`Queue` variants, plus a generic fallback) with
  `(alias, "label", "tech?", "descr?")` args; the `Rel` family (`Rel`, `BiRel`,
  `Rel_Back`, `Rel_U/D/L/R`, `RelIndex`); brace-delimited boundaries
  (`*_Boundary`/`Node`/`Deployment_Node`) drawn as nested cluster boxes;
  and ignored styling directives (`UpdateElementStyle`/`UpdateRelStyle`/
  `UpdateLayoutConfig`/`title`) and `$tags`/`$link` named args. Elements render as
  compartment cards with a `[stereotype: tech]` line plus description. New public
  API: `parseC4`, `renderMermaidC4`. Golden fixtures in `testdata/mermaid/c4/`.
  v0 limits: sprites/icons and per-rel direction hints are not drawn.
- Added a **real Mermaid `architecture-beta`** frontend
  (`src/diagram/mermaid/architecture.zig`): `group`/`service`/`junction`
  declarations with `(icon)[title]` and `in {parent}`, and `idA:R --> L:idB`
  connections (`--`/`-->`/`<--`/`<-->`, with `{group}` modifiers). Groups become
  drawn cluster boxes holding their `in`-members (nesting supported); an edge whose
  endpoint is a group id is routed to that group's box. New public API:
  `parseArchitecture`, `renderMermaidArchitecture`. Golden fixture in
  `testdata/mermaid/architecture/`. v0 limits: port sides and icons are parsed but
  not drawn.
- Added **boundary/group containment** to the graph layout
  (`src/diagram/layout/cluster_layout.zig`). The IR gained a `Cluster{id, label,
  parent}` tree plus `Node.cluster`; a recursive-composite layout lays each
  cluster out as its own sub-graph, boxes it, and embeds it in the parent level as
  one super-node. By construction no foreign node lands inside a box, nesting works
  to any depth, and inter-cluster edges meet the box border. Drives the C4-boundary
  and architecture-group boxes above and is the foundation for future
  `mindmap`/`block` backends. Graphs without clusters are unaffected (byte-identical
  output). New `layered.layoutLevel` (size overrides), `Layout.clusters`.
- Replaced the earlier card-frontend aliases that *accepted* `C4Context`/
  `architectureDiagram`/`c4Diagram` headers but rejected those diagrams' real
  syntax — the C4 and architecture headers now route to the real parsers above,
  so pasting genuine Mermaid C4/architecture works instead of erroring.
- Horizontal graph layouts now expand rank spacing when edge labels require more
  room, avoiding label/card collisions in LR architecture and C4-style diagrams.

### Library

- Added renderer-agnostic **bounded-pane** primitives (`src/frame_view.zig`) for
  fitting a `Frame` into a fixed terminal/TUI pane: `FrameViewport`,
  `OverflowMode`, `frameFits`, `renderFrameRegionToWriter` (clips/pads a region to
  ANSI; byte-identical to `renderFrameToWriter` for a full-frame viewport), and
  `cropFrameToCells` (copies a region into a new owned `Frame`). Fitting is
  deterministic — natural, pad, clip-from-origin, or error — with no scaling or
  relayout. New public API: `FrameViewport`, `OverflowMode`, `frameFits`,
  `renderFrameRegionToWriter`, `cropFrameToCells`.

### CLI and Tooling

- The CLI binary is now `cell-render` (the library module stays `image_to_ascii`).
- Added pane-fit flags to the `mermaid` subcommand: `--width`/`--height` fit an
  exact pane (pad or clip), `--max-width`/`--max-height` only bound, and
  `--overflow allow|clip|error` chooses behavior when the natural diagram exceeds
  the bounds (`error` exits non-zero reporting actual vs requested size). With no
  flags, output is natural (unchanged). `bench/results/diagram-viewport.json`
  records the diagram benchmark with these in place.
- Added a `mermaid` CLI subcommand: `cell-render mermaid <file.mmd>
  [--ascii|--unicode] [--color none|truecolor]` reads a Mermaid diagram
  (flowchart/sequence/state, auto-detected) and writes the rendered frame to
  stdout. Syntax errors are reported to stderr as `file:line:col: message` and
  exit non-zero. The diagram path stays decoder-free (it reads UTF-8 text, not
  images), and the existing image CLI is unchanged.
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
