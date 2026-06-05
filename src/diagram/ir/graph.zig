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

/// Endpoint decoration at the edge's head.
pub const ArrowKind = enum {
    none,
    arrow,
    circle,
    cross,
};

/// Index into `GraphDiagram.nodes`.
pub const NodeId = u32;

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: NodeShape,
};

pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    label: ?[]const u8 = null,
    line: LineKind = .solid,
    arrow: ArrowKind = .arrow,
    /// Minimum rank distance the layout engine must place between endpoints.
    /// Authors lengthen an edge by adding dashes (`A ---> B`), which raises this.
    min_len: u8 = 1,
};

pub const GraphDiagram = struct {
    direction: Direction,
    nodes: []Node,
    edges: []Edge,
};
