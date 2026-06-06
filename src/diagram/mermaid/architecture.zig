//! Parser for the real Mermaid `architecture-beta` diagram syntax. Architecture
//! is a graph-layout diagram, so this lowers to the shared graph IR — groups,
//! services, and junctions become boxes and connections become edges — and
//! reuses the layered layout and renderer.
//!
//! Supported:
//!   header:      `architecture-beta`
//!   groups:      `group {id}({icon})[{title}] (in {parent})?`
//!   services:    `service {id}({icon})[{title}] (in {parent})?`
//!   junctions:   `junction {id} (in {parent})?`
//!   edges:       `{idA}{:T|B|L|R}? {--|-->|<--|<-->} {:T|B|L|R}?{idB}`, with
//!                optional `{group}` modifiers on either endpoint
//!   comments:    `%% ...`
//!
//! v0 rendering: groups become plain nodes (no containment box) and `in {parent}`
//! nesting, port sides (`:L`/`:R`/...), and icons are parsed but not drawn. Edge
//! direction comes from the arrowheads. Syntax errors return `error.MermaidSyntax`.

const std = @import("std");
const graph = @import("../ir/graph.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const ArchitectureResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: graph.GraphDiagram,

    pub fn deinit(self: *ArchitectureResult) void {
        self.arena.deinit();
    }
};

pub fn parseArchitecture(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!ArchitectureResult {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);

    return .{ .arena = arena_state, .diagram = diagram };
}

pub fn isHeader(word: []const u8) bool {
    return std.mem.eql(u8, word, "architecture-beta");
}

const NodeData = struct {
    id: []const u8,
    label: []const u8,
};

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    nodes: std.ArrayList(NodeData) = .empty,
    edges: std.ArrayList(graph.Edge) = .empty,
    index: std.StringHashMapUnmanaged(graph.NodeId) = .empty,

    fn run(self: *Parser, source: []const u8) ParseError!graph.GraphDiagram {
        var line_no: u32 = 0;
        var seen_header = false;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |raw| {
            line_no += 1;
            const trimmed = std.mem.trim(u8, stripComment(raw), " \t\r");
            if (trimmed.len == 0) continue;

            if (!seen_header) {
                if (!isHeader(firstWord(trimmed))) {
                    return self.fail(.missing_header, line_no, 1, "expected the 'architecture-beta' header");
                }
                seen_header = true;
                continue;
            }

            try self.parseStatement(trimmed, line_no);
        }

        if (!seen_header) return self.fail(.missing_header, 1, 1, "expected the 'architecture-beta' header");
        return try self.materialize();
    }

    fn parseStatement(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        const kw = firstWord(line);
        if (std.mem.eql(u8, kw, "group") or std.mem.eql(u8, kw, "service")) {
            return self.parseNodeDecl(line[kw.len..], line_no);
        }
        if (std.mem.eql(u8, kw, "junction")) {
            const id = firstWord(std.mem.trim(u8, line[kw.len..], " \t\r"));
            if (id.len == 0) return self.fail(.expected_node, line_no, 1, "expected a junction id");
            _ = try self.upsertNode(id, id);
            return;
        }
        return self.parseEdge(line, line_no);
    }

    /// `rest` is everything after `group`/`service`: ` id(icon)[title] in parent`.
    fn parseNodeDecl(self: *Parser, rest: []const u8, line_no: u32) ParseError!void {
        var i: usize = 0;
        skipSpaces(rest, &i);
        const id = readIdent(rest, &i);
        if (id.len == 0) return self.fail(.expected_node, line_no, 1, "expected an id");

        // optional (icon) — parsed and ignored
        if (i < rest.len and rest[i] == '(') {
            const close = std.mem.indexOfScalarPos(u8, rest, i, ')') orelse
                return self.fail(.unexpected_token, line_no, @intCast(i + 1), "unterminated icon");
            i = close + 1;
        }
        // optional [title] — becomes the label
        var label = id;
        if (i < rest.len and rest[i] == '[') {
            const close = std.mem.indexOfScalarPos(u8, rest, i, ']') orelse
                return self.fail(.unterminated_label, line_no, @intCast(i + 1), "unterminated title");
            label = std.mem.trim(u8, rest[i + 1 .. close], " \t\r");
            i = close + 1;
        }
        // remainder (`in parent`) parsed loosely and ignored
        const id_node = try self.upsertNode(id, label);
        self.nodes.items[id_node].label = try self.arena.dupe(u8, label);
    }

    fn parseEdge(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        const span = findArrow(line) orelse
            return self.fail(.unexpected_token, line_no, 1, "expected a group/service/junction or a connection");
        const left = std.mem.trim(u8, line[0..span.start], " \t\r");
        const right = std.mem.trim(u8, line[span.end..], " \t\r");
        const left_id = leftEndpointId(left);
        const right_id = rightEndpointId(right);
        if (left_id.len == 0 or right_id.len == 0) {
            return self.fail(.expected_node, line_no, 1, "a connection needs an id on each side");
        }

        const arrow = line[span.start..span.end];
        const points_left = arrow[0] == '<';
        const points_right = arrow[arrow.len - 1] == '>';

        // Orient so the arrowhead lands on the target. `--` has no head.
        const from_id = if (points_left and !points_right) right_id else left_id;
        const to_id = if (points_left and !points_right) left_id else right_id;
        const arrow_kind: graph.ArrowKind = if (points_left or points_right) .arrow else .none;

        const from = try self.upsertNode(from_id, from_id);
        const to = try self.upsertNode(to_id, to_id);
        try self.edges.append(self.arena, .{ .from = from, .to = to, .arrow = arrow_kind, .line = .solid });
    }

    fn upsertNode(self: *Parser, id: []const u8, label: []const u8) ParseError!graph.NodeId {
        const gop = try self.index.getOrPut(self.arena, id);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = try self.arena.dupe(u8, id);
        gop.key_ptr.* = owned;
        const nid: graph.NodeId = @intCast(self.nodes.items.len);
        gop.value_ptr.* = nid;
        try self.nodes.append(self.arena, .{ .id = owned, .label = try self.arena.dupe(u8, label) });
        return nid;
    }

    fn materialize(self: *Parser) ParseError!graph.GraphDiagram {
        const nodes = try self.arena.alloc(graph.Node, self.nodes.items.len);
        for (self.nodes.items, 0..) |n, i| {
            nodes[i] = .{ .id = n.id, .label = n.label, .shape = .rect };
        }
        return .{ .direction = .lr, .nodes = nodes, .edges = try self.edges.toOwnedSlice(self.arena) };
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }
};

const ArrowSpan = struct { start: usize, end: usize };

/// Locate the connection operator (a run of `-`, `<`, `>`). Endpoints never
/// contain those characters, so the first such run is the arrow.
fn findArrow(line: []const u8) ?ArrowSpan {
    const start = std.mem.indexOfAny(u8, line, "-<>") orelse return null;
    var end = start;
    while (end < line.len and (line[end] == '-' or line[end] == '<' or line[end] == '>')) : (end += 1) {}
    return .{ .start = start, .end = end };
}

/// Left endpoint id: leading ident, ignoring any `{group}` / `:side` suffix.
fn leftEndpointId(s: []const u8) []const u8 {
    var i: usize = 0;
    return readIdent(s, &i);
}

/// Right endpoint id: optional leading `T:`/`B:`/`L:`/`R:`, then the ident.
fn rightEndpointId(s: []const u8) []const u8 {
    var start: usize = 0;
    if (s.len >= 2 and std.ascii.isAlphabetic(s[0]) and s[1] == ':') start = 2;
    var i = start;
    return readIdent(s, &i);
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

fn skipSpaces(line: []const u8, i: *usize) void {
    while (i.* < line.len and (line[i.*] == ' ' or line[i.*] == '\t' or line[i.*] == '\r')) : (i.* += 1) {}
}

fn readIdent(line: []const u8, i: *usize) []const u8 {
    const start = i.*;
    while (i.* < line.len and (std.ascii.isAlphanumeric(line[i.*]) or line[i.*] == '_')) : (i.* += 1) {}
    return line[start..i.*];
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(source: []const u8) !ArchitectureResult {
    var diag: ?MermaidError = null;
    return parseArchitecture(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses groups, services, and a directed connection" {
    var r = try parseForTest(
        \\architecture-beta
        \\    group api(cloud)[API]
        \\    service db(database)[Database] in api
        \\    service server(server)[Server] in api
        \\    db:R --> L:server
    );
    defer r.deinit();

    try testing.expectEqual(@as(usize, 3), r.diagram.nodes.len); // api, db, server
    try testing.expectEqualStrings("API", r.diagram.nodes[0].label);
    try testing.expectEqualStrings("Database", r.diagram.nodes[1].label);
    try testing.expectEqual(@as(usize, 1), r.diagram.edges.len);
    const e = r.diagram.edges[0];
    try testing.expectEqualStrings("db", r.diagram.nodes[e.from].id);
    try testing.expectEqualStrings("server", r.diagram.nodes[e.to].id);
    try testing.expectEqual(graph.ArrowKind.arrow, e.arrow);
}

test "reversed and plain connections orient correctly" {
    var r = try parseForTest(
        \\architecture-beta
        \\    service a(x)[A]
        \\    service b(x)[B]
        \\    a:R <-- L:b
        \\    a:T -- B:b
    );
    defer r.deinit();
    // `a <-- b` points at a, so the edge runs b -> a.
    try testing.expectEqualStrings("b", r.diagram.nodes[r.diagram.edges[0].from].id);
    try testing.expectEqualStrings("a", r.diagram.nodes[r.diagram.edges[0].to].id);
    try testing.expectEqual(graph.ArrowKind.arrow, r.diagram.edges[0].arrow);
    // `--` has no arrowhead.
    try testing.expectEqual(graph.ArrowKind.none, r.diagram.edges[1].arrow);
}

test "group-modifier endpoints connect to the group node" {
    var r = try parseForTest(
        \\architecture-beta
        \\    group outer(cloud)[Outer]
        \\    service inner(server)[Inner]
        \\    inner:B --> T:outer{group}
    );
    defer r.deinit();
    const e = r.diagram.edges[0];
    try testing.expectEqualStrings("inner", r.diagram.nodes[e.from].id);
    try testing.expectEqualStrings("outer", r.diagram.nodes[e.to].id);
}

test "junctions become nodes" {
    var r = try parseForTest(
        \\architecture-beta
        \\    junction j1
        \\    service s(x)[S]
        \\    j1:R --> L:s
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    try testing.expectEqualStrings("j1", r.diagram.nodes[0].id);
}

test "rejects a missing header" {
    var diag: ?MermaidError = null;
    const r = parseArchitecture(testing.allocator, "group api(cloud)[API]\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
}
