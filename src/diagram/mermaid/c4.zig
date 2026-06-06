//! Parser for the real Mermaid C4 diagram syntax (C4Context / C4Container /
//! C4Component / C4Dynamic / C4Deployment). C4 is a graph-layout diagram, so this
//! lowers to the shared graph IR — elements become compartment "card" nodes and
//! `Rel(...)` calls become edges — and reuses the layered layout and card
//! renderer.
//!
//! Syntax is function-call form: `Keyword(alias, "label", "tech?", "descr?", ...)`.
//! Supported:
//!   elements:    Person, System(+Db/Queue), Container, Component, Node and their
//!                _Ext variants (and any unknown `Keyword(alias,"label",...)` as a
//!                generic element). First arg is the (bare) alias; the rest are
//!                quoted strings; `$tags`/`$link`/`?sprite` named args are ignored.
//!   relations:   Rel, BiRel, Rel_Back, Rel_U/D/L/R (and _Up/_Down/_Left/_Right),
//!                RelIndex — `Rel(from, to, "label", "tech?")`.
//!   boundaries:  Boundary / *_Boundary / Enterprise_Boundary / Deployment_Node /
//!                Node with a trailing `{ ... }` — parsed and flattened (contents
//!                kept; the grouping box is not drawn in v0).
//!   directives:  UpdateElementStyle / UpdateRelStyle / UpdateLayoutConfig / title
//!                are ignored.
//!
//! Not yet rendered: boundary boxes, sprites/icons, and per-relationship
//! direction hints (Rel_U/D/L/R lay out like Rel). Syntax errors return
//! `error.MermaidSyntax`.

const std = @import("std");
const graph = @import("../ir/graph.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const C4Result = struct {
    arena: std.heap.ArenaAllocator,
    diagram: graph.GraphDiagram,

    pub fn deinit(self: *C4Result) void {
        self.arena.deinit();
    }
};

pub fn parseC4(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!C4Result {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);

    return .{ .arena = arena_state, .diagram = diagram };
}

pub fn isHeader(word: []const u8) bool {
    return std.mem.eql(u8, word, "C4Context") or
        std.mem.eql(u8, word, "C4Container") or
        std.mem.eql(u8, word, "C4Component") or
        std.mem.eql(u8, word, "C4Dynamic") or
        std.mem.eql(u8, word, "C4Deployment");
}

const ElementData = struct {
    id: []const u8,
    label: []const u8,
    stereotype: []const u8,
    tech: ?[]const u8 = null,
    descr: ?[]const u8 = null,
    cluster: ?graph.ClusterId = null,
};

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    elements: std.ArrayList(ElementData) = .empty,
    edges: std.ArrayList(graph.Edge) = .empty,
    index: std.StringHashMapUnmanaged(graph.NodeId) = .empty,
    clusters: std.ArrayList(graph.Cluster) = .empty,
    /// Open boundaries, innermost last. A boundary becomes a cluster box.
    boundary_stack: std.ArrayList(graph.ClusterId) = .empty,

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
                    return self.fail(.missing_header, line_no, 1, "expected a C4 diagram header (C4Context, C4Container, ...)");
                }
                seen_header = true;
                continue;
            }

            try self.parseStatement(trimmed, line_no);
        }

        if (!seen_header) return self.fail(.missing_header, 1, 1, "expected a C4 diagram header");
        if (self.boundary_stack.items.len != 0) return self.fail(.unexpected_token, line_no, 1, "unclosed boundary: expected '}'");

        return try self.materialize();
    }

    fn currentBoundary(self: *Parser) ?graph.ClusterId {
        const n = self.boundary_stack.items.len;
        return if (n == 0) null else self.boundary_stack.items[n - 1];
    }

    fn parseStatement(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        if (std.mem.eql(u8, line, "}")) {
            if (self.boundary_stack.items.len == 0) return self.fail(.unexpected_token, line_no, 1, "'}' without an open boundary");
            _ = self.boundary_stack.pop();
            return;
        }

        const kw = readKeyword(line);
        if (kw.len == 0) return self.fail(.unexpected_token, line_no, 1, "expected a C4 statement");

        if (isDirective(kw)) return; // styling/layout/title — ignored

        const call = parseCall(line, kw.len) orelse {
            // `title some text` etc. without parens — ignore unknown bare lines.
            return;
        };

        if (isRel(kw)) return self.parseRel(kw, call.args, line_no);

        // A trailing `{` makes this a boundary / container: open a cluster.
        if (call.opens_block) return self.parseBoundary(call.args);

        return self.parseElement(kw, call.args, line_no);
    }

    fn parseBoundary(self: *Parser, args: []const u8) ParseError!void {
        var bares: [4][]const u8 = undefined;
        var quoted: [6][]const u8 = undefined;
        var nb: usize = 0;
        var nq: usize = 0;
        try collectArgs(args, &bares, &nb, &quoted, &nq);

        const alias = if (nb > 0) bares[0] else if (nq > 0) quoted[0] else "boundary";
        const label = if (nq > 0) quoted[0] else alias;
        const cid: graph.ClusterId = @intCast(self.clusters.items.len);
        try self.clusters.append(self.arena, .{
            .id = try self.arena.dupe(u8, alias),
            .label = try self.arena.dupe(u8, label),
            .parent = self.currentBoundary(),
        });
        try self.boundary_stack.append(self.arena, cid);
    }

    fn parseElement(self: *Parser, kw: []const u8, args: []const u8, line_no: u32) ParseError!void {
        var bares: [4][]const u8 = undefined;
        var quoted: [6][]const u8 = undefined;
        var nb: usize = 0;
        var nq: usize = 0;
        try collectArgs(args, &bares, &nb, &quoted, &nq);

        if (nb == 0) return self.fail(.expected_node, line_no, 1, "expected an element alias");
        const alias = bares[0];
        const stereo = stereotype(kw);
        const label = if (nq > 0) quoted[0] else alias;

        var tech: ?[]const u8 = null;
        var descr: ?[]const u8 = null;
        if (stereo.has_tech) {
            if (nq > 1) tech = quoted[1];
            if (nq > 2) descr = quoted[2];
        } else {
            if (nq > 1) descr = quoted[1];
        }

        const id = try self.upsertElement(alias);
        const e = &self.elements.items[id];
        e.cluster = self.currentBoundary();
        e.label = try self.arena.dupe(u8, label);
        e.stereotype = if (stereo.external)
            try std.fmt.allocPrint(self.arena, "External {s}", .{stereo.name})
        else
            try self.arena.dupe(u8, stereo.name);
        if (tech) |t| e.tech = try self.arena.dupe(u8, t);
        if (descr) |d| e.descr = try self.arena.dupe(u8, d);
    }

    fn parseRel(self: *Parser, kw: []const u8, args: []const u8, line_no: u32) ParseError!void {
        var bares: [4][]const u8 = undefined;
        var quoted: [6][]const u8 = undefined;
        var nb: usize = 0;
        var nq: usize = 0;
        try collectArgs(args, &bares, &nb, &quoted, &nq);

        // RelIndex(index, from, to, ...) — the leading index is a bare number.
        var fi: usize = 0;
        if (std.mem.eql(u8, kw, "RelIndex") and nb >= 3) fi = 1;
        if (nb < fi + 2) return self.fail(.expected_node, line_no, 1, "a relationship needs a source and target");

        const from = try self.upsertElement(bares[fi]);
        const to = try self.upsertElement(bares[fi + 1]);
        const label = if (nq > 0) quoted[0] else null;
        try self.edges.append(self.arena, .{
            .from = from,
            .to = to,
            .label = if (label) |l| try self.arena.dupe(u8, l) else null,
            .line = .solid,
            .arrow = .arrow,
        });
    }

    fn upsertElement(self: *Parser, alias: []const u8) ParseError!graph.NodeId {
        const gop = try self.index.getOrPut(self.arena, alias);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = try self.arena.dupe(u8, alias);
        gop.key_ptr.* = owned;
        const id: graph.NodeId = @intCast(self.elements.items.len);
        gop.value_ptr.* = id;
        try self.elements.append(self.arena, .{ .id = owned, .label = owned, .stereotype = "" });
        return id;
    }

    fn materialize(self: *Parser) ParseError!graph.GraphDiagram {
        const nodes = try self.arena.alloc(graph.Node, self.elements.items.len);
        for (self.elements.items, 0..) |e, i| {
            var lines = std.ArrayList([]const u8).empty;
            if (e.stereotype.len > 0) {
                const stereo_line = if (e.tech) |t|
                    try std.fmt.allocPrint(self.arena, "[{s}: {s}]", .{ e.stereotype, t })
                else
                    try std.fmt.allocPrint(self.arena, "[{s}]", .{e.stereotype});
                try lines.append(self.arena, stereo_line);
            }
            if (e.descr) |d| try lines.append(self.arena, d);

            var compartments: ?[]const graph.Compartment = null;
            if (lines.items.len > 0) {
                const comps = try self.arena.alloc(graph.Compartment, 1);
                comps[0] = try lines.toOwnedSlice(self.arena);
                compartments = comps;
            }
            nodes[i] = .{ .id = e.id, .label = e.label, .shape = .rect, .compartments = compartments, .cluster = e.cluster };
        }
        return .{
            .direction = .tb,
            .nodes = nodes,
            .edges = try self.edges.toOwnedSlice(self.arena),
            .clusters = try self.clusters.toOwnedSlice(self.arena),
        };
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }
};

const Call = struct { args: []const u8, opens_block: bool };

/// Parse `(...)` starting after the keyword, returning the inner argument text
/// and whether a `{` follows (a boundary/container open). Null if no `(`.
fn parseCall(line: []const u8, kw_len: usize) ?Call {
    var i = kw_len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len or line[i] != '(') return null;
    i += 1;
    const start = i;
    var in_quote = false;
    var depth: u32 = 1;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') {
            in_quote = !in_quote;
        } else if (!in_quote and c == '(') {
            depth += 1;
        } else if (!in_quote and c == ')') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (i >= line.len) return null; // unterminated
    const args = line[start..i];
    const rest = std.mem.trim(u8, line[i + 1 ..], " \t\r");
    return .{ .args = args, .opens_block = std.mem.indexOfScalar(u8, rest, '{') != null };
}

/// Split argument text on top-level commas (respecting quotes), classifying each
/// into bare (ids/numbers) and quoted (strings). `$named`/`x=...` args are
/// dropped. Caller passes fixed buffers; extras beyond capacity are ignored.
fn collectArgs(
    args: []const u8,
    bares: *[4][]const u8,
    nb: *usize,
    quoted: *[6][]const u8,
    nq: *usize,
) ParseError!void {
    var i: usize = 0;
    while (i < args.len) {
        // one argument up to the next top-level comma
        while (i < args.len and (args[i] == ' ' or args[i] == '\t')) : (i += 1) {}
        const start = i;
        var in_quote = false;
        while (i < args.len) : (i += 1) {
            const c = args[i];
            if (c == '"') in_quote = !in_quote else if (!in_quote and c == ',') break;
        }
        const piece = std.mem.trim(u8, args[start..i], " \t\r");
        if (i < args.len) i += 1; // skip comma

        if (piece.len == 0) continue;
        if (piece[0] == '$' or std.mem.indexOfScalar(u8, piece, '=') != null) continue; // named/styling
        if (piece[0] == '"') {
            const inner = if (piece.len >= 2 and piece[piece.len - 1] == '"') piece[1 .. piece.len - 1] else piece[1..];
            if (nq.* < quoted.len) {
                quoted[nq.*] = inner;
                nq.* += 1;
            }
        } else {
            if (nb.* < bares.len) {
                bares[nb.*] = piece;
                nb.* += 1;
            }
        }
    }
}

const Stereotype = struct { name: []const u8, has_tech: bool, external: bool };

fn stereotype(kw: []const u8) Stereotype {
    var base = kw;
    var external = false;
    if (std.mem.endsWith(u8, base, "_Ext")) {
        external = true;
        base = base[0 .. base.len - 4];
    }
    const name: []const u8 = if (startsWith(base, "Person"))
        "Person"
    else if (startsWith(base, "System"))
        "System"
    else if (startsWith(base, "Container"))
        "Container"
    else if (startsWith(base, "Component"))
        "Component"
    else if (std.mem.eql(u8, base, "Node") or std.mem.eql(u8, base, "Deployment_Node"))
        "Node"
    else
        base;
    const has_tech = startsWith(base, "Container") or startsWith(base, "Component") or
        std.mem.eql(u8, base, "Node") or std.mem.eql(u8, base, "Deployment_Node");
    return .{ .name = name, .has_tech = has_tech, .external = external };
}

fn isRel(kw: []const u8) bool {
    return std.mem.eql(u8, kw, "Rel") or std.mem.eql(u8, kw, "BiRel") or
        std.mem.eql(u8, kw, "Rel_Back") or std.mem.eql(u8, kw, "RelIndex") or
        startsWith(kw, "Rel_");
}

fn isDirective(kw: []const u8) bool {
    return std.mem.eql(u8, kw, "UpdateElementStyle") or std.mem.eql(u8, kw, "UpdateRelStyle") or
        std.mem.eql(u8, kw, "UpdateLayoutConfig") or std.mem.eql(u8, kw, "title");
}

fn readKeyword(line: []const u8) []const u8 {
    var end: usize = 0;
    while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) : (end += 1) {}
    return line[0..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "%%")) |pos| return line[0..pos];
    return line;
}

fn firstWord(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '\r') : (end += 1) {}
    return s[0..end];
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(source: []const u8) !C4Result {
    var diag: ?MermaidError = null;
    return parseC4(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses real C4 Person/System/Rel syntax" {
    var r = try parseForTest(
        \\C4Context
        \\    Person(user, "Banking Customer", "A customer of the bank")
        \\    System(sys, "Internet Banking", "Lets customers view accounts")
        \\    Rel(user, sys, "Uses", "HTTPS")
    );
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    try testing.expectEqualStrings("Banking Customer", r.diagram.nodes[0].label);
    try testing.expectEqualStrings("[Person]", r.diagram.nodes[0].compartments.?[0][0]);
    try testing.expectEqualStrings("A customer of the bank", r.diagram.nodes[0].compartments.?[0][1]);
    try testing.expectEqualStrings("Uses", r.diagram.edges[0].label.?);
    try testing.expectEqual(graph.ArrowKind.arrow, r.diagram.edges[0].arrow);
}

test "container technology lands in the stereotype line" {
    var r = try parseForTest(
        \\C4Container
        \\    Container(api, "API", "Zig", "Renders diagrams")
    );
    defer r.deinit();
    try testing.expectEqualStrings("[Container: Zig]", r.diagram.nodes[0].compartments.?[0][0]);
    try testing.expectEqualStrings("Renders diagrams", r.diagram.nodes[0].compartments.?[0][1]);
}

test "external variants are marked in the stereotype" {
    var r = try parseForTest(
        \\C4Context
        \\    System_Ext(email, "E-mail", "Sendmail")
    );
    defer r.deinit();
    try testing.expectEqualStrings("[External System]", r.diagram.nodes[0].compartments.?[0][0]);
}

test "boundaries become nested clusters holding their members" {
    var r = try parseForTest(
        \\C4Context
        \\    Enterprise_Boundary(b0, "Bank") {
        \\        System(s1, "Core")
        \\        System_Boundary(b1, "Internal") {
        \\            System(s2, "Ledger")
        \\        }
        \\    }
        \\    Rel(s1, s2, "writes")
    );
    defer r.deinit();
    // Two systems are nodes; the two boundaries are nested clusters.
    try testing.expectEqual(@as(usize, 2), r.diagram.nodes.len);
    try testing.expectEqual(@as(usize, 1), r.diagram.edges.len);
    try testing.expectEqual(@as(usize, 2), r.diagram.clusters.len);
    try testing.expectEqualStrings("Bank", r.diagram.clusters[0].label);
    try testing.expectEqual(@as(?graph.ClusterId, null), r.diagram.clusters[0].parent);
    try testing.expectEqualStrings("Internal", r.diagram.clusters[1].label);
    try testing.expectEqual(@as(?graph.ClusterId, 0), r.diagram.clusters[1].parent);
    // s1 sits directly in Bank; s2 sits in the nested Internal boundary.
    try testing.expectEqual(@as(?graph.ClusterId, 0), r.diagram.nodes[0].cluster);
    try testing.expectEqual(@as(?graph.ClusterId, 1), r.diagram.nodes[1].cluster);
}

test "styling directives and named args are ignored" {
    var r = try parseForTest(
        \\C4Context
        \\    Person(user, "User", $tags="v1")
        \\    UpdateElementStyle(user, $bgColor="red")
        \\    UpdateLayoutConfig($c4ShapeInRow="3")
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagram.nodes.len);
    try testing.expectEqual(@as(usize, 0), r.diagram.edges.len);
    try testing.expectEqualStrings("User", r.diagram.nodes[0].label);
}

test "directional and bidirectional rels parse" {
    var r = try parseForTest(
        \\C4Context
        \\    System(a, "A")
        \\    System(b, "B")
        \\    Rel_D(a, b, "down")
        \\    BiRel(a, b, "both")
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagram.edges.len);
    try testing.expectEqualStrings("down", r.diagram.edges[0].label.?);
}

test "rejects a missing header" {
    var diag: ?MermaidError = null;
    const r = parseC4(testing.allocator, "Person(a, \"A\")\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
}

test "rejects an unclosed boundary" {
    var diag: ?MermaidError = null;
    const r = parseC4(testing.allocator, "C4Context\n System_Boundary(b, \"B\") {\n System(s, \"S\")\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
}
