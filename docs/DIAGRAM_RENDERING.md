# Diagram Rendering

Cell Render's diagram path is semantic terminal rendering, not image conversion.

```text
Mermaid text -> parser -> Diagram IR -> layout -> CellCanvas -> Frame -> ANSI / OpenTUI / Siftable buffer
```

Do not route Mermaid through SVG or PNG as the main runtime path. The image renderer is still valuable for screenshots
and decoded raster input, but diagrams should remain structured until they become terminal cells. That keeps output
deterministic, cheap to diff, and useful to agents that need precise parse errors and stable planning views.

## Layers

`Frame` is the shared output contract. It owns `codepoints`, `fg`, and `bg` arrays and is already accepted by the ANSI
writer, ANSI diff writer, quality tools, and TUI integration path.

`CellCanvas` is a mutable terminal drawing surface. It draws text, boxes, orthogonal lines, polylines, arrows, and line
joins, then exports to `Frame`. It is the reusable substrate for Mermaid, Siftable planning views, DAGs, state machines,
timelines, trace views, and future non-Mermaid diagrams.

`Diagram IR` is the semantic model. It should describe graph nodes, edges, participants, messages, states, and timeline
items without caring where the input came from.

`Layout` assigns terminal-cell coordinates and routes edges. Graph diagrams and sequence diagrams need separate layout
engines.

`Mermaid` is one input frontend. It should parse a useful subset, normalize to Diagram IR, and emit precise unsupported
syntax errors instead of pretending to be fully compatible on day one.

## Current Foundation

The checked-in drawing substrate is `CellCanvas`:

- `drawText`
- `drawBox`
- `drawLine`
- `drawPolyline`
- `drawArrow`
- Unicode box drawing and ASCII fallback glyph sets
- N/E/S/W line-join resolution
- `toFrame` export

The canvas has no per-cell heap allocation and does not depend on image sampling, decoders, terminal probing, OpenTUI, or
Mermaid.

The first input frontend is the **Mermaid flowchart parser**
(`src/diagram/mermaid/`). It compiles a flowchart subset into the graph IR
(`src/diagram/ir/graph.zig`) and is independent of layout and rendering:

```zig
var diagnostic: ?ascii.MermaidError = null;
var result = try ascii.parseFlowchart(allocator, source, &diagnostic);
defer result.deinit();
// result.diagram: GraphDiagram { direction, nodes[], edges[] }
```

The lexer fully classifies edge operators (stroke + endpoint) so it reproduces
Mermaid's `A---oB` circle-edge trap exactly, and the parser rejects lowercase
`end` as a node id rather than emitting the broken graph real Mermaid produces.
On any syntax error it returns `error.MermaidSyntax` and fills `diagnostic` with
a kind plus 1-based line/column — the actionable feedback an agent needs to fix
its own output. The parser owns an arena; all node/edge strings are copied into
it, so the diagram outlives the source buffer.

The **layered layout** (`src/diagram/layout/layered.zig`) and **graph renderer**
(`src/diagram/render/graph_renderer.zig`) turn that IR into terminal cells:

```zig
var diagnostic: ?ascii.MermaidError = null;
var frame = try ascii.renderMermaidFlowchart(allocator, source, .{
    .glyph_set = .unicode_box, // or .ascii
    .color = .truecolor, // or .none
}, &diagnostic);
defer frame.deinit(allocator);
try ascii.renderFrameToWriter(writer, frame);
```

The layout is a small Sugiyama pipeline: DFS cycle-breaking → longest-path rank
assignment (honoring per-edge `min_len`) → dummy nodes so every edge segment
spans one rank → median-heuristic ordering → neighbor-mean coordinate assignment
→ direction-aware mapping to cells → orthogonal (Manhattan) edge routing. It is
overlap-free by construction (in-rank separation, rank bands, dummy channels) and
deterministic. It is not crossing-minimal — the goal is stable, compact,
predictable output. Example (`--ascii`):

```text
+-------+
| Begin |
+-------+
    |
    +--+
       v
  +--------+
  | Choice |
  +--------+
       |
      yes------no
       v        v
    +-----+  +----+
    | Yes |  | No |
    +-----+  +----+
       |        |
       +---+----+
           v
       +------+
       | Done |
       +------+
```

Node shapes render distinctly (square `rect`, rounded `round`, capsule `circle`,
diagonal-corner `diamond`), `==>`/`-.->` edges use heavy/dotted glyphs, and edge
labels are placed beside the routing line (occupancy-aware, falling back to the
line only when the graph is too dense for a clear slot). Remaining v0 limitation:
self-loops render as a small stub. Golden fixtures live in
`testdata/mermaid/flowchart/` and are checked by `zig build test`.

```text
 ┌──────┐
 │ Rect │
 └──────┘
     │
     ▼
 ╭───────╮
 │ Round │
 ╰───────╯
     ┆          (dotted edge)
     ▼
╭────────╮
( Circle )
╰────────╯
     ┃          (thick edge)
     ▼
╱─────────╲
│ Diamond │
╲─────────╱
```

Diagram performance is tracked separately from image rendering:

```sh
zig build -Doptimize=ReleaseFast bench -- --diagram --out bench/results/diagram-optimized.json
```

The benchmark records parse/layout/render rows, graph size, output dimensions,
timings, allocation counts, allocated bytes, and render ANSI bytes.
`bench/results/diagram-baseline.json` captures the pre-optimization renderer;
`bench/results/diagram-optimized.json` captures direct edge-segment drawing plus
pre-sized layout/rank/chaining structures.

## Mermaid Compatibility Promise

Do not claim full Mermaid compatibility initially. The correct product claim is:

```text
Fast terminal renderer for a practical Mermaid subset.
```

The first Mermaid subset should support:

- `graph` / `flowchart`
- directions `TD`, `TB`, `LR`, `RL`, `BT`
- node IDs and labels such as `A[Label]`
- basic edge operators `-->`, `---`, `-.->`, `==>`
- edge labels such as `A -->|label| B`
- comments beginning with `%%`

Unsupported syntax should fail clearly in strict mode. Non-strict mode can warn and render a conservative fallback when
that is safe, such as rendering an unsupported shape as a rectangle.

## Build Order

1. ~~`CellCanvas` primitives.~~ ✅
2. ~~Minimal Mermaid flowchart lexer/parser.~~ ✅
3. ~~Diagram IR for graph nodes and edges.~~ ✅
4. ~~Stable layered graph layout with Manhattan routing.~~ ✅
5. ~~Flowchart renderer that writes to `CellCanvas`.~~ ✅
6. Sequence diagram parser and lane/time layout.
7. Benchmark and golden harness for diagram rendering.

The `mermaid` CLI subcommand is wired (`image-to-ascii mermaid diagram.mmd
[--ascii|--unicode] [--color none|truecolor]`); syntax errors print as
`file:line:col: message`. Distinct node shapes, heavy/dotted strokes, and
off-line edge labels are implemented. Next: the sequence-diagram track (lane/time
layout), then richer flowchart shapes and crossing reduction.

The official Mermaid CLI can be useful as an optional visual oracle during development, but it must not become a runtime
dependency for core rendering.
