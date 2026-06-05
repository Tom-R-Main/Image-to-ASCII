# Cell Render Implementation Plan

Date: 2026-06-05
Target repo: `Tom-R-Main/Image-to-ASCII`
Local workspace: `/Users/thomasmain/projects/image-to-ascii`

## Goal

Build a Zig-first terminal visual rendering library and CLI whose core returns terminal-native cells or streamed ANSI
output for images, diagrams, and TUI surfaces. The first image release proved:

```text
raw RGBA -> aspect-correct sampler -> density/half-block renderer -> Frame / coalesced ANSI writer
```

The next product layer is semantic diagram rendering:

```text
Mermaid text -> parser -> Diagram IR -> layout -> CellCanvas -> Frame -> ANSI / OpenTUI / Siftable buffer
```

The repo should not become a generic image upload converter, and Mermaid support should not become an SVG/PNG bridge
into the image renderer. The durable product is a small embeddable terminal renderer for TUI apps and agentic planning
surfaces, with Siftable as the first important integration target.

## Repository Assumptions

- The GitHub repo `Tom-R-Main/Image-to-ASCII` is the destination repository.
- The local git repo currently has no commits and no remote configured.
- `RESEARCH.md` is the architecture source of truth.
- Zig `0.16.0` is the local toolchain target unless the project deliberately pins another version.
- Core library code must not decode files, probe terminals, or write stdout/stderr.

## Non-Goals For V1

- No PNG/JPEG/GIF decoder in core.
- No Kitty/Sixel/iTerm image protocol renderer.
- No Python dependency in the hot path.
- No glyph-structure scorer before a quality metric harness exists.
- No terminal auto-detection inside the library.
- No bundled GPL or LGPL code.

## Architectural Commitments

1. Use `ImageView` raw RGBA input as the public core input.
2. Use `CellCanvas` as the mutable drawing substrate for diagrams and terminal UI primitives.
3. Use `Frame` structure-of-arrays output:
   - `codepoints: []u21`
   - `fg: []Rgb8`
   - `bg: []Rgb8`
4. Treat color mode as a frame property instead of per-cell optionals.
5. Expose `renderToCells(...) !Frame` for TUIs.
6. Expose `renderToWriter(*std.Io.Writer, ...) !void` for CLI and logs.
7. Model density, half-block, quadrant, sextant, octant, and Braille with `PartitionModel` tables where possible.
8. Keep glyph rendering split into:
   - `glyph_tone`: calibrated density path,
   - `glyph_structure`: alignment-tolerant shape path.
9. Do color accumulation in linear light and encode back to sRGB for terminal output.
10. Coalesce ANSI SGR runs in the writer path.
11. Keep decoding and font rasterization in CLI, adapters, or `tools/`, not core.
12. Keep Mermaid as one frontend over Diagram IR, layout, and `CellCanvas`; do not make it own the renderer.

## Diagram Rendering Track

### Slice 1: CellCanvas

Status: implemented.

- reusable `CellCanvas` allocation/reuse,
- `drawText`,
- `drawBox`,
- `drawLine`,
- `drawPolyline`,
- `drawArrow`,
- Unicode and ASCII glyph sets,
- line intersection/join resolver,
- conversion to `Frame`,
- golden-style unit tests for boxes, arrows, intersections, and labels.

### Slice 2: Minimal Mermaid Flowchart Parser

Status: implemented (`src/diagram/mermaid/`, IR in `src/diagram/ir/graph.zig`).

Supported first subset:

- `graph` / `flowchart`,
- directions `TD`, `TB`, `LR`, `RL`, `BT` (default top-down),
- node IDs, shapes (`[rect]`, `(round)`, `((circle))`, `{diamond}`), and quoted
  labels such as `A["two words"]`,
- edge operators `-->`, `---`, `-.->`, `==>` plus circle/cross ends `--o`, `--x`,
- edge chains `A --> B --> C`,
- edge labels such as `A -->|label| B`,
- comments beginning with `%%`.

The lexer fully classifies edge operators and reproduces Mermaid's `A---oB`
circle-edge trap; the parser rejects lowercase `end` as a node id. Syntax errors
return `error.MermaidSyntax` with a `MermaidError` (kind + 1-based line/column).
The result owns an arena and copies all strings into it, so the diagram outlives
the source. Still outstanding for a later slice: the `-- text -->` inline-label
form, subgraphs, and `A@{ shape: ... }` general shape syntax.

### Slice 3: Layered Flowchart Renderer

Status: implemented (`src/diagram/layout/layered.zig`, `src/diagram/render/graph_renderer.zig`).

- normalize direction to an internal primary/secondary space, ✅
- assign ranks using longest-path ranking honoring `min_len`, ✅
- break cycles via DFS back-edge marking, ✅
- insert dummy nodes so each edge segment spans one rank, ✅
- order nodes inside ranks with a median heuristic, ✅
- assign integer terminal coordinates (neighbor-mean, separation-safe), ✅
- route edges with orthogonal Manhattan paths through dummy channels, ✅
- place edge labels near path midpoints, ✅
- render to `CellCanvas` and export a `Frame`. ✅

Output is overlap-free by construction and deterministic; it is not
crossing-minimal. Golden fixtures: `testdata/mermaid/flowchart/*.{mmd,golden.txt}`.
Deferred: distinct node-shape rendering, dotted/thick stroke glyphs, off-line edge
labels, a CLI `mermaid` subcommand, and a diagram benchmark lab.

### Slice 4: Sequence Diagram Subset

Sequence diagrams use lane/time layout, not graph layout. Start with participants, aliases, solid/dotted/async arrows,
messages, and self-messages.

## Milestone 0: Repo Bootstrap

Purpose: turn the empty repo into a clean Zig package with documentation, CI shape, and no implementation surprises.

### Tasks

- Add repo metadata:
  - `README.md`
  - `LICENSE`
  - `.gitignore`
  - `build.zig`
  - `build.zig.zon`
  - `src/root.zig`
  - `src/cli.zig`
  - `testdata/README.md`
  - `bench/README.md`
  - `tools/README.md`
- Decide license:
  - preferred: Apache-2.0 if patent language matters,
  - acceptable: MIT or 0BSD for maximal simplicity.
- Configure local remote when ready:
  - `git remote add origin git@github.com:Tom-R-Main/Image-to-ASCII.git`
- Add initial README sections:
  - what the library is,
  - what it is not,
  - core API sketch,
  - first release scope,
  - Zig version.
- Add `.gitignore` for:
  - `.zig-cache/`
  - `zig-out/`
  - editor files,
  - generated benchmark images,
  - large local corpora.

### Validation

```text
zig version
zig build
zig build test
git status --short
```

### Done Criteria

- Fresh clone can run `zig build test`.
- README clearly states library-first direction.
- No generated or large files are tracked.
- Remote setup is documented or configured.

## Milestone 1: Core Types And Validation

Purpose: establish the public API and ownership model before renderer complexity appears.

### Files

```text
src/core.zig
src/pixel.zig
src/root.zig
```

### Tasks

- Define public enums:
  - `RenderMode`
  - `PartitionKind`
  - `Quality`
  - `ColorMode`
  - `TerminalSymbols`
  - `FitMode`
  - `DitherMode`
- Define pixel and image types:
  - `Rgba8`
  - `Rgb8`
  - `ImageView`
  - linear color helper type if needed internally.
- Define `TerminalProfile`.
- Define `Options`.
- Define SoA `Frame` and `Frame.deinit`.
- Implement validation:
  - image width/height nonzero,
  - stride can address each row,
  - pixel slice is large enough for width/height/stride,
  - terminal columns/rows nonzero,
  - cell aspect positive and finite,
  - custom density ramp nonempty and valid.
- Re-export public API from `src/root.zig`.

### Tests

- Valid `ImageView` passes.
- Zero dimensions fail.
- Too-small pixel slice fails.
- Invalid terminal dimensions fail.
- `Frame.deinit` releases all three buffers without leaks.
- Custom ramp rejects control characters in strict ASCII mode.

### Done Criteria

- No rendering yet, but API compiles and validation behavior is deterministic.
- Tests use `std.testing.allocator` and pass leak checks.

## Milestone 2: Luma, Color, And Aspect-Correct Sampling

Purpose: build the shared math used by every renderer.

### Files

```text
src/luma.zig
src/color.zig
src/sample.zig
```

### Tasks

- Implement sRGB to linear conversion.
- Implement linear to sRGB conversion.
- Implement alpha compositing over `TerminalProfile.background`.
- Implement perceptual luminance/lightness for ramp indexing.
- Implement brightness, contrast, and invert transforms.
- Implement fit calculation:
  - contain,
  - cover,
  - stretch.
- Implement output region calculation:
  - requested terminal bounds,
  - fitted columns/rows,
  - source-to-output mapping.
- Implement square-subpixel compensation keyed by partition `sx/sy`.
- Implement area box sampler for:
  - one sample per cell,
  - partition subcell grids.
- Implement representative color helpers:
  - trimmed mean first,
  - median later if implementation cost needs staging.

### Tests

- sRGB black/white round trips.
- Known alpha compositing cases pass.
- A `1:1` image in `a = 0.5` terminal chooses about twice as many columns as rows under contain-fit.
- Half-block `1x2` subpixels are square at `cell_aspect = 0.5`.
- Quadrant compensation is applied consistently.
- Tiny fixture sampling returns expected averages.

### Done Criteria

- Sampling has no per-cell allocation.
- Aspect math is covered by tests before renderer work depends on it.

## Milestone 3: Density Renderer

Purpose: ship the simplest renderer as the baseline and test harness driver.

### Files

```text
src/ramp.zig
src/render.zig
```

### Tasks

- Add default density ramp.
- Validate ramps:
  - nonempty,
  - printable ASCII when `TerminalSymbols.ascii_only`,
  - no control codepoints.
- Implement ramp indexing by perceptual luminance.
- Implement `renderToCells` for `RenderMode.density`.
- Allocate `Frame.codepoints`, `Frame.fg`, and `Frame.bg` once per render.
- Support `ColorMode.none`.
- Support `ColorMode.truecolor`.
- Defer ANSI 16/256 quantization unless needed for CLI parity.

### Tests

- Black maps to darkest ramp end.
- White maps to lightest ramp end.
- Invert flips ramp selection.
- Color disabled leaves `fg` and `bg` empty.
- Truecolor frame fills colors for every cell.
- Golden tiny gradient output is stable.

### Done Criteria

- `renderToCells` works for density.
- No CLI decoder needed.
- Synthetic raw RGBA tests pass.

## Milestone 4: Symbol Tables And Half-Block Renderer

Purpose: prove the partition-model architecture on the first high-value TUI renderer.

### Files

```text
src/symbol.zig
src/render.zig
```

### Tasks

- Define `PartitionModel`.
- Define `MaskGlyph`.
- Add `density_1x1` model.
- Add `half_1x2` model:
  - space,
  - upper half block,
  - lower half block,
  - full block.
- Implement half-block render path:
  - sample top and bottom subcells,
  - choose codepoint,
  - assign fg/bg from top/bottom regions,
  - handle empty/full regions cleanly.
- Use truecolor as the default half-block path.
- Add fallback behavior when terminal symbols do not support blocks.

### Tests

- Top black/bottom white emits expected lower/upper mapping.
- Top red/bottom blue assigns expected fg/bg.
- Solid region can emit full block or space according to chosen policy.
- Symbol capability fallback is deterministic.
- Golden `2x4` raw fixture to one or two cells is stable.

### Done Criteria

- Half-block output looks correct in a normal terminal.
- Density remains available as fallback.
- This is the first useful Siftable preview candidate.

## Milestone 5: ANSI Writer

Purpose: support CLI/log output without making ANSI byte materialization the core API.

### Files

```text
src/ansi.zig
src/cli.zig
```

### Tasks

- Implement UTF-8 codepoint emission.
- Implement SGR state:
  - current fg,
  - current bg,
  - current color mode,
  - reset behavior.
- Emit truecolor SGR only when fg/bg changes.
- Reset at row boundaries or track state across rows with a final reset.
- Implement `renderToWriter`.
- Add test helper that writes into a fixed buffer or allocating writer.
- Keep explicit flush at CLI boundary.

### Tests

- ANSI truecolor for one cell emits expected sequence.
- Adjacent cells with same colors do not repeat SGR.
- Color change emits only necessary SGR.
- Final reset is present.
- Plain/monochrome output does not emit color SGR.

### Done Criteria

- CLI can write synthetic output via `renderToWriter`.
- Escape overhead is bounded by color runs, not cell count.

## Milestone 6: Minimal CLI And Fixtures

Purpose: make the package usable from the terminal without introducing broad decoder dependencies.

### Files

```text
src/cli.zig
tools/fixturegen.zig or test-support PPM/PAM reader
testdata/
```

### Tasks

- CLI supports synthetic inputs:
  - gradient,
  - checkerboard,
  - color bars.
- CLI supports raw RGBA fixture input if useful.
- Add PPM/PAM reader only under CLI/test-support path.
- CLI flags:
  - `--mode density|partition`
  - `--partition density|half`
  - `--width`
  - `--height`
  - `--fit contain|cover|stretch`
  - `--color none|truecolor`
  - `--dither none`
  - `--invert`
  - `--ramp`
- CLI may probe terminal size later, but initial version should accept explicit dimensions.

### Tests

- CLI synthetic gradient exits 0.
- CLI explicit dimensions produce expected row/column count.
- Invalid args return nonzero and write help to stderr.
- No stdout writes occur from core code.

### Done Criteria

- `zig build run -- --synthetic gradient --width 80 --height 24` prints output.
- The CLI proves library integration without decoder scope creep.

## Milestone 7: Ordered Dithering And Binary Subcell Families

Purpose: extend the partition table system after density/half-block are stable.

### Files

```text
src/dither.zig
src/symbol.zig
src/render.zig
```

### Tasks

- Implement ordered 2x2 dithering.
- Implement ordered 4x4 dithering.
- Add quadrant `2x2` table.
- Add sextant `2x3` table gated by `TerminalSymbols.block_legacy`.
- Add Braille `2x4` table and mask ordering.
- Decide whether octant `2x4` should be separate from Braille in this milestone or deferred.
- Keep Floyd-Steinberg deferred until the virtual-grid pass is designed.

### Tests

- Ordered dithering deterministic on tiny fixtures.
- Quadrant all 16 masks map to expected codepoints.
- Sextant unsupported terminal profile falls back.
- Braille dot mask ordering matches Unicode Braille dot layout.
- Monochrome Braille thumbnail golden output is stable.

### Done Criteria

- Partition extension does not duplicate renderer architecture.
- All subcell families share sampler and symbol lookup behavior.

## Milestone 8: Benchmarks

Purpose: catch performance regressions before glyph work raises complexity.

### Files

```text
bench/
build.zig
```

### Tasks

- Add benchmark command in `build.zig`.
- Generate or load deterministic synthetic images:
  - gradient,
  - checkerboard,
  - color bars,
  - noisy photo-like field.
- Measure separately:
  - sampling,
  - density render,
  - half-block render,
  - ANSI encode,
  - total render.
- Report:
  - megapixels/sec,
  - output cells/sec,
  - p50/p95 elapsed if repeated runs are included.
- Establish first targets:
  - `400x240 -> 80x30` density under 5 ms,
  - `400x240 -> 80x30` truecolor half-block under 5 ms,
  - ANSI encoding measured independently.

### Done Criteria

- Benchmark results are stable enough to compare locally.
- Bench does not require network, secrets, or large assets.

## Milestone 9: Quality Harness

Purpose: make glyph-mode decisions measurable before implementing the moat.

### Files

```text
tools/render_compare.zig
tools/calibrate_font.zig
tools/README.md
```

### Tasks

- Choose a font rasterizer dependency for tools only:
  - FreeType,
  - stb_truetype,
  - or another permissive option.
- Render generated terminal text back to an image.
- Compare against resized source:
  - PSNR,
  - SSIM if practical,
  - edge-preservation score.
- Keep tool dependency out of `src/root.zig` and the core package.
- Create a tiny quality corpus:
  - line art,
  - UI screenshot crop,
  - face/photo-like image,
  - logo/text image.

### Done Criteria

- A scorer change can be evaluated numerically and visually.
- Core library still builds without font rasterizer dependencies.

## Milestone 10: Glyph-Tone

Purpose: add calibrated glyph rendering without the full structure scorer risk.

### Files

```text
src/glyph.zig
tools/calibrate_font.zig
```

### Tasks

- Define `GlyphAtlas`.
- Define `GlyphFeature`.
- Generate or bundle a generic ASCII monospace atlas.
- Bucket glyphs by coverage.
- Implement `RenderMode.glyph_tone`.
- Use coverage/lightness as the main match.
- Use glyph mask for fg/bg color solve where truecolor is enabled.
- Validate atlas codepoints are width-1 and non-combining during generation.

### Tests

- Atlas validation rejects invalid glyphs.
- Coverage buckets find candidates.
- Glyph-tone maps black/white extremes predictably.
- Golden ASCII-only glyph output is stable.

### Done Criteria

- `glyph_tone` beats hand-authored density ramp on measured coverage cases.
- The implementation does not yet claim structure-aware fidelity.

## Milestone 11: Glyph-Structure

Purpose: build the long-term differentiator after metrics exist.

Status: baseline implemented. The current path samples cells at the calibrated
8x16 atlas grid, prefilters by coverage, scores packed masks with small offset
tolerance, and falls back to glyph-tone for low-contrast cells. The remaining
work is scorer refinement, broader corpus coverage, and performance tuning.

### Files

```text
src/glyph.zig
src/sample.zig
tools/render_compare.zig
```

### Tasks

- Extract source cell structure features:
  - edge magnitude,
  - dominant orientation,
  - possibly blurred or distance-map masks.
- Prefilter glyphs by:
  - coverage bucket,
  - dominant orientation,
  - rough centroid/spread if useful.
- Implement final alignment-tolerant scorer:
  - start with min distance over small offsets,
  - evaluate AISS-style directional metric only if the proxy is insufficient.
- Add quality modes:
  - `balanced`: limited candidate count,
  - `high`: larger candidate count and optional local refinement.
- Add optional continuity penalty only after independent per-cell quality is strong.

### Tests

- Candidate pruning reduces search set to target range.
- Fixed-position mask mismatch case is improved by offset-tolerant scoring.
- Edge-preservation metric improves on line-art corpus.

### Done Criteria

- Structure mode has measured improvement over glyph-tone on edge-heavy images.
- Performance remains acceptable for still images.

## Milestone 12: Decoder Adapters And Packaging

Purpose: make the CLI practical while preserving the raw-pixel core.

### Files

```text
test_support/image_loader.zig
src/cli.zig
tools/render_compare.zig
bench/main.zig
README.md
```

### Tasks

- Pick optional decoder strategy:
  - `zigimg` selected first for PNG/JPEG CLI input,
  - keep `zstbi` as the fallback candidate if future JPEG coverage or simplicity demands it,
  - do not hand-roll JPEG; direct PNG/JPEG parsing is out of this slice.
- Keep adapter dependency out of `src/root.zig` and core modules.
- Add CLI image loading for PNG/JPEG still frames as supported by the adapter.
- Preserve raw RGBA path for tests and embedders.
- Document dependency boundaries.
- Add small real-image smoke fixtures and `bench/results/real-image-smoke.json`.
- Add examples:
  - render image to terminal,
  - write output text file,
  - call from Zig library code.

### Done Criteria

- CLI is useful on real images.
- Core package remains dependency-light and decoder-free.
- PPM/PAM fixture behavior remains unchanged.
- Real-image smoke fixtures decode and produce finite quality metrics.

## GitHub Launch Plan

### Initial Commit

Include:

```text
README.md
RESEARCH.md
PLAN.md
LICENSE
.gitignore
build.zig
build.zig.zon
src/root.zig
src/cli.zig
```

Validation before commit:

```text
zig fmt .
zig build test
git status --short
```

### Remote Setup

When ready:

```text
git remote add origin git@github.com:Tom-R-Main/Image-to-ASCII.git
git branch -M main
git push -u origin main
```

Use HTTPS instead if SSH auth is not configured:

```text
git remote add origin https://github.com/Tom-R-Main/Image-to-ASCII.git
```

### Issues To Create

1. Bootstrap Zig package and docs.
2. Implement core API and validation.
3. Implement luma/color/aspect sampler.
4. Implement density renderer.
5. Implement half-block partition renderer.
6. Implement ANSI writer with SGR coalescing.
7. Implement minimal CLI synthetic inputs.
8. Add ordered dithering and quadrant/Braille tables.
9. Add benchmark harness.
10. Add quality harness.
11. Implement glyph-tone.
12. Implement glyph-structure.
13. Add optional decoder adapter.

## Release Gates

### `v0.1.0`: Useful Core Preview

Must include:

- raw RGBA API,
- `renderToCells`,
- `renderToWriter`,
- density mode,
- truecolor half-block mode,
- aspect-correct sampling,
- ANSI SGR coalescing,
- minimal CLI synthetic input,
- unit tests,
- benchmark command.

Must not include:

- decoder dependency in core,
- glyph-structure claims,
- terminal probing in core.

### `v0.2.0`: Performance Laboratory And Reuse

Must include:

- tracked JSON benchmark baseline,
- render-kernel matrix with median and p95 timing,
- ANSI encode-only measurement,
- prepared-image / render-context seam for reusable luma precomputation,
- source sampling span precomputation benchmarked against the baseline artifact,
- tuned auto sampler policy with per-row policy visibility in benchmark output,
- render-workspace reuse API for frame buffers and render-shape scratch,
- repeated-render benchmark rows with first-render and steady-state allocation counts,
- ANSI frame-diff writer with dirty-run benchmarks,
- checked-in quality corpus with slash golden and finite-metric regression gates,
- first glyph-structure hot-path optimization measured against the quality corpus
  and ANSI-diff benchmark artifact,
- integration notes for Siftable or another TUI consumer, including
  `PreparedImage`, double-buffered `RenderWorkspace` reuse, `Frame`, ANSI diff
  ownership, and the OpenTUI bridge rule: copy cells into the TUI buffer rather
  than feeding ANSI through a text renderable.

### `v0.3.0`: Glyph-Tone

Must include:

- glyph atlas format,
- generic ASCII atlas,
- glyph-tone renderer,
- initial quality harness.

### `v0.4.0`: Glyph-Structure

Must include:

- alignment-tolerant scorer,
- measurable edge-preservation improvement,
- documented performance envelope.

### `v1.0.0`: Stable Embeddable Library

Must include:

- stable public API,
- clear ownership docs,
- documented terminal profile assumptions,
- benchmark baselines,
- real-image CLI adapter,
- permissive licensing confirmed,
- practical integration examples for Siftable or another TUI consumer.
- optional app-local OpenTUI adapter proof that maps `Frame` cells into an
  `OptimizedBuffer` without adding an OpenTUI dependency to core.

## Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Zig `std.Io` APIs continue moving | API churn | Pin Zig version and isolate writer code in `ansi.zig`. |
| Aspect math bugs make output look squashed | High user-visible quality risk | Test contain/cover/stretch and square-subpixel compensation early. |
| ANSI output too verbose | Slow CLI/TUI output | Implement SGR coalescing before real-image CLI work. |
| Glyph scorer becomes weight soup | Mediocre output | Build quality harness before `glyph_structure`. |
| Decoder dependency leaks into core | Bad embedder ergonomics | Keep adapters outside `src/root.zig` exports. |
| Sextant/octant support varies by terminal | Broken output | Gate by `TerminalSymbols` and fallback deterministically. |
| Median color is costly | Latency risk | Start with trimmed mean, add median behind quality/content policy. |
| Remote repo stays empty while local diverges | Collaboration risk | Push bootstrap docs and skeleton early. |

## Open Decisions

- License: Apache-2.0 vs MIT vs 0BSD.
- Package name: `ascii-render`, `image-to-ascii`, or another Zig module name.
- Public product name: currently documented as Cell Render while the Zig module
  and CLI remain `image_to_ascii` / `image-to-ascii` for compatibility.
- Whether `RenderMode.braille` should be separate from `PartitionKind.octant_2x4` long term.
- Whether ANSI 16/256 support belongs in `v0.1.0` or after truecolor is stable.
- Which optional decoder adapter to use first. Answer: `zigimg`, with `zstbi` as fallback if JPEG coverage becomes the
  limiting factor.
- Which font rasterizer to use in `tools/` for calibration and quality metrics.
- Which Mermaid subset should be the first compatibility target after the
  flowchart v0 path is stable.

## Immediate Next Actions

1. Add a minimal Mermaid flowchart lexer/parser that normalizes to a graph IR
   and rejects unsupported syntax clearly.
2. Add a layered graph layout and render the first flowchart subset through
   `CellCanvas`.
3. Add diagram golden fixtures and `bench/results/diagram-baseline.json` once
   parse/layout/render stages exist.
4. Continue image glyph-structure scoring only after profiling identifies
   candidate scoring, not sampling, as the bottleneck.
