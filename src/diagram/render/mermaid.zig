//! Front door for Mermaid rendering: sniffs the diagram header and dispatches to
//! the diagram backend. Lets one entry point (and the CLI) accept any supported
//! `.mmd` file.

const std = @import("std");
const core = @import("../../core.zig");
const cc = @import("../../canvas/cell_canvas.zig");
const errors = @import("../mermaid/errors.zig");
const card = @import("../mermaid/card.zig");
const c4 = @import("../mermaid/c4.zig");
const architecture = @import("../mermaid/architecture.zig");
const mindmap = @import("../mermaid/mindmap.zig");
const graph_renderer = @import("graph_renderer.zig");
const sequence_renderer = @import("sequence_renderer.zig");

pub const DiagramKind = enum { flowchart, sequence, state, class, er, card, c4, architecture, mindmap };

pub const MermaidRenderOptions = struct {
    glyph_set: cc.GlyphSet = .unicode_box,
    color: core.ColorMode = .truecolor,
};

pub const MermaidRenderError = graph_renderer.GraphRenderError ||
    sequence_renderer.SequenceRenderError ||
    errors.ParseError;

/// Identify the diagram type from the first meaningful line's keyword. Returns
/// null if no recognized header is present.
pub fn detectKind(source: []const u8) ?DiagramKind {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const line = if (std.mem.indexOf(u8, raw, "%%")) |p| raw[0..p] else raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const word = firstWord(trimmed);
        if (std.mem.eql(u8, word, "sequenceDiagram")) return .sequence;
        if (std.mem.eql(u8, word, "flowchart") or std.mem.eql(u8, word, "graph")) return .flowchart;
        if (std.mem.eql(u8, word, "stateDiagram") or std.mem.eql(u8, word, "stateDiagram-v2")) return .state;
        if (std.mem.eql(u8, word, "classDiagram")) return .class;
        if (std.mem.eql(u8, word, "erDiagram")) return .er;
        if (c4.isHeader(word)) return .c4;
        if (architecture.isHeader(word)) return .architecture;
        if (mindmap.isHeader(word)) return .mindmap;
        if (card.isHeader(word)) return .card;
        return null;
    }
    return null;
}

/// Parse and render any supported Mermaid diagram to a `Frame`. On a missing or
/// unrecognized header (or any syntax error) returns `error.MermaidSyntax` with
/// detail in `diagnostic`.
pub fn renderMermaid(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: MermaidRenderOptions,
    diagnostic: *?errors.MermaidError,
) MermaidRenderError!core.Frame {
    const kind = detectKind(source) orelse {
        diagnostic.* = .{
            .kind = .missing_header,
            .line = 1,
            .column = 1,
            .message = "expected a supported Mermaid diagram header",
        };
        return error.MermaidSyntax;
    };

    return switch (kind) {
        .flowchart => graph_renderer.renderMermaidFlowchart(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .sequence => sequence_renderer.renderMermaidSequence(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .state => graph_renderer.renderMermaidState(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .class => graph_renderer.renderMermaidClass(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .er => graph_renderer.renderMermaidEr(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .card => graph_renderer.renderMermaidCard(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .c4 => graph_renderer.renderMermaidC4(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .architecture => graph_renderer.renderMermaidArchitecture(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
        .mindmap => graph_renderer.renderMermaidMindmap(gpa, source, .{
            .glyph_set = options.glyph_set,
            .color = options.color,
        }, diagnostic),
    };
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

test "detects diagram kinds from the header" {
    try testing.expectEqual(DiagramKind.flowchart, detectKind("flowchart LR\n A --> B\n").?);
    try testing.expectEqual(DiagramKind.flowchart, detectKind("graph TD\n A --> B\n").?);
    try testing.expectEqual(DiagramKind.sequence, detectKind("sequenceDiagram\n A->>B: hi\n").?);
    try testing.expectEqual(DiagramKind.sequence, detectKind("%% note\n\nsequenceDiagram\n").?);
    try testing.expectEqual(DiagramKind.state, detectKind("stateDiagram-v2\n [*] --> A\n").?);
    try testing.expectEqual(DiagramKind.state, detectKind("stateDiagram\n A --> B\n").?);
    try testing.expectEqual(DiagramKind.class, detectKind("classDiagram\n class A\n").?);
    try testing.expectEqual(DiagramKind.er, detectKind("erDiagram\n A ||--o{ B\n").?);
    try testing.expectEqual(DiagramKind.card, detectKind("cardDiagram\n card A\n").?);
    try testing.expectEqual(DiagramKind.c4, detectKind("C4Context\n Person(a, \"A\")\n").?);
    try testing.expectEqual(DiagramKind.architecture, detectKind("architecture-beta\n group g(cloud)[G]\n").?);
    try testing.expectEqual(DiagramKind.mindmap, detectKind("mindmap\n  root\n").?);
    try testing.expect(detectKind("nonsense\n") == null);
    try testing.expect(detectKind("\n\n") == null);
}

test "renderMermaid dispatches to the flowchart backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "flowchart LR\n A --> B\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid dispatches to the sequence backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "sequenceDiagram\n A->>B: hi\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid dispatches to the state backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "stateDiagram-v2\n [*] --> A\n A --> [*]\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid dispatches to the class backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "classDiagram\n class A {\n +x\n }\n A --> B\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid dispatches to the ER backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "erDiagram\n CUSTOMER ||--o{ ORDER : places\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid dispatches to the card backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "cardDiagram\n component API \"API\"\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid dispatches to the C4 backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "C4Context\n Person(u, \"User\")\n System(s, \"Sys\")\n Rel(u, s, \"uses\")\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid dispatches to the architecture backend" {
    var diag: ?errors.MermaidError = null;
    var frame = try renderMermaid(testing.allocator, "architecture-beta\n group g(cloud)[G]\n service s(server)[S] in g\n s:R --> L:g\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
}

test "renderMermaid reports a missing header" {
    var diag: ?errors.MermaidError = null;
    const r = renderMermaid(testing.allocator, "A --> B\n", .{ .color = .none }, &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(errors.MermaidErrorKind.missing_header, diag.?.kind);
}
