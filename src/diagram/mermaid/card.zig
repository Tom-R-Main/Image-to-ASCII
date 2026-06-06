//! Line-based parser for a small card-diagram subset. This is the practical
//! requirement / architecture / C4-style frontend for LLM-editable diagrams:
//! cards lower to graph-IR compartment nodes, and relationships lower to graph
//! edges, so layout and rendering reuse the existing graph card renderer.
//!
//! Supported subset (v0):
//!   headers:       `cardDiagram`, `requirementDiagram`
//!                  (real C4 and architecture-beta have dedicated parsers)
//!   direction:     `direction TB|TD|LR|RL|BT`
//!   card blocks:   `component API "API service" { ... }`
//!                  `requirement Req1 [Must render plans] { ... }`
//!   card kinds:    `card`, `requirement`, `element`, `person`, `system`,
//!                  `container`, `component`, `database`, `queue`
//!   relations:     `A --> B : label`, `A -- B`, `A ..> B`
//!                  `A - satisfies -> B`
//!   comments:      `%% ...`
//!
//! Block body lines are kept verbatim as one compartment under the card header.
//! This keeps the input simple enough for agents to manipulate while preserving
//! semantic text such as `risk: high`, `status: proposed`, or `tech: Zig`.

const std = @import("std");
const graph = @import("../ir/graph.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const CardResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: graph.GraphDiagram,

    pub fn deinit(self: *CardResult) void {
        self.arena.deinit();
    }
};

pub fn parseCard(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!CardResult {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);

    return .{ .arena = arena_state, .diagram = diagram };
}

pub fn isHeader(word: []const u8) bool {
    // Only the headers this generic grammar genuinely parses. Real C4 and
    // architecture-beta have dedicated parsers (function-call / port-edge syntax).
    return std.mem.eql(u8, word, "cardDiagram") or
        std.mem.eql(u8, word, "requirementDiagram");
}

const CardData = struct {
    id: []const u8,
    label: []const u8,
    kind: ?[]const u8 = null,
    lines: std.ArrayList([]const u8) = .empty,
};

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    direction: graph.Direction = .tb,
    cards: std.ArrayList(CardData) = .empty,
    edges: std.ArrayList(graph.Edge) = .empty,
    index: std.StringHashMapUnmanaged(graph.NodeId) = .empty,
    open_card: ?graph.NodeId = null,

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
                const word = firstWord(trimmed);
                if (!isHeader(word)) {
                    return self.fail(.missing_header, line_no, 1, "expected a card diagram header");
                }
                seen_header = true;
                continue;
            }

            try self.parseStatement(trimmed, line_no);
        }

        if (!seen_header) return self.fail(.missing_header, 1, 1, "expected a card diagram header");
        if (self.open_card != null) return self.fail(.unexpected_token, line_no, 1, "unclosed card block: expected '}'");

        return try self.materialize();
    }

    fn parseStatement(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        if (self.open_card) |cid| {
            if (std.mem.eql(u8, line, "}")) {
                self.open_card = null;
                return;
            }
            return self.addLine(cid, line);
        }

        const first = firstWord(line);
        if (std.mem.eql(u8, first, "direction")) {
            const dir = std.mem.trim(u8, line[first.len..], " \t\r");
            self.direction = parseDirection(dir) orelse
                return self.fail(.invalid_direction, line_no, 1, "expected a direction: TB, TD, LR, RL, or BT");
            return;
        }
        if (isCardKind(first)) {
            return self.parseCardDecl(first, std.mem.trim(u8, line[first.len..], " \t\r"), line_no);
        }
        return self.parseRelationship(line, line_no);
    }

    fn parseCardDecl(self: *Parser, kind: []const u8, rest: []const u8, line_no: u32) ParseError!void {
        var i: usize = 0;
        skipSpaces(rest, &i);
        const id = readIdent(rest, &i);
        if (id.len == 0) return self.fail(.expected_node, line_no, 1, "expected a card id after the card kind");

        const cid = try self.upsertCard(id, kind);
        skipSpaces(rest, &i);

        if (i < rest.len and rest[i] == '"') {
            const label = try self.readQuoted(rest, &i, line_no);
            self.cards.items[cid].label = try self.arena.dupe(u8, label);
            skipSpaces(rest, &i);
        } else if (i < rest.len and rest[i] == '[') {
            const label = try self.readBracketed(rest, &i, line_no);
            self.cards.items[cid].label = try self.arena.dupe(u8, label);
            skipSpaces(rest, &i);
        }

        if (i < rest.len and rest[i] == '{') {
            self.open_card = cid;
            i += 1;
            skipSpaces(rest, &i);
        }
        if (i != rest.len) {
            return self.fail(.unexpected_token, line_no, @intCast(i + 1), "expected an optional label and '{'");
        }
    }

    fn parseRelationship(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        var i: usize = 0;
        skipSpaces(line, &i);
        const left = readIdent(line, &i);
        if (left.len == 0) return self.fail(.expected_node, line_no, 1, "expected a card id");
        skipSpaces(line, &i);

        if (i < line.len and !std.mem.startsWith(u8, line[i..], "-->") and line[i] == '-') {
            return self.parseNamedArrow(left, line, &i, line_no);
        }

        const rel = readRelationOp(line, &i) orelse
            return self.fail(.unexpected_token, line_no, @intCast(i + 1), "expected a relationship operator");
        skipSpaces(line, &i);
        const right = readIdent(line, &i);
        if (right.len == 0) return self.fail(.expected_node, line_no, @intCast(i + 1), "expected a card id after the relationship");
        skipSpaces(line, &i);

        var label: ?[]const u8 = null;
        if (i < line.len and line[i] == ':') {
            label = std.mem.trim(u8, line[i + 1 ..], " \t\r");
            i = line.len;
        }
        if (i != line.len) return self.fail(.unexpected_token, line_no, @intCast(i + 1), "expected ': label' or end of line");

        const from = try self.upsertCard(left, null);
        const to = try self.upsertCard(right, null);
        try self.edges.append(self.arena, .{
            .from = from,
            .to = to,
            .label = if (label) |l| try self.arena.dupe(u8, l) else null,
            .line = rel.line,
            .arrow = rel.arrow,
        });
    }

    fn parseNamedArrow(self: *Parser, left: []const u8, line: []const u8, i: *usize, line_no: u32) ParseError!void {
        i.* += 1; // leading '-'
        const arrow_pos = std.mem.indexOf(u8, line[i.*..], "->") orelse
            return self.fail(.unexpected_token, line_no, @intCast(i.* + 1), "expected '->' in named relationship");
        const label = std.mem.trim(u8, line[i.* .. i.* + arrow_pos], " \t\r-");
        i.* += arrow_pos + 2;
        skipSpaces(line, i);
        const right = readIdent(line, i);
        if (right.len == 0) return self.fail(.expected_node, line_no, @intCast(i.* + 1), "expected a card id after '->'");
        skipSpaces(line, i);
        if (i.* != line.len) return self.fail(.unexpected_token, line_no, @intCast(i.* + 1), "expected end of line");

        const from = try self.upsertCard(left, null);
        const to = try self.upsertCard(right, null);
        try self.edges.append(self.arena, .{
            .from = from,
            .to = to,
            .label = if (label.len > 0) try self.arena.dupe(u8, label) else null,
            .line = .solid,
            .arrow = .arrow,
        });
    }

    fn readQuoted(self: *Parser, rest: []const u8, i: *usize, line_no: u32) ParseError![]const u8 {
        std.debug.assert(rest[i.*] == '"');
        const start = i.* + 1;
        const end_rel = std.mem.indexOfScalar(u8, rest[start..], '"') orelse
            return self.fail(.unterminated_label, line_no, @intCast(i.* + 1), "unterminated quoted card label");
        const end = start + end_rel;
        i.* = end + 1;
        return rest[start..end];
    }

    fn readBracketed(self: *Parser, rest: []const u8, i: *usize, line_no: u32) ParseError![]const u8 {
        std.debug.assert(rest[i.*] == '[');
        const start = i.* + 1;
        const end_rel = std.mem.indexOfScalar(u8, rest[start..], ']') orelse
            return self.fail(.unterminated_label, line_no, @intCast(i.* + 1), "unterminated bracketed card label");
        const end = start + end_rel;
        i.* = end + 1;
        return rest[start..end];
    }

    fn addLine(self: *Parser, cid: graph.NodeId, text: []const u8) ParseError!void {
        const trimmed = std.mem.trim(u8, text, " \t\r");
        if (trimmed.len == 0) return;
        try self.cards.items[cid].lines.append(self.arena, try self.arena.dupe(u8, trimmed));
    }

    fn upsertCard(self: *Parser, name: []const u8, kind: ?[]const u8) ParseError!graph.NodeId {
        const gop = try self.index.getOrPut(self.arena, name);
        if (gop.found_existing) {
            const id = gop.value_ptr.*;
            if (kind) |k| {
                if (self.cards.items[id].kind == null) self.cards.items[id].kind = try self.arena.dupe(u8, k);
            }
            return id;
        }

        const owned = try self.arena.dupe(u8, name);
        gop.key_ptr.* = owned;
        const id: graph.NodeId = @intCast(self.cards.items.len);
        gop.value_ptr.* = id;
        try self.cards.append(self.arena, .{
            .id = owned,
            .label = owned,
            .kind = if (kind) |k| try self.arena.dupe(u8, k) else null,
        });
        return id;
    }

    fn materialize(self: *Parser) ParseError!graph.GraphDiagram {
        const nodes = try self.arena.alloc(graph.Node, self.cards.items.len);
        for (self.cards.items, 0..) |c, i| {
            var compartments: ?[]const graph.Compartment = null;
            const extra: usize = if (c.kind != null) 1 else 0;
            if (extra + c.lines.items.len > 0) {
                const comps = try self.arena.alloc(graph.Compartment, 1);
                const lines = try self.arena.alloc([]const u8, extra + c.lines.items.len);
                var out_i: usize = 0;
                if (c.kind) |kind| {
                    lines[out_i] = try std.fmt.allocPrint(self.arena, "kind: {s}", .{kind});
                    out_i += 1;
                }
                for (c.lines.items) |line| {
                    lines[out_i] = line;
                    out_i += 1;
                }
                comps[0] = lines;
                compartments = comps;
            }
            nodes[i] = .{
                .id = c.id,
                .label = c.label,
                .shape = .rect,
                .compartments = compartments,
            };
        }
        return .{
            .direction = self.direction,
            .nodes = nodes,
            .edges = try self.edges.toOwnedSlice(self.arena),
        };
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }
};

const Relation = struct {
    line: graph.LineKind,
    arrow: graph.ArrowKind,
};

fn readRelationOp(line: []const u8, i: *usize) ?Relation {
    if (std.mem.startsWith(u8, line[i.*..], "-->")) {
        i.* += 3;
        return .{ .line = .solid, .arrow = .arrow };
    }
    if (std.mem.startsWith(u8, line[i.*..], "..>")) {
        i.* += 3;
        return .{ .line = .dotted, .arrow = .arrow };
    }
    if (std.mem.startsWith(u8, line[i.*..], "--")) {
        i.* += 2;
        return .{ .line = .solid, .arrow = .none };
    }
    if (std.mem.startsWith(u8, line[i.*..], "..")) {
        i.* += 2;
        return .{ .line = .dotted, .arrow = .none };
    }
    return null;
}

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

fn skipSpaces(line: []const u8, i: *usize) void {
    while (i.* < line.len and (line[i.*] == ' ' or line[i.*] == '\t' or line[i.*] == '\r')) : (i.* += 1) {}
}

fn readIdent(line: []const u8, i: *usize) []const u8 {
    const start = i.*;
    while (i.* < line.len and isIdentChar(line[i.*])) : (i.* += 1) {}
    return line[start..i.*];
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/';
}

fn isCardKind(word: []const u8) bool {
    return std.mem.eql(u8, word, "card") or
        std.mem.eql(u8, word, "requirement") or
        std.mem.eql(u8, word, "element") or
        std.mem.eql(u8, word, "person") or
        std.mem.eql(u8, word, "system") or
        std.mem.eql(u8, word, "container") or
        std.mem.eql(u8, word, "component") or
        std.mem.eql(u8, word, "database") or
        std.mem.eql(u8, word, "queue");
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

fn parseForTest(source: []const u8) !CardResult {
    var diag: ?MermaidError = null;
    return parseCard(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses component cards and a labeled edge" {
    var r = try parseForTest(
        \\cardDiagram
        \\ direction LR
        \\ component UI "Siftable TUI" {
        \\   layer: interface
        \\ }
        \\ component Renderer "Cell Render" {
        \\   tech: Zig
        \\ }
        \\ UI --> Renderer : workspace + diff
    );
    defer r.deinit();

    try testing.expectEqual(graph.Direction.lr, r.diagram.direction);
    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    try testing.expectEqualStrings("Siftable TUI", r.diagram.nodes[0].label);
    try testing.expectEqualStrings("kind: component", r.diagram.nodes[0].compartments.?[0][0]);
    try testing.expectEqualStrings("layer: interface", r.diagram.nodes[0].compartments.?[0][1]);
    try testing.expectEqualStrings("workspace + diff", r.diagram.edges[0].label.?);
}

test "parses requirement-style named relationships" {
    var r = try parseForTest(
        \\requirementDiagram
        \\ requirement REQ-1 [Render planning diagrams] {
        \\   risk: low
        \\   status: accepted
        \\ }
        \\ element Agent {
        \\   type: llm
        \\ }
        \\ Agent - satisfies -> REQ-1
    );
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    try testing.expectEqualStrings("Render planning diagrams", r.diagram.nodes[0].label);
    try testing.expectEqualStrings("satisfies", r.diagram.edges[0].label.?);
    try testing.expectEqual(graph.ArrowKind.arrow, r.diagram.edges[0].arrow);
}

test "rejects an unclosed card block" {
    var diag: ?MermaidError = null;
    const r = parseCard(testing.allocator, "cardDiagram\n card A {\n text: open\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
}

test "recognizes only the generic and requirement headers" {
    try testing.expect(isHeader("cardDiagram"));
    try testing.expect(isHeader("requirementDiagram"));
    // C4 and architecture have dedicated real-syntax parsers, not this one.
    try testing.expect(!isHeader("C4Context"));
    try testing.expect(!isHeader("architectureDiagram"));
    try testing.expect(!isHeader("architecture-beta"));
}
