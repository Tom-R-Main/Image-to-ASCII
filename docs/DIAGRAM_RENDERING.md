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
4. Stable layered graph layout with Manhattan routing.
5. Flowchart renderer that writes to `CellCanvas`.
6. Sequence diagram parser and lane/time layout.
7. Benchmark and golden harness for diagram rendering.

The official Mermaid CLI can be useful as an optional visual oracle during development, but it must not become a runtime
dependency for core rendering.
