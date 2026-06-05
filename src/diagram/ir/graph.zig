//! Semantic graph IR shared by the flowchart frontend and any future graph-like
//! diagram producers (task DAGs, state machines, agent plans). The renderer and
//! layout engine consume this model and never see Mermaid syntax.

const std = @import("std");

/// Layout direction. `td` and `tb` are synonyms in Mermaid; both are kept so a
/// round-trip preserves the author's spelling intent, but layout treats them
/// identically (top-to-bottom).
pub const Direction = enum {
    td,
    tb,
    lr,
    rl,
    bt,

    pub fn isHorizontal(self: Direction) bool {
        return self == .lr or self == .rl;
    }
};

/// Node outline. The basic Mermaid v0 subset; expanded shapes come later.
pub const NodeShape = enum {
    rect,
    round,
    circle,
    diamond,
};

/// Stroke style of an edge.
pub const LineKind = enum {
    solid,
    dotted,
    thick,
};

/// Endpoint decoration. `arrow`/`circle`/`cross` are flowchart edge ends;
/// `triangle`/`diamond`/`diamond_filled` are the UML class-relationship ends
/// (inheritance/realization, aggregation, composition).
pub const ArrowKind = enum {
    none,
    arrow,
    circle,
    cross,
    triangle,
    diamond,
    diamond_filled,
};

/// Index into `GraphDiagram.nodes`.
pub const NodeId = u32;

/// A stack of text lines forming one section of a compartment node (e.g. a
/// class's attributes, or its methods).
pub const Compartment = []const []const u8;

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: NodeShape,
    /// When non-null, the node renders as a multi-section "card" (a header plus
    /// these compartments) instead of a simple shape — used by class/ER diagrams.
    compartments: ?[]const Compartment = null,
};

/// Rendered height in cells of a node, given its compartments. A plain node is a
/// 3-row box; a card is top border + header + (divider + rows) per compartment +
/// bottom border. Empty compartments still occupy one blank row. Shared by the
/// layout (to size nodes) and the renderer (to place dividers), so they agree.
pub fn cardHeight(node: Node) u32 {
    const comps = node.compartments orelse return 3;
    var h: u32 = 3; // top border + header + bottom border
    for (comps) |c| h += 1 + @max(@as(u32, 1), @as(u32, @intCast(c.len)));
    return h;
}

pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    label: ?[]const u8 = null,
    line: LineKind = .solid,
    arrow: ArrowKind = .arrow,
    /// Draw the endpoint decoration at the source (`from`) rather than the target.
    /// Class hierarchy/containment ends sit at the parent/whole, which layout
    /// places at the source so it ends up on top.
    head_at_source: bool = false,
    /// Short text rendered beside the source/target endpoints — e.g. ER
    /// cardinality (`1`, `0..N`). Null means no end annotation.
    from_end: ?[]const u8 = null,
    to_end: ?[]const u8 = null,
    /// Minimum rank distance the layout engine must place between endpoints.
    /// Authors lengthen an edge by adding dashes (`A ---> B`), which raises this.
    min_len: u8 = 1,
};

pub const GraphDiagram = struct {
    direction: Direction,
    nodes: []Node,
    edges: []Edge,
};
