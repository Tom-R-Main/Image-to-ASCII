//! Parser for the Mermaid `mindmap` diagram. A mindmap is an indentation-defined
//! tree, which the shared layered layout renders natively, so this lowers to the
//! graph IR (nodes + parent→child edges) and reuses the graph renderer.
//!
//! Supported:
//!   header:   `mindmap`
//!   nodes:    one per line; nesting by leading-whitespace depth. Shapes:
//!             `id[square]`, `id(round)`, `id((circle))`, `id{{hexagon}}`,
//!             `id))bang((`, `id)cloud(`, or bare text (the label, id auto-made).
//!   ignored:  `::icon(...)` and `:::class` decorations, `%%` comments.
//!
//! v0 rendering: Mermaid lays mindmaps out radially; we render a left-to-right
//! layered tree (the honest fit for the existing engine). Markdown in labels and
//! the radial geometry are not reproduced.

const std = @import("std");
const graph = @import("../ir/graph.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const MindmapResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: graph.GraphDiagram,

    pub fn deinit(self: *MindmapResult) void {
        self.arena.deinit();
    }
};

pub fn parseMindmap(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!MindmapResult {
    diagnostic.* = null;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);
    return .{ .arena = arena_state, .diagram = diagram };
}

pub fn isHeader(word: []const u8) bool {
    return std.mem.eql(u8, word, "mindmap");
}

const NodeData = struct {
    id: []const u8,
    label: []const u8,
    shape: graph.NodeShape,
};

/// A node on the ancestor stack: its indentation depth and graph id.
const StackEntry = struct { depth: usize, id: graph.NodeId };

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    nodes: std.ArrayList(NodeData) = .empty,
    edges: std.ArrayList(graph.Edge) = .empty,
    stack: std.ArrayList(StackEntry) = .empty,
    auto: u32 = 0,

    fn run(self: *Parser, source: []const u8) ParseError!graph.GraphDiagram {
        var line_no: u32 = 0;
        var seen_header = false;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |raw| {
            line_no += 1;
            const no_comment = stripComment(raw);
            const trimmed = std.mem.trim(u8, no_comment, " \t\r");
            if (trimmed.len == 0) continue;

            if (!seen_header) {
                if (!isHeader(firstWord(trimmed))) {
                    return self.fail(.missing_header, line_no, 1, "expected the 'mindmap' header");
                }
                seen_header = true;
                // `mindmap root` on the same line is allowed: parse the remainder.
                const rest = std.mem.trim(u8, no_comment[indexAfterWord(no_comment, "mindmap")..], " \t\r");
                if (rest.len == 0) continue;
                try self.addNode(0, rest, line_no);
                continue;
            }

            const depth = leadingWhitespace(no_comment);
            try self.addNode(depth, trimmed, line_no);
        }

        if (!seen_header) return self.fail(.missing_header, 1, 1, "expected the 'mindmap' header");
        if (self.nodes.items.len == 0) return self.fail(.expected_node, line_no, 1, "a mindmap needs at least a root node");
        return try self.materialize();
    }

    fn addNode(self: *Parser, depth: usize, text: []const u8, line_no: u32) ParseError!void {
        _ = line_no;
        const parsed = try self.parseNodeText(text);
        const nid: graph.NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena, parsed);

        // Pop ancestors that are not shallower than this node, then the top of the
        // stack (if any) is this node's parent.
        while (self.stack.items.len > 0 and self.stack.items[self.stack.items.len - 1].depth >= depth) {
            _ = self.stack.pop();
        }
        if (self.stack.items.len > 0) {
            const parent = self.stack.items[self.stack.items.len - 1].id;
            try self.edges.append(self.arena, .{ .from = parent, .to = nid, .arrow = .none, .line = .solid });
        }
        try self.stack.append(self.arena, .{ .depth = depth, .id = nid });
    }

    /// Parse `id[shape]` / bare text into id, label, and shape. Strips trailing
    /// `::icon(...)` / `:::class` decorations.
    fn parseNodeText(self: *Parser, raw: []const u8) ParseError!NodeData {
        var text = raw;
        if (std.mem.indexOf(u8, text, ":::")) |pos| text = std.mem.trimEnd(u8, text[0..pos], " \t");
        if (std.mem.indexOf(u8, text, "::")) |pos| text = std.mem.trimEnd(u8, text[0..pos], " \t");

        const shapes = [_]struct { open: []const u8, close: []const u8, shape: graph.NodeShape }{
            .{ .open = "((", .close = "))", .shape = .circle },
            .{ .open = "{{", .close = "}}", .shape = .diamond },
            .{ .open = "))", .close = "((", .shape = .round }, // bang
            .{ .open = "[", .close = "]", .shape = .rect },
            .{ .open = "(", .close = ")", .shape = .round },
            .{ .open = ")", .close = "(", .shape = .round }, // cloud
        };
        for (shapes) |s| {
            if (std.mem.indexOf(u8, text, s.open)) |op| {
                if (std.mem.lastIndexOf(u8, text, s.close)) |cl| {
                    if (cl >= op + s.open.len) {
                        const id_part = std.mem.trim(u8, text[0..op], " \t");
                        const label = std.mem.trim(u8, text[op + s.open.len .. cl], " \t");
                        return .{
                            .id = if (id_part.len > 0) try self.arena.dupe(u8, id_part) else try self.makeId(),
                            .label = try self.arena.dupe(u8, label),
                            .shape = s.shape,
                        };
                    }
                }
            }
        }
        // Bare text: the whole thing is the label.
        return .{ .id = try self.makeId(), .label = try self.arena.dupe(u8, text), .shape = .rect };
    }

    fn makeId(self: *Parser) ParseError![]const u8 {
        const id = try std.fmt.allocPrint(self.arena, "n{d}", .{self.auto});
        self.auto += 1;
        return id;
    }

    fn materialize(self: *Parser) ParseError!graph.GraphDiagram {
        const nodes = try self.arena.alloc(graph.Node, self.nodes.items.len);
        for (self.nodes.items, 0..) |n, i| {
            nodes[i] = .{ .id = n.id, .label = n.label, .shape = n.shape };
        }
        return .{ .direction = .lr, .nodes = nodes, .edges = try self.edges.toOwnedSlice(self.arena) };
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }
};

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "%%")) |pos| return line[0..pos];
    return line;
}

fn leadingWhitespace(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) : (n += 1) {}
    return n;
}

fn firstWord(s: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, s, " \t\r");
    var end: usize = 0;
    while (end < t.len and t[end] != ' ' and t[end] != '\t' and t[end] != '\r') : (end += 1) {}
    return t[0..end];
}

fn indexAfterWord(s: []const u8, word: []const u8) usize {
    const pos = std.mem.indexOf(u8, s, word) orelse return s.len;
    return pos + word.len;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(source: []const u8) !MindmapResult {
    var diag: ?MermaidError = null;
    return parseMindmap(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "builds a tree from indentation" {
    var r = try parseForTest(
        \\mindmap
        \\  root((Root))
        \\    Planning
        \\      Spec
        \\    Build
        \\    Ship
    );
    defer r.deinit();

    // root, Planning, Spec, Build, Ship.
    try testing.expectEqual(@as(usize, 5), r.diagram.nodes.len);
    try testing.expectEqualStrings("Root", r.diagram.nodes[0].label);
    try testing.expectEqual(graph.NodeShape.circle, r.diagram.nodes[0].shape);
    // 4 parent->child edges (every non-root node has one parent).
    try testing.expectEqual(@as(usize, 4), r.diagram.edges.len);
    // Spec's parent is Planning, not root.
    var spec_parent: ?graph.NodeId = null;
    for (r.diagram.edges) |e| {
        if (std.mem.eql(u8, r.diagram.nodes[e.to].label, "Spec")) spec_parent = e.from;
    }
    try testing.expectEqualStrings("Planning", r.diagram.nodes[spec_parent.?].label);
}

test "parses node shapes and strips class/icon decorations" {
    var r = try parseForTest(
        \\mindmap
        \\  id1[Square]
        \\    id2(Round) :::urgent
        \\    id3{{Hex}} ::icon(fa fa-book)
    );
    defer r.deinit();
    try testing.expectEqual(graph.NodeShape.rect, r.diagram.nodes[0].shape);
    try testing.expectEqualStrings("Square", r.diagram.nodes[0].label);
    try testing.expectEqual(graph.NodeShape.round, r.diagram.nodes[1].shape);
    try testing.expectEqualStrings("Round", r.diagram.nodes[1].label);
    try testing.expectEqual(graph.NodeShape.diamond, r.diagram.nodes[2].shape);
    try testing.expectEqualStrings("Hex", r.diagram.nodes[2].label);
}

test "root on the header line is accepted" {
    var r = try parseForTest("mindmap root((Center))\n  child\n");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    try testing.expectEqualStrings("Center", r.diagram.nodes[0].label);
    try testing.expectEqual(@as(usize, 1), r.diagram.edges.len);
}

test "rejects a missing header" {
    var diag: ?MermaidError = null;
    try testing.expectError(error.MermaidSyntax, parseMindmap(testing.allocator, "  root\n", &diag));
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
}
