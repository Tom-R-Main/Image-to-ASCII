//! Recursive-descent parser for the Mermaid flowchart subset, producing the
//! graph IR in `ir/graph.zig`. This is one input frontend; the IR, layout, and
//! renderer never see Mermaid syntax.
//!
//! Supported subset (v0):
//!   header:      `flowchart`/`graph` with optional direction TD|TB|LR|RL|BT
//!   nodes:       `A`, `A[rect]`, `A(round)`, `A((circle))`, `A{diamond}`
//!   labels:      bracket bodies and quoted strings (`A["two words"]`)
//!   edges:       `-->` `---` `-.->` `==>` and circle/cross ends `--o` `--x`
//!   chains:      `A --> B --> C`
//!   edge labels: `A -->|label| B`
//!   comments:    `%% ...`
//!
//! Deliberately rejected with a precise diagnostic:
//!   - lowercase `end` as a node id (silently breaks real Mermaid)
//!   - anything outside the subset above
//!
//! Ownership: the result carries its own arena; all node/edge strings are copied
//! into it, so the diagram outlives the source buffer. Call `deinit` to free.

const std = @import("std");
const ir = @import("../ir/graph.zig");
const lexer = @import("lexer.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const FlowchartResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: ir.GraphDiagram,

    pub fn deinit(self: *FlowchartResult) void {
        self.arena.deinit();
    }
};

/// Parse `source` into a graph diagram. On syntax error, returns
/// `error.MermaidSyntax` and writes the detail through `diagnostic`.
pub fn parseFlowchart(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!FlowchartResult {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser: Parser = .{
        .arena = arena,
        .lexer = lexer.Lexer.init(source),
        .diagnostic = diagnostic,
    };
    try parser.advance();

    const diagram = try parser.parseProgram();

    return .{ .arena = arena_state, .diagram = diagram };
}

const Parser = struct {
    arena: std.mem.Allocator,
    lexer: lexer.Lexer,
    cur: lexer.Token = undefined,
    diagnostic: *?MermaidError,

    nodes: std.ArrayList(ir.Node) = .empty,
    edges: std.ArrayList(ir.Edge) = .empty,
    index: std.StringHashMapUnmanaged(ir.NodeId) = .empty,

    fn advance(self: *Parser) ParseError!void {
        self.cur = self.lexer.next() catch |err| return self.failLex(err);
    }

    fn failLex(self: *Parser, err: anyerror) ParseError {
        const detail: struct { kind: MermaidErrorKind, msg: []const u8 } = switch (err) {
            error.UnterminatedString => .{ .kind = .unterminated_label, .msg = "unterminated quoted string" },
            error.UnterminatedLabel => .{ .kind = .unterminated_shape, .msg = "unterminated node label" },
            else => .{ .kind = .unexpected_token, .msg = "unexpected character" },
        };
        return self.fail(detail.kind, self.lexer.line, self.lexer.column, detail.msg);
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }

    fn parseProgram(self: *Parser) ParseError!ir.GraphDiagram {
        const direction = try self.parseHeader();

        while (self.cur.kind != .eof) {
            if (self.cur.kind == .newline) {
                try self.advance();
                continue;
            }
            try self.parseStatement();
        }

        return .{
            .direction = direction,
            .nodes = try self.nodes.toOwnedSlice(self.arena),
            .edges = try self.edges.toOwnedSlice(self.arena),
        };
    }

    fn parseHeader(self: *Parser) ParseError!ir.Direction {
        while (self.cur.kind == .newline) try self.advance();

        if (self.cur.kind != .identifier or
            !(std.mem.eql(u8, self.cur.lexeme, "flowchart") or std.mem.eql(u8, self.cur.lexeme, "graph")))
        {
            return self.fail(.missing_header, self.cur.line, self.cur.column, "expected 'flowchart' or 'graph' header");
        }
        try self.advance();

        var direction: ir.Direction = .tb;
        if (self.cur.kind == .identifier) {
            direction = parseDirection(self.cur.lexeme) orelse
                return self.fail(.invalid_direction, self.cur.line, self.cur.column, "expected a direction: TD, TB, LR, RL, or BT");
            try self.advance();
        }

        if (self.cur.kind != .newline and self.cur.kind != .eof) {
            return self.fail(.unexpected_token, self.cur.line, self.cur.column, "unexpected token after diagram header");
        }
        return direction;
    }

    /// chain := node (edge (`|` label `|`)? node)*
    fn parseStatement(self: *Parser) ParseError!void {
        var prev = try self.parseNode();

        while (self.cur.kind == .edge) {
            const op = self.cur.edge;
            try self.advance();

            var label: ?[]const u8 = null;
            if (self.cur.kind == .pipe) {
                const raw = self.lexer.readLabel('|') catch |err| return self.failLex(err);
                label = try self.arena.dupe(u8, raw);
                try self.advance();
            }

            const target = try self.parseNode();
            try self.edges.append(self.arena, .{
                .from = prev,
                .to = target,
                .label = label,
                .line = op.line,
                .arrow = op.arrow,
                .min_len = edgeMinLen(op),
            });
            prev = target;
        }

        if (self.cur.kind != .newline and self.cur.kind != .eof) {
            return self.fail(.unexpected_token, self.cur.line, self.cur.column, "expected an edge or end of statement");
        }
    }

    /// node := IDENT shape?
    fn parseNode(self: *Parser) ParseError!ir.NodeId {
        if (self.cur.kind != .identifier) {
            return self.fail(.expected_node, self.cur.line, self.cur.column, "expected a node identifier");
        }
        if (std.mem.eql(u8, self.cur.lexeme, "end")) {
            return self.fail(.reserved_keyword_end, self.cur.line, self.cur.column, "'end' cannot be used as a node id (reserved by Mermaid)");
        }

        const id = self.cur.lexeme;
        try self.advance();

        var shape: ir.NodeShape = .rect;
        var explicit_label: ?[]const u8 = null;

        switch (self.cur.kind) {
            .lbracket => {
                explicit_label = self.lexer.readLabel(']') catch |err| return self.failLex(err);
                shape = .rect;
                try self.advance();
            },
            .ldparen => {
                explicit_label = self.lexer.readDoubleParenLabel() catch |err| return self.failLex(err);
                shape = .circle;
                try self.advance();
            },
            .lparen => {
                explicit_label = self.lexer.readLabel(')') catch |err| return self.failLex(err);
                shape = .round;
                try self.advance();
            },
            .lbrace => {
                explicit_label = self.lexer.readLabel('}') catch |err| return self.failLex(err);
                shape = .diamond;
                try self.advance();
            },
            else => {},
        }

        return self.upsertNode(id, explicit_label, shape, explicit_label != null);
    }

    /// Insert a node or update an existing one when this reference carries an
    /// explicit shape/label (Mermaid lets a later definition set the label).
    fn upsertNode(
        self: *Parser,
        id: []const u8,
        label: ?[]const u8,
        shape: ir.NodeShape,
        explicit: bool,
    ) ParseError!ir.NodeId {
        const gop = try self.index.getOrPut(self.arena, id);
        if (gop.found_existing) {
            if (explicit) {
                const node = &self.nodes.items[gop.value_ptr.*];
                node.shape = shape;
                node.label = try self.arena.dupe(u8, label.?);
            }
            return gop.value_ptr.*;
        }

        const owned_id = try self.arena.dupe(u8, id);
        gop.key_ptr.* = owned_id;
        const node_id: ir.NodeId = @intCast(self.nodes.items.len);
        gop.value_ptr.* = node_id;
        try self.nodes.append(self.arena, .{
            .id = owned_id,
            .label = try self.arena.dupe(u8, if (label) |l| l else id),
            .shape = shape,
        });
        return node_id;
    }
};

/// Mermaid lengthens an edge by adding dash/equals characters. The minimal
/// arrow link (`-->`, `==>`) has 2 stroke chars; the minimal open link (`---`)
/// has 3. Each character past that baseline adds one rank of length.
fn edgeMinLen(op: lexer.EdgeOp) u8 {
    const baseline: u8 = if (op.arrow == .none) 3 else 2;
    if (op.length <= baseline) return 1;
    return op.length - baseline + 1;
}

fn parseDirection(lexeme: []const u8) ?ir.Direction {
    if (eqlIgnoreCase(lexeme, "TD")) return .td;
    if (eqlIgnoreCase(lexeme, "TB")) return .tb;
    if (eqlIgnoreCase(lexeme, "LR")) return .lr;
    if (eqlIgnoreCase(lexeme, "RL")) return .rl;
    if (eqlIgnoreCase(lexeme, "BT")) return .bt;
    return null;
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

fn parseForTest(source: []const u8) !FlowchartResult {
    var diag: ?MermaidError = null;
    return parseFlowchart(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses a basic LR flowchart" {
    var result = try parseForTest(
        \\flowchart LR
        \\    A --> B
    );
    defer result.deinit();

    try testing.expectEqual(ir.Direction.lr, result.diagram.direction);
    try testing.expectEqual(@as(usize, 2), result.diagram.nodes.len);
    try testing.expectEqual(@as(usize, 1), result.diagram.edges.len);
    try testing.expectEqualStrings("A", result.diagram.nodes[0].id);
    try testing.expectEqualStrings("B", result.diagram.nodes[1].id);

    const edge = result.diagram.edges[0];
    try testing.expectEqual(@as(ir.NodeId, 0), edge.from);
    try testing.expectEqual(@as(ir.NodeId, 1), edge.to);
    try testing.expectEqual(ir.LineKind.solid, edge.line);
    try testing.expectEqual(ir.ArrowKind.arrow, edge.arrow);
}

test "graph is an alias for flowchart and defaults to top-down" {
    var result = try parseForTest("graph\n A --> B\n");
    defer result.deinit();
    try testing.expectEqual(ir.Direction.tb, result.diagram.direction);
}

test "parses node shapes and labels" {
    var result = try parseForTest(
        \\flowchart TD
        \\    A[Start here]
        \\    A --> B(rounded)
        \\    B --> C((circle))
        \\    C --> D{decision}
    );
    defer result.deinit();

    const n = result.diagram.nodes;
    try testing.expectEqual(@as(usize, 4), n.len);
    try testing.expectEqual(ir.NodeShape.rect, n[0].shape);
    try testing.expectEqualStrings("Start here", n[0].label);
    try testing.expectEqual(ir.NodeShape.round, n[1].shape);
    try testing.expectEqualStrings("rounded", n[1].label);
    try testing.expectEqual(ir.NodeShape.circle, n[2].shape);
    try testing.expectEqualStrings("circle", n[2].label);
    try testing.expectEqual(ir.NodeShape.diamond, n[3].shape);
    try testing.expectEqualStrings("decision", n[3].label);
}

test "bare node defaults its label to its id" {
    var result = try parseForTest("flowchart LR\n A --> B\n");
    defer result.deinit();
    try testing.expectEqualStrings("A", result.diagram.nodes[0].label);
}

test "parses an edge chain and stroke variants" {
    var result = try parseForTest(
        \\flowchart LR
        \\    A --> B
        \\    B --- D
        \\    C -.-> D
        \\    D ==> E
    );
    defer result.deinit();

    const e = result.diagram.edges;
    try testing.expectEqual(@as(usize, 4), e.len);
    try testing.expectEqual(ir.ArrowKind.arrow, e[0].arrow);
    try testing.expectEqual(ir.ArrowKind.none, e[1].arrow);
    try testing.expectEqual(ir.LineKind.dotted, e[2].line);
    try testing.expectEqual(ir.LineKind.thick, e[3].line);
}

test "parses pipe edge labels" {
    var result = try parseForTest("flowchart LR\n A -->|yes| B\n");
    defer result.deinit();
    try testing.expect(result.diagram.edges[0].label != null);
    try testing.expectEqualStrings("yes", result.diagram.edges[0].label.?);
}

test "later definition sets a bare node's label" {
    var result = try parseForTest(
        \\flowchart LR
        \\    A --> B
        \\    A[Labeled]
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.diagram.nodes.len);
    try testing.expectEqualStrings("Labeled", result.diagram.nodes[0].label);
}

test "circle and cross edge ends are recognized" {
    var result = try parseForTest("flowchart LR\n A --o B\n B --x C\n");
    defer result.deinit();
    try testing.expectEqual(ir.ArrowKind.circle, result.diagram.edges[0].arrow);
    try testing.expectEqual(ir.ArrowKind.cross, result.diagram.edges[1].arrow);
}

test "longer edges raise min_len" {
    var result = try parseForTest("flowchart LR\n A ---> B\n");
    defer result.deinit();
    try testing.expectEqual(@as(u8, 2), result.diagram.edges[0].min_len);
}

test "comments are ignored" {
    var result = try parseForTest(
        \\flowchart LR
        \\    %% this is a comment
        \\    A --> B %% trailing
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.diagram.edges.len);
}

test "rejects lowercase end as a node id" {
    var diag: ?MermaidError = null;
    const result = parseFlowchart(testing.allocator, "flowchart LR\n A --> end\n", &diag);
    try testing.expectError(error.MermaidSyntax, result);
    try testing.expect(diag != null);
    try testing.expectEqual(MermaidErrorKind.reserved_keyword_end, diag.?.kind);
}

test "reports a missing header" {
    var diag: ?MermaidError = null;
    const result = parseFlowchart(testing.allocator, "A --> B\n", &diag);
    try testing.expectError(error.MermaidSyntax, result);
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
    try testing.expectEqual(@as(u32, 1), diag.?.line);
}

test "reports an unterminated shape with a location" {
    var diag: ?MermaidError = null;
    const result = parseFlowchart(testing.allocator, "flowchart LR\n A[unterminated\n", &diag);
    try testing.expectError(error.MermaidSyntax, result);
    try testing.expectEqual(MermaidErrorKind.unterminated_shape, diag.?.kind);
}

test "reports an invalid direction" {
    var diag: ?MermaidError = null;
    const result = parseFlowchart(testing.allocator, "flowchart SIDEWAYS\n A --> B\n", &diag);
    try testing.expectError(error.MermaidSyntax, result);
    try testing.expectEqual(MermaidErrorKind.invalid_direction, diag.?.kind);
}
