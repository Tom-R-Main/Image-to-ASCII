//! Renders a laid-out graph (flowchart) onto a `CellCanvas` and exports a
//! `Frame`. This is the terminal-cell backend for the graph IR; it knows nothing
//! about Mermaid syntax and consumes only `GraphDiagram` + `Layout`.

const std = @import("std");
const core = @import("../../core.zig");
const cc = @import("../../canvas/cell_canvas.zig");
const text_measure = @import("../../canvas/text_measure.zig");
const ir = @import("../ir/graph.zig");
const layered = @import("../layout/layered.zig");
const flowchart = @import("../mermaid/flowchart.zig");

pub const GraphRenderOptions = struct {
    layout: layered.LayoutOptions = .{},
    glyph_set: cc.GlyphSet = .unicode_box,
    color: core.ColorMode = .truecolor,
    node_fg: core.Rgb8 = .{ .r = 235, .g = 235, .b = 235 },
    node_bg: core.Rgb8 = .{ .r = 0, .g = 0, .b = 0 },
    edge_fg: core.Rgb8 = .{ .r = 150, .g = 180, .b = 220 },
    edge_bg: core.Rgb8 = .{ .r = 0, .g = 0, .b = 0 },
};

pub const GraphRenderError = error{ OutOfMemory, InvalidUtf8, Overflow, NonOrthogonalLine };

/// Render an already-parsed graph diagram to a `Frame`.
pub fn renderGraph(
    gpa: std.mem.Allocator,
    diagram: ir.GraphDiagram,
    options: GraphRenderOptions,
) GraphRenderError!core.Frame {
    var lay = try layered.layoutFlowchart(gpa, diagram, options.layout);
    defer lay.deinit();

    var canvas = try cc.CellCanvas.init(gpa, lay.columns, lay.rows, options.color);
    defer canvas.deinit(gpa);

    const line_opts: cc.LineOptions = .{ .glyph_set = options.glyph_set, .fg = options.edge_fg, .bg = options.edge_bg };
    const arrow_opts: cc.ArrowOptions = .{ .glyph_set = options.glyph_set, .fg = options.edge_fg, .bg = options.edge_bg };
    const box_opts: cc.BoxOptions = .{ .glyph_set = options.glyph_set, .fg = options.node_fg, .bg = options.node_bg };
    const node_text: cc.TextOptions = .{ .fg = options.node_fg, .bg = options.node_bg };
    const edge_text: cc.TextOptions = .{ .fg = options.edge_fg, .bg = options.edge_bg };

    // 1. Edge lines first; node boxes drawn over them sit only in clear cells.
    for (lay.edges) |edge| {
        try drawPolyline(gpa, &canvas, edge.points, line_opts);
    }

    // 2. Node boxes and their labels.
    for (lay.nodes) |node| {
        try canvas.drawBox(toCanvasRect(node.rect), box_opts);
        try drawCenteredLabel(&canvas, node.rect, node.label, node_text);
    }

    // 3. Endpoint decorations (drawn last so they stay visible at box edges).
    for (lay.edges) |edge| {
        try drawDecoration(&canvas, edge, options.glyph_set, arrow_opts, edge_text);
    }

    // 4. Edge labels.
    for (lay.edges) |edge| {
        if (edge.label) |label| {
            if (edge.label_at) |at| try drawCenteredText(&canvas, at, label, edge_text);
        }
    }

    return canvas.toFrame(gpa);
}

/// Parse Mermaid flowchart source and render it to a `Frame`. On syntax error,
/// returns `error.MermaidSyntax` with detail written through `diagnostic`.
pub fn renderMermaidFlowchart(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: GraphRenderOptions,
    diagnostic: *?flowchart.MermaidError,
) (GraphRenderError || flowchart.ParseError)!core.Frame {
    var parsed = try flowchart.parseFlowchart(gpa, source, diagnostic);
    defer parsed.deinit();
    return renderGraph(gpa, parsed.diagram, options);
}

fn toCanvasRect(r: layered.Rect) cc.Rect {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

fn drawPolyline(gpa: std.mem.Allocator, canvas: *cc.CellCanvas, points: []const layered.Point, opts: cc.LineOptions) !void {
    if (points.len < 2) return;
    const cpts = try gpa.alloc(cc.Point, points.len);
    defer gpa.free(cpts);
    for (points, 0..) |p, i| cpts[i] = .{ .x = p.x, .y = p.y };
    try canvas.drawPolyline(cpts, opts);
}

fn drawCenteredLabel(canvas: *cc.CellCanvas, rect: layered.Rect, label: []const u8, opts: cc.TextOptions) !void {
    if (rect.width < 3) return;
    const interior: i32 = @intCast(rect.width - 2);
    const w: i32 = @intCast(text_measure.width(label) catch return);
    const pad = @max(@as(i32, 0), @divTrunc(interior - w, 2));
    const lx = rect.x + 1 + pad;
    const ly = rect.y + @divTrunc(@as(i32, @intCast(rect.height)), 2);
    try canvas.drawText(lx, ly, label, opts);
}

fn drawCenteredText(canvas: *cc.CellCanvas, at: layered.Point, text: []const u8, opts: cc.TextOptions) !void {
    const w: i32 = @intCast(text_measure.width(text) catch return);
    try canvas.drawText(at.x - @divTrunc(w, 2), at.y, text, opts);
}

fn drawDecoration(
    canvas: *cc.CellCanvas,
    edge: layered.RoutedEdge,
    glyph_set: cc.GlyphSet,
    arrow_opts: cc.ArrowOptions,
    text_opts: cc.TextOptions,
) !void {
    const points = edge.points;
    if (points.len < 2) return;
    const last = points[points.len - 1];

    // Walk back to the nearest distinct point to get the head direction.
    var prev = last;
    var i = points.len - 1;
    while (i > 0) {
        i -= 1;
        if (points[i].x != last.x or points[i].y != last.y) {
            prev = points[i];
            break;
        }
    }

    switch (edge.arrow) {
        .none => {},
        .arrow => try canvas.drawArrow(
            .{ .x = prev.x, .y = prev.y },
            .{ .x = last.x, .y = last.y },
            arrow_opts,
        ),
        .circle => try canvas.drawText(last.x, last.y, circleGlyph(glyph_set), text_opts),
        .cross => try canvas.drawText(last.x, last.y, crossGlyph(glyph_set), text_opts),
    }
}

fn circleGlyph(glyph_set: cc.GlyphSet) []const u8 {
    return switch (glyph_set) {
        .unicode_box => "\u{25CB}", // WHITE CIRCLE
        .ascii => "o",
    };
}

fn crossGlyph(glyph_set: cc.GlyphSet) []const u8 {
    return switch (glyph_set) {
        .unicode_box => "\u{00D7}", // MULTIPLICATION SIGN
        .ascii => "x",
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Render to an ASCII text grid for golden comparison (color off, ASCII glyphs).
fn renderToText(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var diag: ?flowchart.MermaidError = null;
    var frame = renderMermaidFlowchart(allocator, source, .{
        .glyph_set = .ascii,
        .color = .none,
    }, &diag) catch |err| {
        if (diag) |d| std.debug.print("render error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
    defer frame.deinit(allocator);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var row: u32 = 0;
    while (row < frame.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < frame.columns) : (col += 1) {
            const cp = frame.codepoints[row * frame.columns + col];
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch 1;
            try out.appendSlice(allocator, buf[0..len]);
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "renders a horizontal two-node flowchart" {
    const text = try renderToText(testing.allocator, "flowchart LR\n A[A] --> B[B]\n");
    defer testing.allocator.free(text);

    // Expect two boxes joined by an arrow; check structural landmarks.
    try testing.expect(std.mem.indexOf(u8, text, "+-") != null); // box corner
    try testing.expect(std.mem.indexOf(u8, text, ">") != null); // arrow head
    try testing.expect(std.mem.indexOf(u8, text, "A") != null);
    try testing.expect(std.mem.indexOf(u8, text, "B") != null);
}

test "renders a top-down chain with vertical connectors" {
    const text = try renderToText(testing.allocator, "flowchart TD\n A --> B\n");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "|") != null); // vertical edge
    try testing.expect(std.mem.indexOf(u8, text, "v") != null); // down arrow head
}

test "renders an edge label" {
    const text = try renderToText(testing.allocator, "flowchart TD\n A -->|yes| B\n");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "yes") != null);
}

test "renders circle and cross edge ends" {
    const text = try renderToText(testing.allocator, "flowchart LR\n A --o B\n");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "o") != null);
}

test "flowchart golden fixtures" {
    // testdata lives outside the src/ package so @embedFile can't reach it;
    // read fixtures at runtime relative to the build's working directory.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "testdata/mermaid/flowchart/";

    const bases = [_][]const u8{ "basic_lr", "labeled_edges", "diamond" };
    for (bases) |base| {
        const mmd_path = try std.fmt.allocPrint(testing.allocator, "{s}{s}.mmd", .{ dir, base });
        defer testing.allocator.free(mmd_path);
        const golden_path = try std.fmt.allocPrint(testing.allocator, "{s}{s}.golden.txt", .{ dir, base });
        defer testing.allocator.free(golden_path);

        const src = try std.Io.Dir.cwd().readFileAlloc(io, mmd_path, testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(src);
        const golden = try std.Io.Dir.cwd().readFileAlloc(io, golden_path, testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(golden);

        const got = try renderToText(testing.allocator, src);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(golden, got);
    }
}

test "frame dimensions are positive and bounded" {
    var diag: ?flowchart.MermaidError = null;
    var frame = try renderMermaidFlowchart(testing.allocator, "flowchart TD\n A --> B --> C\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0);
    try testing.expect(frame.rows > 0);
    try testing.expectEqual(frame.codepoints.len, frame.columns * frame.rows);
}
