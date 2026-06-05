//! Line-based parser for the Mermaid class-diagram subset. Class diagrams are a
//! graph-layout diagram, so this frontend lowers to the shared graph IR
//! (`ir/graph.zig`) — classes become compartment "card" nodes, relationships
//! become edges with UML endpoint decorations — and reuses the layered layout and
//! graph renderer.
//!
//! Supported subset (v0):
//!   header:        `classDiagram`
//!   class blocks:  `class User { ... }` with `+attr`, `+method()` members
//!   members:       `User : +String id`, `User : +login()`
//!   declarations:  `class User`
//!   relationships: inheritance `<|--` / `--|>`, composition `*--` / `--*`,
//!                  aggregation `o--` / `--o`, association `-->` / `<--` / `--`,
//!                  dependency `..>` / `<..`, realization `..|>` / `<|..`,
//!                  each with an optional `: label`
//!   comments:      `%% ...`
//!
//! Members containing `()` go in the methods compartment, others in attributes.
//! Generics, annotations, namespaces, and multiplicities are not yet supported.
//! Note: aggregation `o--`/`--o` needs a space before/after the `o` (otherwise it
//! reads as part of a class id). Syntax errors return `error.MermaidSyntax`.

const std = @import("std");
const graph = @import("../ir/graph.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const ClassResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: graph.GraphDiagram,

    pub fn deinit(self: *ClassResult) void {
        self.arena.deinit();
    }
};

pub fn parseClass(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!ClassResult {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);

    return .{ .arena = arena_state, .diagram = diagram };
}

const ClassData = struct {
    id: []const u8,
    attrs: std.ArrayList([]const u8) = .empty,
    methods: std.ArrayList([]const u8) = .empty,
};

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    classes: std.ArrayList(ClassData) = .empty,
    edges: std.ArrayList(graph.Edge) = .empty,
    index: std.StringHashMapUnmanaged(graph.NodeId) = .empty,
    open_class: ?graph.NodeId = null,

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
                if (!std.mem.eql(u8, trimmed, "classDiagram")) {
                    return self.fail(.missing_header, line_no, 1, "expected 'classDiagram' header");
                }
                seen_header = true;
                continue;
            }

            try self.parseStatement(trimmed, line_no);
        }

        if (!seen_header) return self.fail(.missing_header, 1, 1, "expected 'classDiagram' header");
        if (self.open_class != null) return self.fail(.unexpected_token, line_no, 1, "unclosed class block: expected '}'");

        return try self.materialize();
    }

    fn parseStatement(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        // Inside a `class X { ... }` block, every line is a member until `}`.
        if (self.open_class) |cid| {
            if (std.mem.eql(u8, line, "}")) {
                self.open_class = null;
                return;
            }
            return self.addMember(cid, line);
        }

        const first = firstWord(line);
        if (std.mem.eql(u8, first, "class")) {
            return self.parseClassDecl(std.mem.trim(u8, line[first.len..], " \t\r"), line_no);
        }

        // `LEFT OP RIGHT` relationship or `Name : member`.
        var i: usize = 0;
        skipSpaces(line, &i);
        const left = readIdent(line, &i);
        if (left.len == 0) return self.fail(.expected_node, line_no, 1, "expected a class name");
        skipSpaces(line, &i);

        if (i < line.len and line[i] == ':') {
            const member = std.mem.trim(u8, line[i + 1 ..], " \t\r");
            const cid = try self.upsertClass(left);
            return self.addMember(cid, member);
        }
        if (i < line.len and isOpChar(line[i])) {
            return self.parseRelationship(left, line, &i, line_no);
        }
        if (i >= line.len) {
            _ = try self.upsertClass(left); // a bare class name declares it
            return;
        }
        return self.fail(.unexpected_token, line_no, @intCast(i + 1), "expected ':', a relationship, or end of line");
    }

    fn parseClassDecl(self: *Parser, rest: []const u8, line_no: u32) ParseError!void {
        var name = rest;
        var opens_block = false;
        if (std.mem.endsWith(u8, name, "{")) {
            name = std.mem.trim(u8, name[0 .. name.len - 1], " \t\r");
            opens_block = true;
        }
        // Drop any generic/annotation suffix (e.g. `List~T~`) for v0.
        name = firstWord(name);
        if (name.len == 0) return self.fail(.expected_node, line_no, 1, "expected a class name after 'class'");

        const cid = try self.upsertClass(name);
        if (opens_block) self.open_class = cid;
    }

    fn parseRelationship(self: *Parser, left: []const u8, line: []const u8, i: *usize, line_no: u32) ParseError!void {
        const op_start = i.*;
        while (i.* < line.len and isOpChar(line[i.*])) : (i.* += 1) {}
        const op = line[op_start..i.*];
        skipSpaces(line, i);
        const right = readIdent(line, i);
        if (right.len == 0) return self.fail(.expected_node, line_no, @intCast(i.* + 1), "expected a class on the right of the relationship");
        skipSpaces(line, i);

        var label: ?[]const u8 = null;
        if (i.* < line.len and line[i.*] == ':') {
            label = std.mem.trim(u8, line[i.* + 1 ..], " \t\r");
        }

        const rel = classify(op) orelse return self.fail(.unexpected_token, line_no, @intCast(op_start + 1), "unrecognized class relationship operator");

        const left_id = try self.upsertClass(left);
        const right_id = try self.upsertClass(right);
        const from = if (rel.reverse) right_id else left_id;
        const to = if (rel.reverse) left_id else right_id;
        try self.edges.append(self.arena, .{
            .from = from,
            .to = to,
            .label = if (label) |l| try self.arena.dupe(u8, l) else null,
            .line = rel.line,
            .arrow = rel.arrow,
            .head_at_source = rel.head_at_source,
        });
    }

    fn addMember(self: *Parser, cid: graph.NodeId, text: []const u8) ParseError!void {
        const trimmed = std.mem.trim(u8, text, " \t\r");
        if (trimmed.len == 0) return;
        const owned = try self.arena.dupe(u8, trimmed);
        const class = &self.classes.items[cid];
        if (std.mem.indexOfScalar(u8, trimmed, '(') != null) {
            try class.methods.append(self.arena, owned);
        } else {
            try class.attrs.append(self.arena, owned);
        }
    }

    fn upsertClass(self: *Parser, name: []const u8) ParseError!graph.NodeId {
        const gop = try self.index.getOrPut(self.arena, name);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = try self.arena.dupe(u8, name);
        gop.key_ptr.* = owned;
        const id: graph.NodeId = @intCast(self.classes.items.len);
        gop.value_ptr.* = id;
        try self.classes.append(self.arena, .{ .id = owned });
        return id;
    }

    fn materialize(self: *Parser) ParseError!graph.GraphDiagram {
        const nodes = try self.arena.alloc(graph.Node, self.classes.items.len);
        for (self.classes.items, 0..) |c, i| {
            var compartments: ?[]const graph.Compartment = null;
            if (c.attrs.items.len > 0 or c.methods.items.len > 0) {
                const comps = try self.arena.alloc(graph.Compartment, 2);
                comps[0] = try self.arena.dupe([]const u8, c.attrs.items);
                comps[1] = try self.arena.dupe([]const u8, c.methods.items);
                compartments = comps;
            }
            nodes[i] = .{
                .id = c.id,
                .label = c.id,
                .shape = .rect,
                .compartments = compartments,
            };
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
    arrow: graph.ArrowKind,
    line: graph.LineKind,
    /// Swap LEFT/RIGHT so `from` is the parent/whole (placed on top).
    reverse: bool,
    head_at_source: bool,
};

/// Classify a class-relationship operator. Hierarchy/containment ends
/// (triangle/diamond) define the parent/whole side, which becomes the edge source
/// (decoration drawn there). Plain arrows decorate the target.
fn classify(op: []const u8) ?Rel {
    if (op.len == 0) return null;
    const dashed = std.mem.indexOfScalar(u8, op, '.') != null;
    const line: graph.LineKind = if (dashed) .dotted else .solid;

    const left = endDecoration(op, true);
    const right = endDecoration(op, false);

    // Containment/hierarchy: parent side hosts a triangle or diamond.
    if (isContainment(left)) return .{ .arrow = left, .line = line, .reverse = false, .head_at_source = true };
    if (isContainment(right)) return .{ .arrow = right, .line = line, .reverse = true, .head_at_source = true };
    // Directed association/dependency: arrow at the target.
    if (right == .arrow) return .{ .arrow = .arrow, .line = line, .reverse = false, .head_at_source = false };
    if (left == .arrow) return .{ .arrow = .arrow, .line = line, .reverse = true, .head_at_source = false };
    // Plain line — must still be a recognized operator (only `-`/`.`).
    for (op) |c| {
        if (c != '-' and c != '.') return null;
    }
    return .{ .arrow = .none, .line = line, .reverse = false, .head_at_source = false };
}

fn isContainment(a: graph.ArrowKind) bool {
    return a == .triangle or a == .diamond or a == .diamond_filled;
}

fn endDecoration(op: []const u8, left: bool) graph.ArrowKind {
    if (left) {
        if (std.mem.startsWith(u8, op, "<|")) return .triangle;
        if (op[0] == '<') return .arrow;
        if (op[0] == '*') return .diamond_filled;
        if (op[0] == 'o') return .diamond;
        return .none;
    }
    if (std.mem.endsWith(u8, op, "|>")) return .triangle;
    const last = op[op.len - 1];
    if (last == '>') return .arrow;
    if (last == '*') return .diamond_filled;
    if (last == 'o') return .diamond;
    return .none;
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

fn isOpChar(c: u8) bool {
    return c == '<' or c == '>' or c == '|' or c == '*' or c == 'o' or c == '.' or c == '-';
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(source: []const u8) !ClassResult {
    var diag: ?MermaidError = null;
    return parseClass(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses a class block with attributes and methods" {
    var r = try parseForTest(
        \\classDiagram
        \\    class User {
        \\      +String id
        \\      +login()
        \\    }
    );
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.diagram.nodes.len);
    const comps = r.diagram.nodes[0].compartments.?;
    try testing.expectEqual(@as(usize, 2), comps.len);
    try testing.expectEqualStrings("+String id", comps[0][0]); // attributes
    try testing.expectEqualStrings("+login()", comps[1][0]); // methods
}

test "member declarations outside a block" {
    var r = try parseForTest(
        \\classDiagram
        \\    User : +String id
        \\    User : +login()
    );
    defer r.deinit();
    const comps = r.diagram.nodes[0].compartments.?;
    try testing.expectEqualStrings("+String id", comps[0][0]);
    try testing.expectEqualStrings("+login()", comps[1][0]);
}

test "inheritance puts the parent on top with a triangle at the source" {
    var r = try parseForTest(
        \\classDiagram
        \\    User <|-- Admin
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    const e = r.diagram.edges[0];
    try testing.expectEqual(graph.ArrowKind.triangle, e.arrow);
    try testing.expect(e.head_at_source);
    // `User <|-- Admin`: User is the parent → edge source.
    try testing.expectEqualStrings("User", r.diagram.nodes[e.from].id);
    try testing.expectEqualStrings("Admin", r.diagram.nodes[e.to].id);
}

test "association arrow decorates the target" {
    var r = try parseForTest("classDiagram\n User --> Session\n");
    defer r.deinit();
    const e = r.diagram.edges[0];
    try testing.expectEqual(graph.ArrowKind.arrow, e.arrow);
    try testing.expect(!e.head_at_source);
    try testing.expectEqualStrings("Session", r.diagram.nodes[e.to].id);
}

test "composition, aggregation, dependency, realization" {
    var r = try parseForTest(
        \\classDiagram
        \\    Car *-- Engine
        \\    Library o-- Book
        \\    Order ..> Payment
        \\    Admin ..|> Role
    );
    defer r.deinit();
    try testing.expectEqual(graph.ArrowKind.diamond_filled, r.diagram.edges[0].arrow);
    try testing.expectEqual(graph.ArrowKind.diamond, r.diagram.edges[1].arrow);
    try testing.expectEqual(graph.ArrowKind.arrow, r.diagram.edges[2].arrow);
    try testing.expectEqual(graph.LineKind.dotted, r.diagram.edges[2].line);
    try testing.expectEqual(graph.ArrowKind.triangle, r.diagram.edges[3].arrow);
    try testing.expectEqual(graph.LineKind.dotted, r.diagram.edges[3].line);
}

test "relationship label is captured" {
    var r = try parseForTest("classDiagram\n User --> Session : owns\n");
    defer r.deinit();
    try testing.expectEqualStrings("owns", r.diagram.edges[0].label.?);
}

test "a class with no members renders as a plain box" {
    var r = try parseForTest("classDiagram\n class Empty\n");
    defer r.deinit();
    try testing.expect(r.diagram.nodes[0].compartments == null);
}

test "rejects a missing header" {
    var diag: ?MermaidError = null;
    const r = parseClass(testing.allocator, "class A\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
}

test "rejects an unclosed class block" {
    var diag: ?MermaidError = null;
    const r = parseClass(testing.allocator, "classDiagram\n class A {\n +x\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
}
