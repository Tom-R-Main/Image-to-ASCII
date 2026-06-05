//! Line-based parser for the Mermaid state-diagram subset. State diagrams are a
//! graph-layout diagram, so this frontend lowers directly to the shared graph IR
//! (`ir/graph.zig`) and reuses the layered layout and graph renderer — there is
//! no separate state layout or renderer.
//!
//! Supported subset (v0):
//!   header:       `stateDiagram` / `stateDiagram-v2`
//!   direction:    `direction TB|TD|LR|RL|BT`
//!   start/end:    `[*]` (renders as a small circle)
//!   transitions:  `A --> B`, `A --> B : label`
//!   descriptions: `S : long label`
//!   declarations: `state Name`
//!   comments:     `%% ...`
//!
//! States render as rounded nodes; `[*]` as a circle. Composite states, choice,
//! fork/join, and notes are not yet supported. Syntax errors return
//! `error.MermaidSyntax` with a `MermaidError`. The result owns an arena.

const std = @import("std");
const graph = @import("../ir/graph.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const StateResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: graph.GraphDiagram,

    pub fn deinit(self: *StateResult) void {
        self.arena.deinit();
    }
};

pub fn parseState(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!StateResult {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);

    return .{ .arena = arena_state, .diagram = diagram };
}

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    direction: graph.Direction = .tb,
    nodes: std.ArrayList(graph.Node) = .empty,
    edges: std.ArrayList(graph.Edge) = .empty,
    index: std.StringHashMapUnmanaged(graph.NodeId) = .empty,
    start_id: ?graph.NodeId = null,
    end_id: ?graph.NodeId = null,

    fn run(self: *Parser, source: []const u8) ParseError!graph.GraphDiagram {
        var line_no: u32 = 0;
        var seen_header = false;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |raw| {
            line_no += 1;
            const line = stripComment(raw);
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            if (!seen_header) {
                if (!std.mem.eql(u8, trimmed, "stateDiagram") and !std.mem.eql(u8, trimmed, "stateDiagram-v2")) {
                    return self.fail(.missing_header, line_no, 1, "expected 'stateDiagram' or 'stateDiagram-v2' header");
                }
                seen_header = true;
                continue;
            }

            try self.parseStatement(trimmed, line_no);
        }

        if (!seen_header) return self.fail(.missing_header, 1, 1, "expected 'stateDiagram' header");

        return .{
            .direction = self.direction,
            .nodes = try self.nodes.toOwnedSlice(self.arena),
            .edges = try self.edges.toOwnedSlice(self.arena),
        };
    }

    fn parseStatement(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        if (std.mem.indexOf(u8, line, "-->")) |arrow_pos| {
            return self.parseTransition(line, arrow_pos, line_no);
        }

        const first = firstWord(line);
        if (std.mem.eql(u8, first, "direction")) {
            const dir = std.mem.trim(u8, line[first.len..], " \t\r");
            self.direction = parseDirection(dir) orelse
                return self.fail(.invalid_direction, line_no, 1, "expected a direction: TB, TD, LR, RL, or BT");
            return;
        }
        if (std.mem.eql(u8, first, "state")) {
            const name = firstWord(line[first.len..]);
            if (name.len == 0) return self.fail(.expected_node, line_no, 1, "expected a state name after 'state'");
            _ = try self.upsertState(name, line_no);
            return;
        }

        // `S : description` sets a state's label.
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const id = std.mem.trim(u8, line[0..colon], " \t\r");
            const desc = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
            const nid = try self.upsertState(id, line_no);
            self.nodes.items[nid].label = try self.arena.dupe(u8, desc);
            return;
        }

        // A bare state id on its own line just declares it.
        _ = try self.upsertState(line, line_no);
    }

    fn parseTransition(self: *Parser, line: []const u8, arrow_pos: usize, line_no: u32) ParseError!void {
        const left = std.mem.trim(u8, line[0..arrow_pos], " \t\r");
        var rest = std.mem.trim(u8, line[arrow_pos + 3 ..], " \t\r");

        var label: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
            label = std.mem.trim(u8, rest[colon + 1 ..], " \t\r");
            rest = std.mem.trim(u8, rest[0..colon], " \t\r");
        }

        if (left.len == 0 or rest.len == 0) {
            return self.fail(.expected_node, line_no, 1, "a transition needs a state on each side of '-->'");
        }

        // `[*]` on the left is the initial pseudo-state; on the right, a final
        // one. Keeping them distinct makes start → … → end a DAG, not a cycle.
        const from = if (std.mem.eql(u8, left, "[*]")) try self.startNode() else try self.upsertState(left, line_no);
        const to = if (std.mem.eql(u8, rest, "[*]")) try self.endNode() else try self.upsertState(rest, line_no);
        try self.edges.append(self.arena, .{
            .from = from,
            .to = to,
            .label = if (label) |l| try self.arena.dupe(u8, l) else null,
            .line = .solid,
            .arrow = .arrow,
        });
    }

    fn startNode(self: *Parser) ParseError!graph.NodeId {
        if (self.start_id) |id| return id;
        const id = try self.addNode("[*]start", "*", .circle);
        self.start_id = id;
        return id;
    }

    fn endNode(self: *Parser) ParseError!graph.NodeId {
        if (self.end_id) |id| return id;
        const id = try self.addNode("[*]end", "*", .circle);
        self.end_id = id;
        return id;
    }

    /// Resolve a named state to a node id, creating it on first use. A bare `[*]`
    /// outside a transition defaults to the start pseudo-state.
    fn upsertState(self: *Parser, name: []const u8, line_no: u32) ParseError!graph.NodeId {
        if (std.mem.eql(u8, name, "[*]")) return self.startNode();
        if (name.len == 0) return self.fail(.expected_node, line_no, 1, "expected a state name");

        const gop = try self.index.getOrPut(self.arena, name);
        if (gop.found_existing) return gop.value_ptr.*;

        const owned = try self.arena.dupe(u8, name);
        gop.key_ptr.* = owned;
        const id = try self.addNode(owned, owned, .round);
        gop.value_ptr.* = id;
        return id;
    }

    fn addNode(self: *Parser, id: []const u8, label: []const u8, shape: graph.NodeShape) ParseError!graph.NodeId {
        const nid: graph.NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena, .{
            .id = try self.arena.dupe(u8, id),
            .label = try self.arena.dupe(u8, label),
            .shape = shape,
        });
        return nid;
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }
};

fn parseDirection(s: []const u8) ?graph.Direction {
    if (eqlIgnoreCase(s, "TB") or eqlIgnoreCase(s, "TD")) return .tb;
    if (eqlIgnoreCase(s, "LR")) return .lr;
    if (eqlIgnoreCase(s, "RL")) return .rl;
    if (eqlIgnoreCase(s, "BT")) return .bt;
    return null;
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "%%")) |pos| return line[0..pos];
    return line;
}

fn firstWord(s: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t\r");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != '\r') : (end += 1) {}
    return trimmed[0..end];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(source: []const u8) !StateResult {
    var diag: ?MermaidError = null;
    return parseState(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses states, transitions, and labels" {
    var r = try parseForTest(
        \\stateDiagram-v2
        \\    [*] --> Still
        \\    Still --> Moving : go
        \\    Moving --> Still : stop
        \\    Moving --> [*]
    );
    defer r.deinit();

    // Still, Moving, plus separate start and end pseudo-states.
    try testing.expectEqual(@as(usize, 4), r.diagram.nodes.len);
    try testing.expectEqual(@as(usize, 4), r.diagram.edges.len);

    // The [*] start node is a circle; real states are rounded.
    try testing.expectEqual(graph.NodeShape.circle, r.diagram.nodes[0].shape);
    try testing.expectEqual(graph.NodeShape.round, r.diagram.nodes[1].shape);
    try testing.expectEqualStrings("go", r.diagram.edges[1].label.?);
}

test "state description sets the label" {
    var r = try parseForTest(
        \\stateDiagram-v2
        \\    s1 : Idle state
        \\    s1 --> s2
    );
    defer r.deinit();
    try testing.expectEqualStrings("Idle state", r.diagram.nodes[0].label);
}

test "direction is honored" {
    var r = try parseForTest("stateDiagram-v2\n direction LR\n A --> B\n");
    defer r.deinit();
    try testing.expectEqual(graph.Direction.lr, r.diagram.direction);
}

test "start and end pseudo-states are distinct so start..end is acyclic" {
    var r = try parseForTest(
        \\stateDiagram-v2
        \\    [*] --> A
        \\    A --> [*]
    );
    defer r.deinit();
    var circles: usize = 0;
    for (r.diagram.nodes) |n| {
        if (n.shape == .circle) circles += 1;
    }
    try testing.expectEqual(@as(usize, 2), circles); // one start, one end
    // start -> A and A -> end, no edge back to the start node.
    try testing.expect(r.diagram.edges[1].to != r.diagram.edges[0].from);
}

test "rejects a missing header" {
    var diag: ?MermaidError = null;
    const r = parseState(testing.allocator, "A --> B\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
}

test "reports a dangling transition" {
    var diag: ?MermaidError = null;
    const r = parseState(testing.allocator, "stateDiagram-v2\n A -->\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.expected_node, diag.?.kind);
}
