//! Sugiyama-style layered layout for the graph IR.
//!
//! Pipeline:
//!   1. break cycles (DFS back-edges are marked reversed for ranking only),
//!   2. longest-path rank assignment honoring per-edge `min_len`,
//!   3. insert dummy nodes so every edge segment spans exactly one rank,
//!   4. order nodes within ranks with a median heuristic to reduce crossings,
//!   5. assign integer secondary coordinates (neighbor-mean, separation-safe),
//!   6. stack ranks along the primary axis and map to cell (col,row) per
//!      direction,
//!   7. route each edge as an orthogonal polyline through its dummy channel.
//!
//! Internally the layout always reasons in (primary = rank axis, secondary =
//! in-rank axis) space, then maps to screen cells based on `Direction`. This
//! keeps the four directions a single code path with a final transform.
//!
//! The result is overlap-free by construction: in-rank separation prevents
//! sibling collisions, rank bands prevent cross-rank collisions, and dummy
//! channels keep long edges out of node boxes. It is not crossing-optimal; the
//! goal is stable, compact, predictable output.

const std = @import("std");
const ir = @import("../ir/graph.zig");
const text_measure = @import("../../canvas/text_measure.zig");

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

pub const LayoutOptions = struct {
    /// Gap cells between rank bands (along the primary axis).
    rank_gap: u32 = 3,
    /// Gap cells between siblings (along the secondary axis).
    node_gap: u32 = 3,
    /// Horizontal padding inside a box on each side of its label.
    pad_x: u32 = 1,
    order_iterations: u8 = 4,
    coord_iterations: u8 = 8,
};

pub const LaidOutNode = struct {
    node: ir.NodeId,
    label: []const u8,
    shape: ir.NodeShape,
    rect: Rect,
};

pub const RoutedEdge = struct {
    edge_index: usize,
    points: []Point,
    line: ir.LineKind,
    arrow: ir.ArrowKind,
    label: ?[]const u8,
    label_at: ?Point,
};

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    columns: u32,
    rows: u32,
    nodes: []LaidOutNode,
    edges: []RoutedEdge,

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
    }
};

pub const LayoutError = error{ OutOfMemory, InvalidUtf8 };

const Axis = enum { down, up, right, left };

fn primaryAxis(dir: ir.Direction) Axis {
    return switch (dir) {
        .td, .tb => .down,
        .bt => .up,
        .lr => .right,
        .rl => .left,
    };
}

fn isVertical(dir: ir.Direction) bool {
    return !dir.isHorizontal();
}

const LKind = enum { real, dummy };

const LNode = struct {
    kind: LKind,
    real: ir.NodeId = 0,
    rank: u32 = 0,
    order: u32 = 0,
    /// Box footprint in cells (real nodes only; dummies are 1x1).
    w: u32 = 1,
    h: u32 = 1,
    /// Size along the secondary axis (depends on orientation).
    sec_size: u32 = 1,
    /// Size along the primary axis (depends on orientation).
    pri_size: u32 = 1,
    /// Center along the secondary axis, in cells.
    sec_center: i32 = 0,
    /// Top/left along the primary axis, in cells.
    pri_pos: i32 = 0,
    /// Final cell rect (after primary/secondary mapping and the global shift).
    rect: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    neighbors: std.ArrayList(usize) = .empty,
};

pub fn layoutFlowchart(
    gpa: std.mem.Allocator,
    diagram: ir.GraphDiagram,
    options: LayoutOptions,
) LayoutError!Layout {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var eng: Engine = .{
        .arena = arena,
        .scratch = scratch,
        .diagram = diagram,
        .options = options,
        .vertical = isVertical(diagram.direction),
        .axis = primaryAxis(diagram.direction),
    };

    const result = try eng.run();
    return .{
        .arena = arena_state,
        .columns = result.columns,
        .rows = result.rows,
        .nodes = result.nodes,
        .edges = result.edges,
    };
}

const Engine = struct {
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    diagram: ir.GraphDiagram,
    options: LayoutOptions,
    vertical: bool,
    axis: Axis,

    lnodes: std.ArrayList(LNode) = .empty,
    /// real node id -> lnode index (identity for the first N).
    rank_of: []u32 = &.{},
    /// Chain of lnode indices per edge, ordered from original `from` to `to`.
    chains: []std.ArrayList(usize) = &.{},
    /// Rank buckets of lnode indices.
    ranks: std.ArrayList(std.ArrayList(usize)) = .empty,
    max_rank: u32 = 0,

    const RunResult = struct {
        columns: u32,
        rows: u32,
        nodes: []LaidOutNode,
        edges: []RoutedEdge,
    };

    fn run(self: *Engine) LayoutError!RunResult {
        const n = self.diagram.nodes.len;
        if (n == 0) {
            return .{ .columns = 0, .rows = 0, .nodes = &.{}, .edges = &.{} };
        }

        const reversed = try self.breakCycles();
        try self.assignRanks(reversed);
        try self.lnodes.ensureTotalCapacity(self.arena, n + self.dummyCount());
        try self.buildLNodes();
        try self.buildChains();
        try self.bucketRanks();
        try self.orderRanks();
        try self.assignSecondary();
        self.assignPrimary();
        self.mapToCells();
        const edges = try self.routeEdges();
        const dims = self.shiftToOrigin(edges);
        const nodes = try self.collectNodes();

        return .{ .columns = dims.columns, .rows = dims.rows, .nodes = nodes, .edges = edges };
    }

    // -- cycle breaking -----------------------------------------------------

    fn breakCycles(self: *Engine) LayoutError![]bool {
        const n = self.diagram.nodes.len;
        const edges = self.diagram.edges;
        const reversed = try self.scratch.alloc(bool, edges.len);
        @memset(reversed, false);

        // 0 = white (unseen), 1 = gray (on stack), 2 = black (done).
        const color = try self.scratch.alloc(u2, n);
        @memset(color, 0);

        // out-edge index lists per node.
        var out = try self.scratch.alloc(std.ArrayList(usize), n);
        for (out) |*o| o.* = .empty;
        for (edges, 0..) |e, i| {
            if (e.from == e.to) continue; // self-loop: never part of ranking.
            try out[e.from].append(self.scratch, i);
        }

        for (0..n) |start| {
            if (color[start] != 0) continue;
            try self.dfsBreak(@intCast(start), out, color, reversed);
        }
        return reversed;
    }

    fn dfsBreak(self: *Engine, u: u32, out: []std.ArrayList(usize), color: []u2, reversed: []bool) LayoutError!void {
        color[u] = 1;
        for (out[u].items) |ei| {
            const v = self.diagram.edges[ei].to;
            switch (color[v]) {
                0 => try self.dfsBreak(v, out, color, reversed),
                1 => reversed[ei] = true, // back edge -> reverse for ranking
                else => {},
            }
        }
        color[u] = 2;
    }

    // -- ranking ------------------------------------------------------------

    fn assignRanks(self: *Engine, reversed: []bool) LayoutError!void {
        const n = self.diagram.nodes.len;
        const edges = self.diagram.edges;

        // DAG edges as (a -> b) with rank[b] >= rank[a] + min_len.
        const DagEdge = struct { a: u32, b: u32, len: u8 };
        var dag = try self.scratch.alloc(std.ArrayList(DagEdge), n);
        for (dag) |*d| d.* = .empty;
        const indeg = try self.scratch.alloc(u32, n);
        @memset(indeg, 0);

        for (edges, 0..) |e, i| {
            if (e.from == e.to) continue;
            const a = if (reversed[i]) e.to else e.from;
            const b = if (reversed[i]) e.from else e.to;
            try dag[a].append(self.scratch, .{ .a = a, .b = b, .len = e.min_len });
            indeg[b] += 1;
        }

        self.rank_of = try self.arena.alloc(u32, n);
        @memset(self.rank_of, 0);

        // Kahn topological order; seed sources in node-id order for determinism.
        var queue = try self.scratch.alloc(u32, n);
        var head: usize = 0;
        var tail: usize = 0;
        for (0..n) |i| {
            if (indeg[i] == 0) {
                queue[tail] = @intCast(i);
                tail += 1;
            }
        }
        while (head < tail) {
            const u = queue[head];
            head += 1;
            for (dag[u].items) |de| {
                const cand = self.rank_of[u] + de.len;
                if (cand > self.rank_of[de.b]) self.rank_of[de.b] = cand;
                indeg[de.b] -= 1;
                if (indeg[de.b] == 0) {
                    queue[tail] = de.b;
                    tail += 1;
                }
            }
        }

        var maxr: u32 = 0;
        for (self.rank_of) |r| maxr = @max(maxr, r);
        self.max_rank = maxr;
    }

    fn dummyCount(self: *Engine) usize {
        var count: usize = 0;
        for (self.diagram.edges) |e| {
            if (e.from == e.to) continue;
            const a = self.rank_of[e.from];
            const b = self.rank_of[e.to];
            const span = if (a > b) a - b else b - a;
            if (span > 1) count += span - 1;
        }
        return count;
    }

    // -- layout nodes -------------------------------------------------------

    fn buildLNodes(self: *Engine) LayoutError!void {
        for (self.diagram.nodes, 0..) |node, i| {
            const label_w = try text_measure.width(node.label);
            const w = label_w + 2 + 2 * self.options.pad_x;
            const h: u32 = 3;
            const sec: u32 = if (self.vertical) w else h;
            const pri: u32 = if (self.vertical) h else w;
            try self.lnodes.append(self.arena, .{
                .kind = .real,
                .real = @intCast(i),
                .rank = self.rank_of[i],
                .w = w,
                .h = h,
                .sec_size = sec,
                .pri_size = pri,
            });
        }
    }

    fn addDummy(self: *Engine, rank: u32) LayoutError!usize {
        const idx = self.lnodes.items.len;
        try self.lnodes.append(self.arena, .{
            .kind = .dummy,
            .rank = rank,
            .w = 1,
            .h = 1,
            .sec_size = 1,
            .pri_size = 1,
        });
        return idx;
    }

    fn buildChains(self: *Engine) LayoutError!void {
        const edges = self.diagram.edges;
        self.chains = try self.arena.alloc(std.ArrayList(usize), edges.len);
        for (self.chains) |*c| c.* = .empty;

        for (edges, 0..) |e, i| {
            if (e.from == e.to) continue; // self-loops handled at routing time.
            const r0: i64 = self.rank_of[e.from];
            const r1: i64 = self.rank_of[e.to];
            const span: usize = @intCast(if (r0 > r1) r0 - r1 else r1 - r0);
            try self.chains[i].ensureTotalCapacity(self.arena, span + 1);
            self.chains[i].appendAssumeCapacity(e.from);
            if (r1 != r0) {
                const step: i64 = if (r1 > r0) 1 else -1;
                var r = r0 + step;
                while (r != r1) : (r += step) {
                    const d = try self.addDummy(@intCast(r));
                    self.chains[i].appendAssumeCapacity(d);
                }
            }
            self.chains[i].appendAssumeCapacity(e.to);
        }

        // Record adjacency between consecutive chain members (one rank apart).
        for (self.chains) |chain| {
            if (chain.items.len < 2) continue;
            var k: usize = 1;
            while (k < chain.items.len) : (k += 1) {
                const a = chain.items[k - 1];
                const b = chain.items[k];
                if (self.lnodes.items[a].rank == self.lnodes.items[b].rank) continue;
                try self.lnodes.items[a].neighbors.append(self.arena, b);
                try self.lnodes.items[b].neighbors.append(self.arena, a);
            }
        }
    }

    // -- ordering -----------------------------------------------------------

    fn bucketRanks(self: *Engine) LayoutError!void {
        try self.ranks.resize(self.arena, self.max_rank + 1);
        for (self.ranks.items) |*r| r.* = .empty;
        const rank_counts = try self.scratch.alloc(usize, self.ranks.items.len);
        @memset(rank_counts, 0);
        for (self.lnodes.items) |ln| {
            rank_counts[ln.rank] += 1;
        }
        for (self.ranks.items, 0..) |*bucket, i| {
            try bucket.ensureTotalCapacity(self.arena, rank_counts[i]);
        }
        for (self.lnodes.items, 0..) |ln, i| {
            self.ranks.items[ln.rank].appendAssumeCapacity(i);
        }
        self.reindexOrders();
    }

    fn reindexOrders(self: *Engine) void {
        for (self.ranks.items) |bucket| {
            for (bucket.items, 0..) |li, pos| {
                self.lnodes.items[li].order = @intCast(pos);
            }
        }
    }

    fn orderRanks(self: *Engine) LayoutError!void {
        var iter: u8 = 0;
        while (iter < self.options.order_iterations) : (iter += 1) {
            const down = (iter % 2 == 0);
            try self.medianSweep(down);
            self.reindexOrders();
        }
    }

    fn medianSweep(self: *Engine, down: bool) LayoutError!void {
        const count = self.ranks.items.len;
        var ri: usize = 0;
        while (ri < count) : (ri += 1) {
            // Down sweep fixes rank 0 and uses upper neighbors; up sweep fixes
            // the last rank and uses lower neighbors.
            const r = if (down) ri else count - 1 - ri;
            if (down and r == 0) continue;
            if (!down and r == count - 1) continue;
            const from_rank: u32 = if (down) @intCast(r - 1) else @intCast(r + 1);

            const bucket = self.ranks.items[r];
            const keys = try self.scratch.alloc(f64, bucket.items.len);
            for (bucket.items, 0..) |li, k| {
                keys[k] = self.medianKey(li, from_rank, @intCast(k));
            }
            sortByKey(bucket.items, keys);
        }
    }

    fn medianKey(self: *Engine, li: usize, from_rank: u32, fallback_pos: u32) f64 {
        const ln = self.lnodes.items[li];
        var positions = std.ArrayList(u32).empty;
        defer positions.deinit(self.scratch);
        for (ln.neighbors.items) |nb| {
            if (self.lnodes.items[nb].rank == from_rank) {
                positions.append(self.scratch, self.lnodes.items[nb].order) catch return @floatFromInt(fallback_pos);
            }
        }
        if (positions.items.len == 0) return @floatFromInt(fallback_pos);
        std.mem.sort(u32, positions.items, {}, std.sort.asc(u32));
        const m = positions.items.len;
        if (m % 2 == 1) return @floatFromInt(positions.items[m / 2]);
        const lo = positions.items[m / 2 - 1];
        const hi = positions.items[m / 2];
        return (@as(f64, @floatFromInt(lo)) + @as(f64, @floatFromInt(hi))) / 2.0;
    }

    // -- secondary coordinates ---------------------------------------------

    fn sep(self: *Engine, a: usize, b: usize) i32 {
        const sa: i32 = @intCast(self.lnodes.items[a].sec_size);
        const sb: i32 = @intCast(self.lnodes.items[b].sec_size);
        return @divTrunc(sa, 2) + @as(i32, @intCast(self.options.node_gap)) + @divTrunc(sb, 2);
    }

    fn assignSecondary(self: *Engine) LayoutError!void {
        // Initial packing per rank.
        for (self.ranks.items) |bucket| {
            var prev: ?usize = null;
            var cursor: i32 = 0;
            for (bucket.items) |li| {
                if (prev) |p| {
                    cursor += self.sep(p, li);
                } else {
                    cursor = @divTrunc(@as(i32, @intCast(self.lnodes.items[li].sec_size)), 2);
                }
                self.lnodes.items[li].sec_center = cursor;
                prev = li;
            }
        }

        // Relax toward neighbor means, keeping separation via a forward pass.
        var iter: u8 = 0;
        while (iter < self.options.coord_iterations) : (iter += 1) {
            for (self.ranks.items) |bucket| {
                var prev: ?usize = null;
                for (bucket.items) |li| {
                    const desired = self.desiredCenter(li);
                    var c = desired;
                    if (prev) |p| {
                        const min_c = self.lnodes.items[p].sec_center + self.sep(p, li);
                        if (c < min_c) c = min_c;
                    }
                    self.lnodes.items[li].sec_center = c;
                    prev = li;
                }
            }
        }
    }

    fn desiredCenter(self: *Engine, li: usize) i32 {
        const ln = self.lnodes.items[li];
        if (ln.neighbors.items.len == 0) return ln.sec_center;
        var sum: i64 = 0;
        for (ln.neighbors.items) |nb| sum += self.lnodes.items[nb].sec_center;
        return @intCast(@divTrunc(sum, @as(i64, @intCast(ln.neighbors.items.len))));
    }

    // -- primary coordinates ------------------------------------------------

    fn assignPrimary(self: *Engine) void {
        var cursor: i32 = 0;
        for (self.ranks.items) |bucket| {
            var band: u32 = 1;
            for (bucket.items) |li| band = @max(band, self.lnodes.items[li].pri_size);
            for (bucket.items) |li| {
                const ln = &self.lnodes.items[li];
                const slack: i32 = @intCast((band - ln.pri_size) / 2);
                ln.pri_pos = cursor + slack;
            }
            cursor += @as(i32, @intCast(band)) + @as(i32, @intCast(self.options.rank_gap));
        }
    }

    // -- map (primary,secondary) -> (col,row) -------------------------------

    fn mapToCells(self: *Engine) void {
        // Total primary extent for flipped directions (bt/rl).
        var total_pri: i32 = 0;
        for (self.lnodes.items) |ln| {
            total_pri = @max(total_pri, ln.pri_pos + @as(i32, @intCast(ln.pri_size)));
        }

        for (self.lnodes.items) |*ln| {
            const sec_left = ln.sec_center - @divTrunc(@as(i32, @intCast(ln.sec_size)), 2);
            const pri_top = ln.pri_pos;
            const pri_flipped = total_pri - pri_top - @as(i32, @intCast(ln.pri_size));
            switch (self.diagram.direction) {
                .td, .tb => ln.rect = .{ .x = sec_left, .y = pri_top, .width = ln.w, .height = ln.h },
                .bt => ln.rect = .{ .x = sec_left, .y = pri_flipped, .width = ln.w, .height = ln.h },
                .lr => ln.rect = .{ .x = pri_top, .y = sec_left, .width = ln.w, .height = ln.h },
                .rl => ln.rect = .{ .x = pri_flipped, .y = sec_left, .width = ln.w, .height = ln.h },
            }
        }
    }

    // -- routing ------------------------------------------------------------

    fn routeEdges(self: *Engine) LayoutError![]RoutedEdge {
        var out = std.ArrayList(RoutedEdge).empty;
        try out.ensureTotalCapacity(self.arena, self.diagram.edges.len);
        for (self.diagram.edges, 0..) |e, i| {
            if (e.from == e.to) {
                out.appendAssumeCapacity(try self.routeSelfLoop(i, e));
                continue;
            }
            out.appendAssumeCapacity(try self.routeChain(i, e));
        }
        return out.toOwnedSlice(self.arena);
    }

    fn routeChain(self: *Engine, edge_index: usize, e: ir.Edge) LayoutError!RoutedEdge {
        const chain = self.chains[edge_index].items;
        var pts = std.ArrayList(Point).empty;
        try pts.ensureTotalCapacity(self.arena, chain.len * 4);

        var k: usize = 1;
        while (k < chain.len) : (k += 1) {
            const cur = chain[k - 1];
            const next = chain[k];
            const forward = self.lnodes.items[next].rank > self.lnodes.items[cur].rank;
            const a = self.endpoint(cur, forward, true);
            const b = self.endpoint(next, forward, false);
            try self.appendSegment(&pts, a, b);
        }

        const points = try pts.toOwnedSlice(self.arena);
        return .{
            .edge_index = edge_index,
            .points = points,
            .line = e.line,
            .arrow = e.arrow,
            .label = if (e.label) |l| try self.arena.dupe(u8, l) else null,
            .label_at = midpoint(points),
        };
    }

    /// Exit/entry point of a chain member. `leaving` selects exit vs entry; for
    /// real nodes the face depends on travel direction, dummies use their center.
    fn endpoint(self: *Engine, li: usize, forward: bool, leaving: bool) Point {
        const ln = self.lnodes.items[li];
        if (ln.kind == .dummy) {
            return .{ .x = ln.rect.x, .y = ln.rect.y };
        }
        // Travel-forward exit uses the forward face; travel-forward entry uses
        // the backward face. Reversed travel swaps these.
        const use_forward_face = if (leaving) forward else !forward;
        return self.face(ln.rect, use_forward_face);
    }

    fn face(self: *Engine, rect: Rect, forward_face: bool) Point {
        const cx = rect.x + @divTrunc(@as(i32, @intCast(rect.width)), 2);
        const cy = rect.y + @divTrunc(@as(i32, @intCast(rect.height)), 2);
        const w: i32 = @intCast(rect.width);
        const h: i32 = @intCast(rect.height);
        return switch (self.axis) {
            .down => if (forward_face) .{ .x = cx, .y = rect.y + h } else .{ .x = cx, .y = rect.y - 1 },
            .up => if (forward_face) .{ .x = cx, .y = rect.y - 1 } else .{ .x = cx, .y = rect.y + h },
            .right => if (forward_face) .{ .x = rect.x + w, .y = cy } else .{ .x = rect.x - 1, .y = cy },
            .left => if (forward_face) .{ .x = rect.x - 1, .y = cy } else .{ .x = rect.x + w, .y = cy },
        };
    }

    fn appendSegment(self: *Engine, pts: *std.ArrayList(Point), a: Point, b: Point) LayoutError!void {
        try pushPoint(self.arena, pts, a);
        if (self.vertical) {
            const mid = @divTrunc(a.y + b.y, 2);
            try pushPoint(self.arena, pts, .{ .x = a.x, .y = mid });
            try pushPoint(self.arena, pts, .{ .x = b.x, .y = mid });
        } else {
            const mid = @divTrunc(a.x + b.x, 2);
            try pushPoint(self.arena, pts, .{ .x = mid, .y = a.y });
            try pushPoint(self.arena, pts, .{ .x = mid, .y = b.y });
        }
        try pushPoint(self.arena, pts, b);
    }

    fn routeSelfLoop(self: *Engine, edge_index: usize, e: ir.Edge) LayoutError!RoutedEdge {
        const ln = self.lnodes.items[e.from];
        const r = ln.rect;
        const right: i32 = r.x + @as(i32, @intCast(r.width));
        const bottom_row: i32 = r.y + @as(i32, @intCast(r.height)) - 1;
        const below: i32 = r.y + @as(i32, @intCast(r.height));
        const cx = r.x + @divTrunc(@as(i32, @intCast(r.width)), 2);

        var pts = std.ArrayList(Point).empty;
        try pts.ensureTotalCapacity(self.arena, 4);
        try pushPoint(self.arena, &pts, .{ .x = right - 1, .y = bottom_row });
        try pushPoint(self.arena, &pts, .{ .x = right, .y = bottom_row });
        try pushPoint(self.arena, &pts, .{ .x = right, .y = below });
        try pushPoint(self.arena, &pts, .{ .x = cx, .y = below });
        const points = try pts.toOwnedSlice(self.arena);
        return .{
            .edge_index = edge_index,
            .points = points,
            .line = e.line,
            .arrow = e.arrow,
            .label = if (e.label) |l| try self.arena.dupe(u8, l) else null,
            .label_at = null,
        };
    }

    // -- finalize -----------------------------------------------------------

    fn shiftToOrigin(self: *Engine, edges: []RoutedEdge) struct { columns: u32, rows: u32 } {
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);

        for (self.lnodes.items) |ln| {
            if (ln.kind != .real) continue;
            min_x = @min(min_x, ln.rect.x);
            min_y = @min(min_y, ln.rect.y);
            max_x = @max(max_x, ln.rect.x + @as(i32, @intCast(ln.rect.width)) - 1);
            max_y = @max(max_y, ln.rect.y + @as(i32, @intCast(ln.rect.height)) - 1);
        }
        for (edges) |re| {
            for (re.points) |p| {
                min_x = @min(min_x, p.x);
                min_y = @min(min_y, p.y);
                max_x = @max(max_x, p.x);
                max_y = @max(max_y, p.y);
            }
        }

        const dx = -min_x;
        const dy = -min_y;
        for (self.lnodes.items) |*ln| {
            ln.rect.x += dx;
            ln.rect.y += dy;
        }
        for (edges) |*re| {
            for (re.points) |*p| {
                p.x += dx;
                p.y += dy;
            }
            if (re.label_at) |*la| {
                la.x += dx;
                la.y += dy;
            }
        }

        return .{
            .columns = @intCast(max_x - min_x + 1),
            .rows = @intCast(max_y - min_y + 1),
        };
    }

    fn collectNodes(self: *Engine) LayoutError![]LaidOutNode {
        var out = std.ArrayList(LaidOutNode).empty;
        try out.ensureTotalCapacity(self.arena, self.diagram.nodes.len);
        for (self.lnodes.items) |ln| {
            if (ln.kind != .real) continue;
            const node = self.diagram.nodes[ln.real];
            out.appendAssumeCapacity(.{
                .node = ln.real,
                .label = try self.arena.dupe(u8, node.label),
                .shape = node.shape,
                .rect = ln.rect,
            });
        }
        return out.toOwnedSlice(self.arena);
    }
};

// -- helpers ----------------------------------------------------------------

fn pushPoint(allocator: std.mem.Allocator, pts: *std.ArrayList(Point), p: Point) !void {
    if (pts.items.len > 0) {
        const last = pts.items[pts.items.len - 1];
        if (last.x == p.x and last.y == p.y) return;
    }
    try pts.append(allocator, p);
}

fn midpoint(points: []const Point) ?Point {
    if (points.len == 0) return null;
    return points[points.len / 2];
}

/// Stable insertion sort of `items` by parallel `keys` (small ranks; stability
/// preserves prior order for equal keys, which keeps layout deterministic).
fn sortByKey(items: []usize, keys: []f64) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const item = items[i];
        const key = keys[i];
        var j = i;
        while (j > 0 and keys[j - 1] > key) : (j -= 1) {
            items[j] = items[j - 1];
            keys[j] = keys[j - 1];
        }
        items[j] = item;
        keys[j] = key;
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const flowchart = @import("../mermaid/flowchart.zig");

fn layoutSource(src: []const u8) !struct { parse: flowchart.FlowchartResult, layout: Layout } {
    var diag: ?flowchart.MermaidError = null;
    var parse = try flowchart.parseFlowchart(testing.allocator, src, &diag);
    errdefer parse.deinit();
    const lay = try layoutFlowchart(testing.allocator, parse.diagram, .{});
    return .{ .parse = parse, .layout = lay };
}

test "lays out a simple chain without overlap" {
    var r = try layoutSource("flowchart TD\n A --> B --> C\n");
    defer r.parse.deinit();
    defer r.layout.deinit();

    try testing.expectEqual(@as(usize, 3), r.layout.nodes.len);
    // Top-down: each successive node sits on a lower row band.
    var prev_bottom: i32 = -1;
    for (r.layout.nodes) |node| {
        try testing.expect(node.rect.y > prev_bottom);
        prev_bottom = node.rect.y + @as(i32, @intCast(node.rect.height)) - 1;
    }
}

test "horizontal layout advances along columns" {
    var r = try layoutSource("flowchart LR\n A --> B\n");
    defer r.parse.deinit();
    defer r.layout.deinit();

    const a = r.layout.nodes[0].rect;
    const b = r.layout.nodes[1].rect;
    try testing.expect(b.x > a.x + @as(i32, @intCast(a.width)) - 1);
    try testing.expectEqual(a.y, b.y); // same lane
}

test "node boxes never overlap" {
    var r = try layoutSource(
        \\flowchart TD
        \\    A --> B
        \\    A --> C
        \\    B --> D
        \\    C --> D
    );
    defer r.parse.deinit();
    defer r.layout.deinit();

    const nodes = r.layout.nodes;
    for (nodes, 0..) |p, i| {
        for (nodes[i + 1 ..]) |q| {
            const disjoint = p.rect.x + @as(i32, @intCast(p.rect.width)) <= q.rect.x or
                q.rect.x + @as(i32, @intCast(q.rect.width)) <= p.rect.x or
                p.rect.y + @as(i32, @intCast(p.rect.height)) <= q.rect.y or
                q.rect.y + @as(i32, @intCast(q.rect.height)) <= p.rect.y;
            try testing.expect(disjoint);
        }
    }
}

test "multi-rank edge is routed and stays in bounds" {
    var r = try layoutSource("flowchart TD\n A --> B\n A --> C\n B --> C\n");
    defer r.parse.deinit();
    defer r.layout.deinit();

    try testing.expectEqual(@as(usize, 3), r.layout.edges.len);
    for (r.layout.edges) |e| {
        try testing.expect(e.points.len >= 2);
        for (e.points) |p| {
            try testing.expect(p.x >= 0 and p.x < @as(i32, @intCast(r.layout.columns)));
            try testing.expect(p.y >= 0 and p.y < @as(i32, @intCast(r.layout.rows)));
        }
    }
}

test "cycles do not hang ranking" {
    var r = try layoutSource("flowchart LR\n A --> B\n B --> C\n C --> A\n");
    defer r.parse.deinit();
    defer r.layout.deinit();
    try testing.expectEqual(@as(usize, 3), r.layout.nodes.len);
    try testing.expectEqual(@as(usize, 3), r.layout.edges.len);
}

test "empty graph yields empty layout" {
    var diag: ?flowchart.MermaidError = null;
    var parse = try flowchart.parseFlowchart(testing.allocator, "flowchart TD\n", &diag);
    defer parse.deinit();
    var lay = try layoutFlowchart(testing.allocator, parse.diagram, .{});
    defer lay.deinit();
    try testing.expectEqual(@as(usize, 0), lay.nodes.len);
    try testing.expectEqual(@as(u32, 0), lay.columns);
}
