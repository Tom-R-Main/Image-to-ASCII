//! Line-based parser for the Mermaid entity-relationship (ER) diagram subset.
//! ER diagrams are graph-layout, so this lowers to the shared graph IR: entities
//! become single-compartment "card" nodes (reusing the class card renderer) and
//! relationships become edges annotated with cardinality at each end.
//!
//! Supported subset (v0):
//!   header:        `erDiagram`
//!   entity blocks: `CUSTOMER { string name PK ... }` (attribute lines verbatim)
//!   relationships: `A CARD--CARD B : verb` where each CARD is one of
//!                  `||` `|o` `o|` `}o` `o{` `}|` `|{`, joined by `--`
//!                  (identifying, solid) or `..` (non-identifying, dashed)
//!   comments:      `%% ...`
//!
//! Cardinality renders as compact multiplicity text (`1`, `0..1`, `1..N`,
//! `0..N`) beside each endpoint rather than crow's-foot glyphs, which a cell grid
//! cannot draw faithfully. Entity names are `[A-Za-z0-9_]` (hyphenated/quoted
//! names are not yet supported). Syntax errors return `error.MermaidSyntax`.

const std = @import("std");
const graph = @import("../ir/graph.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const ErResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: graph.GraphDiagram,

    pub fn deinit(self: *ErResult) void {
        self.arena.deinit();
    }
};

pub fn parseEr(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!ErResult {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);

    return .{ .arena = arena_state, .diagram = diagram };
}

const EntityData = struct {
    id: []const u8,
    attrs: std.ArrayList([]const u8) = .empty,
};

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    entities: std.ArrayList(EntityData) = .empty,
    edges: std.ArrayList(graph.Edge) = .empty,
    index: std.StringHashMapUnmanaged(graph.NodeId) = .empty,
    open_entity: ?graph.NodeId = null,

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
                if (!std.mem.eql(u8, trimmed, "erDiagram")) {
                    return self.fail(.missing_header, line_no, 1, "expected 'erDiagram' header");
                }
                seen_header = true;
                continue;
            }

            try self.parseStatement(trimmed, line_no);
        }

        if (!seen_header) return self.fail(.missing_header, 1, 1, "expected 'erDiagram' header");
        if (self.open_entity != null) return self.fail(.unexpected_token, line_no, 1, "unclosed entity block: expected '}'");

        return try self.materialize();
    }

    fn parseStatement(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        if (self.open_entity) |eid| {
            if (std.mem.eql(u8, line, "}")) {
                self.open_entity = null;
                return;
            }
            const owned = try self.arena.dupe(u8, line);
            try self.entities.items[eid].attrs.append(self.arena, owned);
            return;
        }

        var i: usize = 0;
        skipSpaces(line, &i);
        const left = readIdent(line, &i);
        if (left.len == 0) return self.fail(.expected_node, line_no, 1, "expected an entity name");
        skipSpaces(line, &i);

        // `ENTITY {` opens an attribute block.
        if (i < line.len and line[i] == '{') {
            self.open_entity = try self.upsertEntity(left);
            return;
        }
        // Otherwise a relationship: a cardinality run, then the right entity.
        if (i < line.len and isCardChar(line[i])) {
            return self.parseRelationship(left, line, &i, line_no);
        }
        if (i >= line.len) {
            _ = try self.upsertEntity(left); // bare entity declaration
            return;
        }
        return self.fail(.unexpected_token, line_no, @intCast(i + 1), "expected '{' or a relationship after the entity");
    }

    fn parseRelationship(self: *Parser, left: []const u8, line: []const u8, i: *usize, line_no: u32) ParseError!void {
        const op_start = i.*;
        while (i.* < line.len and isCardChar(line[i.*])) : (i.* += 1) {}
        const op = line[op_start..i.*];
        skipSpaces(line, i);
        const right = readIdent(line, i);
        if (right.len == 0) return self.fail(.expected_node, line_no, @intCast(i.* + 1), "expected an entity on the right of the relationship");
        skipSpaces(line, i);

        var label: ?[]const u8 = null;
        if (i.* < line.len and line[i.*] == ':') {
            label = std.mem.trim(u8, line[i.* + 1 ..], " \t\r");
        }

        const rel = classify(op) orelse return self.fail(.unexpected_token, line_no, @intCast(op_start + 1), "expected a cardinality relationship (e.g. ||--o{)");

        const from = try self.upsertEntity(left);
        const to = try self.upsertEntity(right);
        try self.edges.append(self.arena, .{
            .from = from,
            .to = to,
            .label = if (label) |l| try self.arena.dupe(u8, l) else null,
            .line = rel.line,
            .arrow = .none,
            .from_end = rel.from_end,
            .to_end = rel.to_end,
        });
    }

    fn upsertEntity(self: *Parser, name: []const u8) ParseError!graph.NodeId {
        const gop = try self.index.getOrPut(self.arena, name);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = try self.arena.dupe(u8, name);
        gop.key_ptr.* = owned;
        const id: graph.NodeId = @intCast(self.entities.items.len);
        gop.value_ptr.* = id;
        try self.entities.append(self.arena, .{ .id = owned });
        return id;
    }

    fn materialize(self: *Parser) ParseError!graph.GraphDiagram {
        const nodes = try self.arena.alloc(graph.Node, self.entities.items.len);
        for (self.entities.items, 0..) |e, i| {
            var compartments: ?[]const graph.Compartment = null;
            if (e.attrs.items.len > 0) {
                const comps = try self.arena.alloc(graph.Compartment, 1);
                comps[0] = try self.arena.dupe([]const u8, e.attrs.items);
                compartments = comps;
            }
            nodes[i] = .{ .id = e.id, .label = e.id, .shape = .rect, .compartments = compartments };
        }
        return .{
            .direction = .tb,
            .nodes = nodes,
            .edges = try self.edges.toOwnedSlice(self.arena),
        };
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }
};

const Rel = struct {
    line: graph.LineKind,
    from_end: []const u8,
    to_end: []const u8,
};

/// Split a cardinality operator (e.g. `||--o{`) into a connector (`--` solid /
/// `..` dashed) and a left/right cardinality, mapped to multiplicity text.
fn classify(op: []const u8) ?Rel {
    const conn = std.mem.indexOfAny(u8, op, "-.") orelse return null;
    if (conn + 2 > op.len) return null;
    const connector = op[conn .. conn + 2];
    const line: graph.LineKind = if (std.mem.eql(u8, connector, "--"))
        .solid
    else if (std.mem.eql(u8, connector, ".."))
        .dotted
    else
        return null;

    const left = op[0..conn];
    const right = op[conn + 2 ..];
    if (left.len == 0 or right.len == 0) return null;

    return .{
        .line = line,
        .from_end = cardinalityText(left) orelse return null,
        .to_end = cardinalityText(right) orelse return null,
    };
}

/// Map a crow's-foot cardinality token to multiplicity text. `{`/`}` is "many",
/// `o` is "optional/zero", `|` is "one".
fn cardinalityText(card: []const u8) ?[]const u8 {
    var many = false;
    var optional = false;
    var bar = false;
    for (card) |c| switch (c) {
        '{', '}' => many = true,
        'o' => optional = true,
        '|' => bar = true,
        else => return null,
    };
    if (!many and !optional and !bar) return null;
    if (many) return if (optional) "0..N" else "1..N";
    return if (optional) "0..1" else "1";
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "%%")) |pos| return line[0..pos];
    return line;
}

fn skipSpaces(line: []const u8, i: *usize) void {
    while (i.* < line.len and (line[i.*] == ' ' or line[i.*] == '\t' or line[i.*] == '\r')) : (i.* += 1) {}
}

fn readIdent(line: []const u8, i: *usize) []const u8 {
    const start = i.*;
    while (i.* < line.len and (std.ascii.isAlphanumeric(line[i.*]) or line[i.*] == '_')) : (i.* += 1) {}
    return line[start..i.*];
}

fn isCardChar(c: u8) bool {
    return c == '|' or c == 'o' or c == '{' or c == '}' or c == '-' or c == '.';
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(source: []const u8) !ErResult {
    var diag: ?MermaidError = null;
    return parseEr(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses a relationship with cardinality" {
    var r = try parseForTest("erDiagram\n CUSTOMER ||--o{ ORDER : places\n");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    const e = r.diagram.edges[0];
    try testing.expectEqualStrings("CUSTOMER", r.diagram.nodes[e.from].id);
    try testing.expectEqualStrings("ORDER", r.diagram.nodes[e.to].id);
    try testing.expectEqualStrings("1", e.from_end.?); // ||  -> exactly one
    try testing.expectEqualStrings("0..N", e.to_end.?); // o{ -> zero or more
    try testing.expectEqualStrings("places", e.label.?);
    try testing.expectEqual(graph.ArrowKind.none, e.arrow);
}

test "non-identifying relationships are dashed" {
    var r = try parseForTest("erDiagram\n A }o..o{ B\n");
    defer r.deinit();
    try testing.expectEqual(graph.LineKind.dotted, r.diagram.edges[0].line);
    try testing.expectEqualStrings("0..N", r.diagram.edges[0].from_end.?);
    try testing.expectEqualStrings("0..N", r.diagram.edges[0].to_end.?);
}

test "all cardinality tokens map correctly" {
    var r = try parseForTest(
        \\erDiagram
        \\    A ||--|| B
        \\    A |o--o| B
        \\    A }|--|{ B
    );
    defer r.deinit();
    try testing.expectEqualStrings("1", r.diagram.edges[0].from_end.?);
    try testing.expectEqualStrings("1", r.diagram.edges[0].to_end.?);
    try testing.expectEqualStrings("0..1", r.diagram.edges[1].from_end.?);
    try testing.expectEqualStrings("0..1", r.diagram.edges[1].to_end.?);
    try testing.expectEqualStrings("1..N", r.diagram.edges[2].from_end.?);
    try testing.expectEqualStrings("1..N", r.diagram.edges[2].to_end.?);
}

test "entity block populates a single attribute compartment" {
    var r = try parseForTest(
        \\erDiagram
        \\    CUSTOMER {
        \\        string name
        \\        string custNumber PK
        \\    }
    );
    defer r.deinit();
    const comps = r.diagram.nodes[0].compartments.?;
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(@as(usize, 2), comps[0].len);
    try testing.expectEqualStrings("string name", comps[0][0]);
    try testing.expectEqualStrings("string custNumber PK", comps[0][1]);
}

test "an entity with no attributes is a plain box" {
    var r = try parseForTest("erDiagram\n A ||--|| B\n");
    defer r.deinit();
    try testing.expect(r.diagram.nodes[0].compartments == null);
}

test "rejects a missing header" {
    var diag: ?MermaidError = null;
    const r = parseEr(testing.allocator, "A ||--o{ B\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
}

test "rejects a malformed relationship operator" {
    var diag: ?MermaidError = null;
    const r = parseEr(testing.allocator, "erDiagram\n A |~| B\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
}
