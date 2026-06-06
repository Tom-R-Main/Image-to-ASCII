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
    parent_id: ?[]const u8 = null,
};

const GroupDecl = struct {
    id: []const u8,
    label: []const u8,
    parent_id: ?[]const u8 = null,
};

const EdgeDecl = struct {
    from_id: []const u8,
    to_id: []const u8,
    arrow: graph.ArrowKind,
};

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    nodes: std.ArrayList(NodeData) = .empty,
    groups: std.ArrayList(GroupDecl) = .empty,
    edges: std.ArrayList(EdgeDecl) = .empty,
    index: std.StringHashMapUnmanaged(graph.NodeId) = .empty,
    group_index: std.StringHashMapUnmanaged(graph.ClusterId) = .empty,

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
        if (std.mem.eql(u8, kw, "group")) return self.parseDecl(line[kw.len..], line_no, true);
        if (std.mem.eql(u8, kw, "service")) return self.parseDecl(line[kw.len..], line_no, false);
        if (std.mem.eql(u8, kw, "junction")) {
            var i: usize = 0;
            const tail = std.mem.trim(u8, line[kw.len..], " \t\r");
            const id = readIdent(tail, &i);
            if (id.len == 0) return self.fail(.expected_node, line_no, 1, "expected a junction id");
            const parent = parseInParent(tail, &i);
            try self.declNode(id, id, parent);
            return;
        }
        return self.parseEdge(line, line_no);
    }

    /// `rest` is everything after `group`/`service`: ` id(icon)[title] in parent`.
    /// Groups become clusters; services/junctions become nodes carrying `parent`.
    fn parseDecl(self: *Parser, rest: []const u8, line_no: u32, is_group: bool) ParseError!void {
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
        const parent = parseInParent(rest, &i);

        if (is_group) {
            try self.declGroup(id, label, parent);
        } else {
            try self.declNode(id, label, parent);
        }
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

        try self.edges.append(self.arena, .{
            .from_id = try self.arena.dupe(u8, from_id),
            .to_id = try self.arena.dupe(u8, to_id),
            .arrow = arrow_kind,
        });
    }

    fn declNode(self: *Parser, id: []const u8, label: []const u8, parent: ?[]const u8) ParseError!void {
        const gop = try self.index.getOrPut(self.arena, id);
        if (gop.found_existing) {
            self.nodes.items[gop.value_ptr.*].label = try self.arena.dupe(u8, label);
            if (parent) |p| self.nodes.items[gop.value_ptr.*].parent_id = try self.arena.dupe(u8, p);
            return;
        }
        const owned = try self.arena.dupe(u8, id);
        gop.key_ptr.* = owned;
        gop.value_ptr.* = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena, .{
            .id = owned,
            .label = try self.arena.dupe(u8, label),
            .parent_id = if (parent) |p| try self.arena.dupe(u8, p) else null,
        });
    }

    fn declGroup(self: *Parser, id: []const u8, label: []const u8, parent: ?[]const u8) ParseError!void {
        const gop = try self.group_index.getOrPut(self.arena, id);
        if (gop.found_existing) return;
        const owned = try self.arena.dupe(u8, id);
        gop.key_ptr.* = owned;
        gop.value_ptr.* = @intCast(self.groups.items.len);
        try self.groups.append(self.arena, .{
            .id = owned,
            .label = try self.arena.dupe(u8, label),
            .parent_id = if (parent) |p| try self.arena.dupe(u8, p) else null,
        });
    }

    /// Resolve an edge endpoint id to a node index. A service/junction id maps to
    /// its node; a group id maps to a representative member (so the edge meets the
    /// group box); an unknown id becomes a fresh loose node.
    fn resolveEndpoint(self: *Parser, id: []const u8, clusters: []const graph.Cluster) ParseError!?graph.NodeId {
        if (self.index.get(id)) |nid| return nid;
        if (self.group_index.get(id)) |cid| return self.groupRep(cid, clusters);
        // Unknown id: create a loose node so the edge still renders.
        try self.declNode(id, id, null);
        return self.index.get(id).?;
    }

    fn groupRep(self: *Parser, cid: graph.ClusterId, clusters: []const graph.Cluster) ?graph.NodeId {
        for (self.nodes.items, 0..) |n, i| {
            var cur: ?graph.ClusterId = if (n.parent_id) |p| self.group_index.get(p) else null;
            while (cur) |c| {
                if (c == cid) return @intCast(i);
                cur = clusters[c].parent;
            }
        }
        return null; // empty group: edge to it is dropped
    }

    fn materialize(self: *Parser) ParseError!graph.GraphDiagram {
        // Clusters, resolving each group's parent group by id.
        const clusters = try self.arena.alloc(graph.Cluster, self.groups.items.len);
        for (self.groups.items, 0..) |g, i| {
            clusters[i] = .{
                .id = g.id,
                .label = g.label,
                .parent = if (g.parent_id) |p| self.group_index.get(p) else null,
            };
        }

        // Nodes, resolving each node's `in` group by id.
        const nodes = try self.arena.alloc(graph.Node, self.nodes.items.len);
        for (self.nodes.items, 0..) |n, i| {
            nodes[i] = .{
                .id = n.id,
                .label = n.label,
                .shape = .rect,
                .cluster = if (n.parent_id) |p| self.group_index.get(p) else null,
            };
        }

        // Resolve edges (endpoints may reference groups), dropping any that hit an
        // empty group with no representative member.
        var edges: std.ArrayList(graph.Edge) = .empty;
        for (self.edges.items) |e| {
            const from = try self.resolveEndpoint(e.from_id, clusters) orelse continue;
            const to = try self.resolveEndpoint(e.to_id, clusters) orelse continue;
            try edges.append(self.arena, .{ .from = from, .to = to, .arrow = e.arrow, .line = .solid });
        }

        return .{
            .direction = .lr,
            .nodes = nodes,
            .edges = try edges.toOwnedSlice(self.arena),
            .clusters = clusters,
        };
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

/// Parse a trailing ` in <parent>` clause from position `i`, returning the parent
/// id (or null). Leaves `i` past the clause when found.
fn parseInParent(s: []const u8, i: *usize) ?[]const u8 {
    var j = i.*;
    skipSpaces(s, &j);
    if (j + 2 > s.len or !std.mem.eql(u8, s[j .. j + 2], "in")) return null;
    j += 2;
    if (j < s.len and s[j] != ' ' and s[j] != '\t') return null; // "inbox" is not "in"
    skipSpaces(s, &j);
    const parent = readIdent(s, &j);
    if (parent.len == 0) return null;
    i.* = j;
    return parent;
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

    // api is a cluster now; db and server are its member nodes.
    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len); // db, server
    try testing.expectEqual(@as(usize, 1), r.diagram.clusters.len);
    try testing.expectEqualStrings("API", r.diagram.clusters[0].label);
    try testing.expectEqual(@as(?graph.ClusterId, 0), r.diagram.nodes[0].cluster);
    try testing.expectEqual(@as(?graph.ClusterId, 0), r.diagram.nodes[1].cluster);
    try testing.expectEqualStrings("Database", r.diagram.nodes[0].label);
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

test "an edge to a group id resolves to a representative member" {
    var r = try parseForTest(
        \\architecture-beta
        \\    group g(cloud)[G]
        \\    service a(server)[A] in g
        \\    service b(server)[B]
        \\    b:R --> L:g{group}
    );
    defer r.deinit();
    // `g` is a cluster; the edge to it lands on its member `a` so the renderer's
    // cluster pass routes it to the group box border.
    try testing.expectEqual(@as(usize, 1), r.diagram.edges.len);
    const e = r.diagram.edges[0];
    try testing.expectEqualStrings("b", r.diagram.nodes[e.from].id);
    try testing.expectEqualStrings("a", r.diagram.nodes[e.to].id);
    try testing.expectEqual(@as(?graph.ClusterId, 0), r.diagram.nodes[e.to].cluster);
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
