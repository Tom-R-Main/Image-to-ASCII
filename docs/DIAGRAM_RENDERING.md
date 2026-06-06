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
6. ~~Sequence diagram parser and lane/time layout.~~ ✅
7. Benchmark and golden harness for diagram rendering (flowchart done; sequence
   has golden fixtures, benchmark rows pending).

## Sequence Diagrams

The second frontend is sequence diagrams, which use a lane/time layout rather than
graph layout: `sequenceDiagram text -> parser -> sequence IR -> lane/time layout
-> CellCanvas -> Frame`. Participants become vertical lanes (a header box plus a
dotted lifeline); messages stack top-to-bottom in source order with labels above
the arrows.

```text
+-------+      +-----+
| Alice |      | Bob |
+-------+      +-----+
    :             :
    :   Request   :
    +------------->
    :  Response   :
    <.............+
    :Async notify :
    +------------->
```

Supported: `participant`/`actor` with `as` aliases, implicit participants (created
in first-seen order), all eight message arrows (`->`, `-->`, `->>`, `-->>`, `-)`,
`--)`, `-x`, `--x`), self-messages (a small right-side loop), and `%%` comments.
Heads are distinct: filled `►◄`, open async `▷◁`, cross `×`. **Notes**
(`left of`/`right of`/`over`, including `over A,B`) render as boxes over the
lifelines. **Activations** (`->>+` / `-->>-` suffixes and standalone
`activate`/`deactivate`, nestable) render the active lifeline span as a solid
heavy segment (`┃`) against the dotted idle line (`┆`). **Blocks** —
`alt`/`opt`/`loop`/`par` with `else`/`and` and `end`, including nesting — render
as labeled frames around their events (`alt [is valid]`), sized to fit both the
content and the title; nested frames are enclosed by their parents, and
`else`/`and` render as dotted dividers. Deferred: `critical`/`break`/`rect`
blocks and a repeated participant row at the bottom.

## State Diagrams

State diagrams are graph-layout diagrams, so the frontend
(`src/diagram/mermaid/state.zig`) lowers `stateDiagram`/`stateDiagram-v2` straight
to the shared graph IR and reuses the layered layout and graph renderer — there is
no separate state layout or renderer. States render as rounded nodes and `[*]` as
a circle; start and end pseudo-states are kept distinct so `[*] → … → [*]` is a
clean DAG rather than a cycle. Supported: transitions (`A --> B`, `A --> B :
label`), state descriptions (`S : text`), `direction`, and `%%` comments.
Deferred: composite states, choice/fork/join, and notes.

```text
   .---.
   ( * )
   '---'
     |
     v
.--------.
| Active |
'--------'
     |
  finish
     v
 .------.
 | Done |
 '------'
```

## Class Diagrams

Class diagrams are also graph-layout, lowered to the shared graph IR
(`src/diagram/mermaid/class.zig`). They add a **compartment-node renderer**: a
class becomes a "card" — a header plus stacked compartments (attributes, methods)
— instead of a simple box. The graph IR `Node` carries optional `compartments`,
and `ir.cardHeight` is shared by the layout (to size the node) and the renderer
(to place dividers) so the card exactly fills its rect. This card renderer is the
reusable substrate for future ER, requirement, architecture, and C4 cards.

```text
+---------------+
|     User      |
+---------------+
| +String id    |
+---------------+
| +login() bool |
+---------------+
        ^
        +-----------+
        v           |
   +---------+  +-------+
   | Session |  | Admin |
   +---------+  +-------+
```

Relationships lower to edges with UML endpoint decorations
(`ArrowKind.triangle`/`diamond`/`diamond_filled` plus `Edge.head_at_source`):
inheritance `<|--`/`--|>`, composition `*--`/`--*`, aggregation `o--`/`--o`,
association `-->`/`<--`/`--`, dependency `..>`/`<..`, realization `..|>`/`<|..`,
each with an optional `: label`. The parent/whole is placed on top with its
decoration at the source. Deferred: generics/annotations/namespaces,
multiplicities, and spreading multiple same-side decorations across the parent's
edge (today two source-decorated relationships share the exit port).

## Entity-Relationship Diagrams

ER diagrams (`src/diagram/mermaid/er.zig`) reuse the compartment-node renderer:
each entity is a single-compartment card (header + attribute lines). Relationships
carry cardinality at **both** ends, supported by `Edge.from_end`/`Edge.to_end`
(short text drawn beside each endpoint). A cell grid can't draw crow's feet
faithfully, so the tokens map to multiplicity text — `||`→`1`, `|o`/`o|`→`0..1`,
`}|`/`|{`→`1..N`, `}o`/`o{`→`0..N` — joined by `--` (identifying, solid) or `..`
(non-identifying, dashed), with an optional verb label at the midpoint.

```text
+-------------------+
|     CUSTOMER      |
+-------------------+
| string name       |
| string custNumber |
+-------------------+
          |1
          |places
          |0..N
      +-------+
      | ORDER |
      +-------+
```

Deferred: hyphenated/quoted entity names, attribute key/comment columns, and
full crow's-foot glyph geometry. Edge labels and endpoint labels are included in
the layout bounds before the graph is shifted to the origin, so narrow diagrams
still keep cardinality text inside the emitted canvas.

## Card Diagrams

Card diagrams (`src/diagram/mermaid/card.zig`) are a compact, LLM-editable
compartment-card grammar for planning views (the `requirementDiagram` header also
parses real Mermaid requirement syntax):

```text
cardDiagram
  direction LR
  person Agent "Planning Agent" {
    model: LLM
    role: edits diagrams
  }
  component Renderer "Cell Render" {
    tech: Zig
    output: Frame + ANSI
  }
  Agent --> Renderer : emits cardDiagram
```

Supported card headers are `cardDiagram` and `requirementDiagram`. Card kinds are
`card`, `requirement`, `element`, `person`, `system`, `container`, `component`,
`database`, and `queue`. Block body lines are kept verbatim in one compartment,
with the card kind prepended as `kind: ...`. Relationships support `-->`, `--`,
`..>`, `..`, and requirement-style named arrows such as `Agent - satisfies -> REQ-1`.

## C4 and Architecture (real Mermaid syntax)

C4 and architecture-beta are graph-layout diagrams with their own real syntaxes,
so they have dedicated parsers (not the generic card grammar) that both lower to
the shared graph IR and reuse the compartment-card renderer.

**C4** (`src/diagram/mermaid/c4.zig`) parses the real function-call syntax —
`C4Context`/`C4Container`/`C4Component`/`C4Dynamic`/`C4Deployment` headers;
`Person(alias, "label", "descr")`, `System`/`Container`/`Component`/`Node` and
their `_Ext`/`Db`/`Queue` variants; the `Rel` family (`Rel`, `BiRel`, `Rel_Back`,
`Rel_U/D/L/R`, `RelIndex`); brace-delimited boundaries (`*_Boundary`/`Node`/
`Deployment_Node`) now become **drawn cluster boxes** (see Containment below) and
nest; `UpdateElementStyle`/`UpdateRelStyle`/`UpdateLayoutConfig`/`title` ignored.
Each element renders as a card with a `[stereotype: tech]` line and a description.
Deferred: sprites/icons, per-rel direction hints.

**Architecture** (`src/diagram/mermaid/architecture.zig`) parses real
`architecture-beta` — `group`/`service`/`junction` with `(icon)[title]` and
`in {parent}`, and `idA:R --> L:idB` connections (`--`/`-->`/`<--`/`<-->`, with
`{group}` modifiers). Groups now become **drawn cluster boxes** containing their
`in`-members and nesting via `group … in <group>`; an edge whose endpoint is a
group id is routed to that group's box. Deferred: port sides and icons (parsed
but not drawn).

### Containment (boundary/group boxes)

Both diagrams lower grouping to `GraphDiagram.clusters` (a `Cluster{id, label,
parent}` tree) plus a `Node.cluster` back-reference. `cluster_layout.zig` renders
them with a **recursive-composite** strategy: each cluster is laid out as its own
sub-graph, boxed, and handed to the parent level as one fixed-size super-node;
the parent's layout places loose nodes and cluster boxes together, then the
sub-layout is blitted into the box interior. Consequences, by construction: a
foreign node can never land inside a cluster box, nesting works to any depth, and
an inter-cluster edge is lifted to the lowest common scope and routed to the
cluster **box border** (not the exact inner node — matching how grouped diagrams
are normally drawn). The same machinery is what future `mindmap`/`block` backends
will reuse. Diagrams without clusters take the plain single-level layout path
unchanged, so existing flowchart/state/class/ER output is byte-identical.

A `renderMermaid` dispatcher detects the diagram type from the header keyword and
routes to the flowchart, sequence, state, class, ER, card, C4, or architecture
backend, so `cell-render mermaid file.mmd` handles any of them.

## Bounded Panes (Viewport)

Diagrams render to their natural size; for TUI/Siftable panes that size must be
bounded. `src/frame_view.zig` adds renderer-agnostic primitives over any `Frame`:

- `FrameViewport { x, y, columns, rows }` and `OverflowMode { allow, clip, error_if_too_large }`,
- `frameFits(frame, columns, rows)`,
- `renderFrameRegionToWriter(writer, frame, viewport)` — emit a bounded region as
  ANSI (clips when the viewport is smaller, blank-pads when larger; byte-identical
  to `renderFrameToWriter` for a full-frame viewport),
- `cropFrameToCells(allocator, frame, viewport)` — copy a region into a new owned
  `Frame` (e.g. to blit into a TUI buffer).

There is no scaling or relayout yet — fitting is deterministic: natural → pad,
clip from origin, or error. The CLI exposes this:

```sh
cell-render mermaid diagram.mmd --width 100 --height 30 --overflow clip
cell-render mermaid diagram.mmd --max-width 120 --max-height 40 --overflow error
```

`--width`/`--height` fit an exact pane (pad or clip); `--max-width`/`--max-height`
only bound (no padding); `--overflow` chooses what happens when the natural
diagram exceeds the bounds (`error` exits non-zero with the actual vs requested
size). With no bounds, output is natural (unchanged).

## Status and Next

The `mermaid` CLI subcommand renders flowchart, sequence, state, class, ER, card,
C4, and architecture-beta diagrams
(`cell-render mermaid diagram.mmd [--ascii|--unicode] [--color none|truecolor]`
plus the viewport flags above); syntax errors print as `file:line:col: message`.
Flowcharts have distinct node shapes, heavy/dotted strokes, and off-line edge
labels; sequence diagrams cover notes, activations, and alt/opt/loop/par blocks;
class and ER diagrams render compartment cards (with UML relationship ends and
cardinality respectively); card/C4/architecture diagrams render planning cards
through the same compartment renderer (C4 and architecture parse their real
syntax), and C4 boundaries / architecture groups now draw nested containment
boxes (see Containment above). Next: `mindmap`/`block` backends on top of the
cluster machinery, and spreading multiple same-side class decorations across the
parent's edge.

The official Mermaid CLI can be useful as an optional visual oracle during development, but it must not become a runtime
dependency for core rendering.
