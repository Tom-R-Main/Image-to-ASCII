//! Recursive-composite layout for graphs with boundary/group clusters.
//!
//! Each cluster is laid out as its own sub-graph (its direct member nodes plus
//! any nested child clusters, which are themselves composites), then boxed and
//! handed to the parent level as a single fixed-size super-node. The parent lays
//! out its loose nodes and child-cluster boxes together with the ordinary layered
//! engine, then this module blits each child's sub-layout into the interior of the
//! box the engine placed.
//!
//! Consequences, by construction:
//!   * No foreign node can land inside a cluster box (the box is opaque at the
//!     parent level; its contents are placed only in its interior afterwards).
//!   * Nesting works to any depth via the recursion.
//!   * An inter-cluster edge is lifted to the lowest common scope and routed to
//!     the cluster *box* face — it meets the border, not the exact inner node.
//!
//! The output is a plain `layered.Layout` (flattened, absolute coordinates) with
//! its `clusters` field populated, so the renderer treats it like any other graph
//! plus a list of boxes to draw.

const std = @import("std");
const ir = @import("../ir/graph.zig");
const layered = @import("layered.zig");
const text_measure = @import("../../canvas/text_measure.zig");

const Rect = layered.Rect;
const Point = layered.Point;
const LayoutError = layered.LayoutError;

/// One level's flattened result, in local coordinates with origin at (0,0).
const Composite = struct {
    width: u32,
    height: u32,
    nodes: []layered.LaidOutNode,
    clusters: []layered.LaidOutCluster,
    edges: []layered.RoutedEdge,
};

/// A vertex at one level: either a real node, or a child cluster (already laid
/// out into `child`).
const Vertex = union(enum) {
    node: ir.NodeId,
    cluster: struct { id: ir.ClusterId, child: Composite },
};

const Rep = union(enum) { node: ir.NodeId, cluster: ir.ClusterId };

pub fn layoutClustered(
    gpa: std.mem.Allocator,
    diagram: ir.GraphDiagram,
    options: layered.LayoutOptions,
) LayoutError!layered.Layout {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var ctx: Ctx = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .diagram = diagram,
        .options = options,
    };
    const root = try ctx.buildLevel(null);

    return .{
        .arena = arena_state,
        .columns = root.width,
        .rows = root.height,
        .nodes = root.nodes,
        .edges = root.edges,
        .clusters = root.clusters,
    };
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    diagram: ir.GraphDiagram,
    options: layered.LayoutOptions,

    /// Lay out everything whose direct scope is `scope` (null = the top level).
    fn buildLevel(self: *Ctx, scope: ?ir.ClusterId) LayoutError!Composite {
        var vertices: std.ArrayList(Vertex) = .empty;

        // Direct member nodes of this scope (node.cluster == scope).
        for (self.diagram.nodes, 0..) |node, i| {
            if (eqlOpt(node.cluster, scope)) try vertices.append(self.arena, .{ .node = @intCast(i) });
        }
        // Child clusters of this scope, each laid out recursively. Empty clusters
        // (no descendant nodes) are dropped rather than drawn as bare boxes.
        for (self.diagram.clusters, 0..) |cl, ci| {
            if (!eqlOpt(cl.parent, scope)) continue;
            const child = try self.buildLevel(@intCast(ci));
            if (child.nodes.len == 0) continue;
            try vertices.append(self.arena, .{ .cluster = .{ .id = @intCast(ci), .child = child } });
        }

        if (vertices.items.len == 0) {
            return .{ .width = 0, .height = 0, .nodes = &.{}, .clusters = &.{}, .edges = &.{} };
        }

        // Build the level graph: one Node per vertex, with size overrides for the
        // cluster super-nodes.
        const level_nodes = try self.arena.alloc(ir.Node, vertices.items.len);
        const overrides = try self.arena.alloc(?layered.Footprint, vertices.items.len);
        var node_to_level: std.AutoHashMapUnmanaged(ir.NodeId, usize) = .empty;
        var cluster_to_level: std.AutoHashMapUnmanaged(ir.ClusterId, usize) = .empty;

        for (vertices.items, 0..) |v, idx| {
            switch (v) {
                .node => |nid| {
                    const src = self.diagram.nodes[nid];
                    level_nodes[idx] = .{ .id = src.id, .label = src.label, .shape = src.shape, .compartments = src.compartments };
                    overrides[idx] = null;
                    try node_to_level.put(self.arena, nid, idx);
                },
                .cluster => |c| {
                    const cl = self.diagram.clusters[c.id];
                    const label_w = try text_measure.width(cl.label);
                    // Symmetric 1-cell side padding around the content; the label
                    // form needs corner, dash, space, <label>, space, …, corner.
                    const box_w = @max(c.child.width + 4, label_w + 5);
                    const box_h = c.child.height + 2;
                    level_nodes[idx] = .{ .id = cl.id, .label = "", .shape = .rect };
                    overrides[idx] = .{ .w = box_w, .h = box_h };
                    try cluster_to_level.put(self.arena, c.id, idx);
                },
            }
        }

        // Lift each global edge to this scope, if both endpoints resolve here.
        var level_edges: std.ArrayList(ir.Edge) = .empty;
        var level_edge_global: std.ArrayList(usize) = .empty;
        var seen: std.ArrayList([2]usize) = .empty; // dedup cluster-involving pairs
        for (self.diagram.edges, 0..) |e, gi| {
            const ru = self.repInScope(e.from, scope) orelse continue;
            const rv = self.repInScope(e.to, scope) orelse continue;
            const li = levelIndex(ru, node_to_level, cluster_to_level);
            const lj = levelIndex(rv, node_to_level, cluster_to_level);
            const involves_cluster = ru == .cluster or rv == .cluster;
            if (li == lj) {
                // Keep genuine same-node self-loops; drop within-child internal edges.
                if (e.from != e.to or ru != .node) continue;
            }
            if (involves_cluster and pairSeen(seen.items, li, lj)) continue;
            try level_edges.append(self.arena, .{
                .from = @intCast(li),
                .to = @intCast(lj),
                .label = e.label,
                .line = e.line,
                .arrow = e.arrow,
                .head_at_source = e.head_at_source,
                .from_end = e.from_end,
                .to_end = e.to_end,
                .min_len = e.min_len,
            });
            try level_edge_global.append(self.arena, gi);
            if (involves_cluster) try seen.append(self.arena, .{ li, lj });
        }

        const level_diagram: ir.GraphDiagram = .{
            .direction = self.diagram.direction,
            .nodes = level_nodes,
            .edges = try level_edges.toOwnedSlice(self.arena),
        };
        var sub = try layered.layoutLevel(self.gpa, level_diagram, self.options, overrides);
        defer sub.deinit();

        // Flatten the engine result into this composite (copying out of sub.arena).
        var out_nodes: std.ArrayList(layered.LaidOutNode) = .empty;
        var out_clusters: std.ArrayList(layered.LaidOutCluster) = .empty;
        var out_edges: std.ArrayList(layered.RoutedEdge) = .empty;

        for (sub.nodes) |ln| {
            switch (vertices.items[ln.node]) {
                .node => |nid| {
                    const src = self.diagram.nodes[nid];
                    try out_nodes.append(self.arena, .{
                        .node = nid,
                        .label = try self.arena.dupe(u8, src.label),
                        .shape = src.shape,
                        .rect = ln.rect,
                    });
                },
                .cluster => |c| {
                    const cl = self.diagram.clusters[c.id];
                    try out_clusters.append(self.arena, .{ .rect = ln.rect, .label = try self.arena.dupe(u8, cl.label) });
                    // Blit the child's content into this box's interior, with one
                    // cell of padding inside the left/right border.
                    const dx = ln.rect.x + 2;
                    const dy = ln.rect.y + 1;
                    for (c.child.nodes) |cn| {
                        try out_nodes.append(self.arena, .{ .node = cn.node, .label = cn.label, .shape = cn.shape, .rect = offsetRect(cn.rect, dx, dy) });
                    }
                    for (c.child.clusters) |cc| {
                        try out_clusters.append(self.arena, .{ .rect = offsetRect(cc.rect, dx, dy), .label = cc.label });
                    }
                    for (c.child.edges) |ce| {
                        try out_edges.append(self.arena, try self.copyEdge(ce, dx, dy, ce.edge_index));
                    }
                },
            }
        }

        // This level's own routed edges, remapped to global edge indices.
        for (sub.edges) |re| {
            const gi = level_edge_global.items[re.edge_index];
            try out_edges.append(self.arena, try self.copyEdge(re, 0, 0, gi));
        }

        return .{
            .width = sub.columns,
            .height = sub.rows,
            .nodes = try out_nodes.toOwnedSlice(self.arena),
            .clusters = try out_clusters.toOwnedSlice(self.arena),
            .edges = try out_edges.toOwnedSlice(self.arena),
        };
    }

    /// The representative of `node_id` among the direct members of `scope`:
    /// itself if it sits directly in `scope`, the child cluster of `scope` that
    /// contains it otherwise, or null if it is not within `scope` at all.
    fn repInScope(self: *Ctx, node_id: ir.NodeId, scope: ?ir.ClusterId) ?Rep {
        var cur = self.diagram.nodes[node_id].cluster;
        while (cur) |cid| {
            if (eqlOpt(self.diagram.clusters[cid].parent, scope)) return .{ .cluster = cid };
            cur = self.diagram.clusters[cid].parent;
        }
        if (eqlOpt(self.diagram.nodes[node_id].cluster, scope)) return .{ .node = node_id };
        return null;
    }

    /// Copy a routed edge into the arena, translated by (dx,dy), with a new index.
    fn copyEdge(self: *Ctx, re: layered.RoutedEdge, dx: i32, dy: i32, edge_index: usize) LayoutError!layered.RoutedEdge {
        const pts = try self.arena.alloc(Point, re.points.len);
        for (re.points, 0..) |p, i| pts[i] = .{ .x = p.x + dx, .y = p.y + dy };
        return .{
            .edge_index = edge_index,
            .points = pts,
            .line = re.line,
            .arrow = re.arrow,
            .label = if (re.label) |l| try self.arena.dupe(u8, l) else null,
            .label_at = if (re.label_at) |la| .{ .x = la.x + dx, .y = la.y + dy } else null,
        };
    }
};

fn eqlOpt(a: ?ir.ClusterId, b: ?ir.ClusterId) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn offsetRect(r: Rect, dx: i32, dy: i32) Rect {
    return .{ .x = r.x + dx, .y = r.y + dy, .width = r.width, .height = r.height };
}

fn levelIndex(
    rep: Rep,
    node_to_level: std.AutoHashMapUnmanaged(ir.NodeId, usize),
    cluster_to_level: std.AutoHashMapUnmanaged(ir.ClusterId, usize),
) usize {
    return switch (rep) {
        .node => |n| node_to_level.get(n).?,
        .cluster => |c| cluster_to_level.get(c).?,
    };
}

fn pairSeen(items: []const [2]usize, a: usize, b: usize) bool {
    for (items) |p| if (p[0] == a and p[1] == b) return true;
    return false;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "cluster box contains its members and nothing else" {
    // Two clusters of one node each, plus a loose node; one inter-cluster edge.
    var nodes = [_]ir.Node{
        .{ .id = "a", .label = "A", .shape = .rect, .cluster = 0 },
        .{ .id = "b", .label = "B", .shape = .rect, .cluster = 1 },
        .{ .id = "c", .label = "C", .shape = .rect, .cluster = null },
    };
    var edges = [_]ir.Edge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
    };
    const clusters = [_]ir.Cluster{
        .{ .id = "g0", .label = "Group Zero" },
        .{ .id = "g1", .label = "Group One" },
    };
    const diagram: ir.GraphDiagram = .{ .direction = .lr, .nodes = &nodes, .edges = &edges, .clusters = &clusters };

    var lay = try layoutClustered(testing.allocator, diagram, .{});
    defer lay.deinit();

    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
    try testing.expectEqual(@as(usize, 2), lay.clusters.len);

    // Each clustered node must sit strictly inside its cluster's box.
    for (lay.nodes) |n| {
        const src = diagram.nodes[n.node];
        if (src.cluster) |cid| {
            const want_label = clusters[cid].label;
            const box = findCluster(lay.clusters, want_label).?;
            try testing.expect(n.rect.x > box.rect.x);
            try testing.expect(n.rect.y > box.rect.y);
            try testing.expect(n.rect.x + @as(i32, @intCast(n.rect.width)) <= box.rect.x + @as(i32, @intCast(box.rect.width)));
            try testing.expect(n.rect.y + @as(i32, @intCast(n.rect.height)) <= box.rect.y + @as(i32, @intCast(box.rect.height)));
        }
    }

    // No node may sit inside a cluster box it doesn't belong to.
    for (lay.nodes) |n| {
        const src = diagram.nodes[n.node];
        for (lay.clusters) |box| {
            const inside = n.rect.x > box.rect.x and
                n.rect.x + @as(i32, @intCast(n.rect.width)) <= box.rect.x + @as(i32, @intCast(box.rect.width)) and
                n.rect.y > box.rect.y and
                n.rect.y + @as(i32, @intCast(n.rect.height)) <= box.rect.y + @as(i32, @intCast(box.rect.height));
            if (inside) {
                const owner = if (src.cluster) |cid| clusters[cid].label else "";
                try testing.expectEqualStrings(box.label, owner);
            }
        }
    }
}

test "nested clusters nest their boxes" {
    // outer { inner { a } , b }
    var nodes = [_]ir.Node{
        .{ .id = "a", .label = "A", .shape = .rect, .cluster = 1 }, // inner
        .{ .id = "b", .label = "B", .shape = .rect, .cluster = 0 }, // outer, loose
    };
    var edges = [_]ir.Edge{.{ .from = 0, .to = 1 }};
    const clusters = [_]ir.Cluster{
        .{ .id = "outer", .label = "Outer", .parent = null },
        .{ .id = "inner", .label = "Inner", .parent = 0 },
    };
    const diagram: ir.GraphDiagram = .{ .direction = .tb, .nodes = &nodes, .edges = &edges, .clusters = &clusters };

    var lay = try layoutClustered(testing.allocator, diagram, .{});
    defer lay.deinit();

    const outer = findCluster(lay.clusters, "Outer").?;
    const inner = findCluster(lay.clusters, "Inner").?;
    // Inner box is strictly within the outer box.
    try testing.expect(inner.rect.x > outer.rect.x);
    try testing.expect(inner.rect.y > outer.rect.y);
    try testing.expect(inner.rect.x + @as(i32, @intCast(inner.rect.width)) <= outer.rect.x + @as(i32, @intCast(outer.rect.width)));
    try testing.expect(inner.rect.y + @as(i32, @intCast(inner.rect.height)) <= outer.rect.y + @as(i32, @intCast(outer.rect.height)));
}

fn findCluster(clusters: []const layered.LaidOutCluster, label: []const u8) ?layered.LaidOutCluster {
    for (clusters) |c| if (std.mem.eql(u8, c.label, label)) return c;
    return null;
}
