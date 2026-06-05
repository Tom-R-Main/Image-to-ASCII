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
const state = @import("../mermaid/state.zig");
const class = @import("../mermaid/class.zig");

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

    const node_text: cc.TextOptions = .{ .fg = options.node_fg, .bg = options.node_bg };
    const edge_text: cc.TextOptions = .{ .fg = options.edge_fg, .bg = options.edge_bg };

    // 1. Edge lines first; node boxes drawn over them sit only in clear cells.
    for (lay.edges) |edge| {
        const line_opts: cc.LineOptions = .{
            .glyph_set = options.glyph_set,
            .stroke = strokeFor(edge.line),
            .fg = options.edge_fg,
            .bg = options.edge_bg,
        };
        try drawPolyline(&canvas, edge.points, line_opts);
    }

    // 2. Node shapes/cards and their labels.
    const box_opts: cc.BoxOptions = .{ .glyph_set = options.glyph_set, .fg = options.node_fg, .bg = options.node_bg };
    for (lay.nodes) |node| {
        if (diagram.nodes[node.node].compartments) |comps| {
            try drawCard(&canvas, node.rect, node.label, comps, box_opts, node_text, options.layout.pad_x);
        } else {
            try drawNodeShape(&canvas, node.rect, node.shape, options.glyph_set, node_text);
            try drawCenteredLabel(&canvas, node.rect, node.label, node_text);
        }
    }

    // 3. Endpoint decorations (drawn last so they stay visible at box edges).
    for (lay.edges) |edge| {
        const arrow_opts: cc.ArrowOptions = .{
            .glyph_set = options.glyph_set,
            .stroke = strokeFor(edge.line),
            .fg = options.edge_fg,
            .bg = options.edge_bg,
        };
        const at_source = diagram.edges[edge.edge_index].head_at_source;
        try drawDecoration(&canvas, edge, at_source, options.glyph_set, arrow_opts, edge_text);
    }

    // 4. Edge labels, placed beside the routing line rather than over it.
    for (lay.edges) |edge| {
        if (edge.label) |label| try drawEdgeLabel(&canvas, edge, label, edge_text);
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

/// Parse a Mermaid state diagram and render it. State diagrams lower to the same
/// graph IR, so this reuses the flowchart layout and renderer.
pub fn renderMermaidState(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: GraphRenderOptions,
    diagnostic: *?state.MermaidError,
) (GraphRenderError || state.ParseError)!core.Frame {
    var parsed = try state.parseState(gpa, source, diagnostic);
    defer parsed.deinit();
    return renderGraph(gpa, parsed.diagram, options);
}

/// Parse a Mermaid class diagram and render it. Classes become compartment cards;
/// it reuses the same graph layout and renderer.
pub fn renderMermaidClass(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: GraphRenderOptions,
    diagnostic: *?class.MermaidError,
) (GraphRenderError || class.ParseError)!core.Frame {
    var parsed = try class.parseClass(gpa, source, diagnostic);
    defer parsed.deinit();
    return renderGraph(gpa, parsed.diagram, options);
}

fn strokeFor(line: ir.LineKind) cc.Stroke {
    return switch (line) {
        .solid => .light,
        .dotted => .dotted,
        .thick => .heavy,
    };
}

const ShapeGlyphs = struct {
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    h: []const u8,
    vl: []const u8,
    vr: []const u8,
};

/// Glyphs per node shape. Terminal cells can't draw true circles or rhombi, so
/// these are recognizable approximations: rounded corners for `round`, rounded
/// corners with parenthesis sides (a capsule) for `circle`, and diagonal corners
/// for `diamond`. ASCII falls back to dot/quote corners and slashes.
fn shapeGlyphs(shape: ir.NodeShape, glyph_set: cc.GlyphSet) ShapeGlyphs {
    return switch (glyph_set) {
        .unicode_box => switch (shape) {
            .rect => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .vl = "│", .vr = "│" },
            .round => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .vl = "│", .vr = "│" },
            .circle => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .vl = "(", .vr = ")" },
            .diamond => .{ .tl = "╱", .tr = "╲", .bl = "╲", .br = "╱", .h = "─", .vl = "│", .vr = "│" },
        },
        .ascii => switch (shape) {
            .rect => .{ .tl = "+", .tr = "+", .bl = "+", .br = "+", .h = "-", .vl = "|", .vr = "|" },
            .round => .{ .tl = ".", .tr = ".", .bl = "'", .br = "'", .h = "-", .vl = "|", .vr = "|" },
            .circle => .{ .tl = ".", .tr = ".", .bl = "'", .br = "'", .h = "-", .vl = "(", .vr = ")" },
            .diamond => .{ .tl = "/", .tr = "\\", .bl = "\\", .br = "/", .h = "-", .vl = "|", .vr = "|" },
        },
    };
}

/// Draw a node border with shape-specific glyphs. Interior is left untouched
/// (the layout keeps edges out of node rects), and the label is drawn after.
fn drawNodeShape(canvas: *cc.CellCanvas, rect: layered.Rect, shape: ir.NodeShape, glyph_set: cc.GlyphSet, opts: cc.TextOptions) !void {
    if (rect.width < 2 or rect.height < 2) return;
    const g = shapeGlyphs(shape, glyph_set);
    const x = rect.x;
    const y = rect.y;
    const w: i32 = @intCast(rect.width);
    const h: i32 = @intCast(rect.height);

    try canvas.drawText(x, y, g.tl, opts);
    try canvas.drawText(x + w - 1, y, g.tr, opts);
    try canvas.drawText(x, y + h - 1, g.bl, opts);
    try canvas.drawText(x + w - 1, y + h - 1, g.br, opts);

    var i: i32 = 1;
    while (i < w - 1) : (i += 1) {
        try canvas.drawText(x + i, y, g.h, opts);
        try canvas.drawText(x + i, y + h - 1, g.h, opts);
    }

    var row: i32 = y + 1;
    while (row < y + h - 1) : (row += 1) {
        try canvas.drawText(x, row, g.vl, opts);
        try canvas.drawText(x + w - 1, row, g.vr, opts);
    }
}

fn drawPolyline(canvas: *cc.CellCanvas, points: []const layered.Point, opts: cc.LineOptions) !void {
    if (points.len < 2) return;
    var i: usize = 1;
    while (i < points.len) : (i += 1) {
        const a = points[i - 1];
        const b = points[i];
        try canvas.drawLine(.{ .x = a.x, .y = a.y }, .{ .x = b.x, .y = b.y }, opts);
    }
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

/// Place an edge label beside its routing line, never over it when avoidable.
/// The anchor is the path midpoint by arc length. We try candidate slots (above/
/// below a horizontal mid-segment; right/left of a vertical one) and take the
/// first that is fully blank and in-bounds, falling back to the midpoint only if
/// the graph is too dense for any clear slot.
fn drawEdgeLabel(canvas: *cc.CellCanvas, edge: layered.RoutedEdge, label: []const u8, opts: cc.TextOptions) !void {
    const points = edge.points;
    if (points.len < 2) return;
    const w: i32 = @intCast(text_measure.width(label) catch return);
    const mid = pathMidpoint(points);

    var candidates: [4]layered.Point = undefined;
    var count: usize = 0;
    if (mid.horizontal) {
        const left = mid.point.x - @divTrunc(w, 2);
        candidates[0] = .{ .x = left, .y = mid.point.y - 1 };
        candidates[1] = .{ .x = left, .y = mid.point.y + 1 };
        count = 2;
    } else {
        candidates[0] = .{ .x = mid.point.x + 1, .y = mid.point.y };
        candidates[1] = .{ .x = mid.point.x - w, .y = mid.point.y };
        candidates[2] = .{ .x = mid.point.x - @divTrunc(w, 2), .y = mid.point.y - 1 };
        candidates[3] = .{ .x = mid.point.x - @divTrunc(w, 2), .y = mid.point.y + 1 };
        count = 4;
    }

    for (candidates[0..count]) |c| {
        if (rowIsBlank(canvas, c.x, c.y, w)) {
            try canvas.drawText(c.x, c.y, label, opts);
            return;
        }
    }
    try canvas.drawText(mid.point.x - @divTrunc(w, 2), mid.point.y, label, opts);
}

fn rowIsBlank(canvas: *const cc.CellCanvas, x: i32, y: i32, w: i32) bool {
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        if (!canvas.isBlank(x + i, y)) return false;
    }
    return true;
}

const Midpoint = struct { point: layered.Point, horizontal: bool };

/// Midpoint of an orthogonal polyline by total arc length.
fn pathMidpoint(points: []const layered.Point) Midpoint {
    var total: i32 = 0;
    var i: usize = 1;
    while (i < points.len) : (i += 1) {
        total += @intCast(@abs(points[i].x - points[i - 1].x) + @abs(points[i].y - points[i - 1].y));
    }
    var target = @divTrunc(total, 2);
    i = 1;
    while (i < points.len) : (i += 1) {
        const a = points[i - 1];
        const b = points[i];
        const seg: i32 = @intCast(@abs(b.x - a.x) + @abs(b.y - a.y));
        if (seg == 0) continue;
        if (target <= seg) {
            if (a.y == b.y) {
                const step: i32 = if (b.x >= a.x) 1 else -1;
                return .{ .point = .{ .x = a.x + step * target, .y = a.y }, .horizontal = true };
            }
            const step: i32 = if (b.y >= a.y) 1 else -1;
            return .{ .point = .{ .x = a.x, .y = a.y + step * target }, .horizontal = false };
        }
        target -= seg;
    }
    return .{ .point = points[points.len / 2], .horizontal = true };
}

fn drawDecoration(
    canvas: *cc.CellCanvas,
    edge: layered.RoutedEdge,
    at_source: bool,
    glyph_set: cc.GlyphSet,
    arrow_opts: cc.ArrowOptions,
    text_opts: cc.TextOptions,
) !void {
    const points = edge.points;
    if (points.len < 2) return;

    // The decorated endpoint and its inward neighbor (so direction points into
    // the decorated node).
    const p = if (at_source) points[0] else points[points.len - 1];
    var prev = p;
    if (at_source) {
        for (points[1..]) |q| {
            if (q.x != p.x or q.y != p.y) {
                prev = q;
                break;
            }
        }
    } else {
        var i = points.len - 1;
        while (i > 0) {
            i -= 1;
            if (points[i].x != p.x or points[i].y != p.y) {
                prev = points[i];
                break;
            }
        }
    }
    const dx = p.x - prev.x;
    const dy = p.y - prev.y;

    switch (edge.arrow) {
        .none => {},
        .arrow => try canvas.drawArrow(.{ .x = prev.x, .y = prev.y }, .{ .x = p.x, .y = p.y }, arrow_opts),
        .circle => try canvas.drawText(p.x, p.y, circleGlyph(glyph_set), text_opts),
        .cross => try canvas.drawText(p.x, p.y, crossGlyph(glyph_set), text_opts),
        .triangle => try canvas.drawText(p.x, p.y, triangleGlyph(glyph_set, dx, dy), text_opts),
        .diamond => try canvas.drawText(p.x, p.y, if (glyph_set == .ascii) "o" else "\u{25C7}", text_opts), // ◇
        .diamond_filled => try canvas.drawText(p.x, p.y, if (glyph_set == .ascii) "*" else "\u{25C6}", text_opts), // ◆
    }
}

fn triangleGlyph(glyph_set: cc.GlyphSet, dx: i32, dy: i32) []const u8 {
    if (@abs(dy) >= @abs(dx)) {
        if (dy < 0) return if (glyph_set == .ascii) "^" else "\u{25B3}"; // △
        return if (glyph_set == .ascii) "v" else "\u{25BD}"; // ▽
    }
    if (dx < 0) return if (glyph_set == .ascii) "<" else "\u{25C1}"; // ◁
    return if (glyph_set == .ascii) ">" else "\u{25B7}"; // ▷
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

/// Draw a compartment "card": a rectangular box with a centered header and one
/// or more dividers separating left-justified content rows. Row offsets mirror
/// `ir.cardHeight` so the card exactly fills the layout-computed rect.
fn drawCard(
    canvas: *cc.CellCanvas,
    rect: layered.Rect,
    header: []const u8,
    comps: []const ir.Compartment,
    box_opts: cc.BoxOptions,
    text_opts: cc.TextOptions,
    pad_x: u32,
) !void {
    try canvas.drawBox(toCanvasRect(rect), box_opts);
    try drawRowText(canvas, rect, rect.y + 1, header, .center, pad_x, text_opts);

    const line_opts: cc.LineOptions = .{ .glyph_set = box_opts.glyph_set, .stroke = box_opts.stroke, .fg = box_opts.fg, .bg = box_opts.bg };
    const right = rect.x + @as(i32, @intCast(rect.width)) - 1;
    var row = rect.y + 2;
    for (comps) |c| {
        try canvas.drawLine(.{ .x = rect.x, .y = row }, .{ .x = right, .y = row }, line_opts);
        row += 1;
        for (c, 0..) |line, k| {
            try drawRowText(canvas, rect, row + @as(i32, @intCast(k)), line, .left, pad_x, text_opts);
        }
        row += @intCast(@max(@as(usize, 1), c.len));
    }
}

fn toCanvasRect(rect: layered.Rect) cc.Rect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

const RowAlign = enum { left, center };

fn drawRowText(canvas: *cc.CellCanvas, rect: layered.Rect, row: i32, text: []const u8, alignment: RowAlign, pad_x: u32, opts: cc.TextOptions) !void {
    if (rect.width < 3) return;
    const interior: i32 = @intCast(rect.width - 2);
    const w: i32 = @intCast(text_measure.width(text) catch return);
    const x = switch (alignment) {
        .left => rect.x + 1 + @as(i32, @intCast(pad_x)),
        .center => rect.x + 1 + @max(@as(i32, 0), @divTrunc(interior - w, 2)),
    };
    try canvas.drawText(x, row, text, opts);
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

fn frameToText(allocator: std.mem.Allocator, frame: core.Frame) ![]u8 {
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

test "renders a state diagram as a graph (golden)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/mermaid/state/simple.mmd", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(src);
    const golden = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/mermaid/state/simple.golden.txt", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(golden);

    var diag: ?state.MermaidError = null;
    var frame = try renderMermaidState(testing.allocator, src, .{ .glyph_set = .ascii, .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    const got = try frameToText(testing.allocator, frame);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(golden, got);
}

test "renders a class diagram as a compartment card (golden)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/mermaid/class/basic.mmd", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(src);
    const golden = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/mermaid/class/basic.golden.txt", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(golden);

    var diag: ?class.MermaidError = null;
    var frame = try renderMermaidClass(testing.allocator, src, .{ .glyph_set = .ascii, .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    const got = try frameToText(testing.allocator, frame);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(golden, got);
}

test "class card has two compartments and a unicode inheritance triangle" {
    var diag: ?class.MermaidError = null;
    var frame = try renderMermaidClass(testing.allocator,
        \\classDiagram
        \\    class User {
        \\      +id
        \\      +run()
        \\    }
        \\    User <|-- Admin
    , .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    var dividers: usize = 0;
    var triangle = false;
    for (frame.codepoints) |c| {
        if (c == 0x251C) dividers += 1; // ├ left divider junction
        if (c == 0x25B3) triangle = true; // △ inheritance head
    }
    try testing.expect(dividers >= 2); // header/attrs and attrs/methods dividers
    try testing.expect(triangle);
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

fn frameHasCodepoint(frame: core.Frame, cp: u21) bool {
    for (frame.codepoints) |c| {
        if (c == cp) return true;
    }
    return false;
}

test "unicode edges use distinct dotted and heavy stroke glyphs" {
    var diag: ?flowchart.MermaidError = null;
    var frame = try renderMermaidFlowchart(testing.allocator, "flowchart TD\n A -.-> B\n B ==> C\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frameHasCodepoint(frame, 0x2506)); // ┆ dotted vertical
    try testing.expect(frameHasCodepoint(frame, 0x2503)); // ┃ heavy vertical
}

test "node shapes use distinct corner glyphs" {
    var diag: ?flowchart.MermaidError = null;
    var frame = try renderMermaidFlowchart(testing.allocator, "flowchart TD\n A(Round) --> B{Dia}\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frameHasCodepoint(frame, 0x256d)); // ╭ round corner
    try testing.expect(frameHasCodepoint(frame, 0x2571)); // ╱ diamond corner
    try testing.expect(!frameHasCodepoint(frame, 0x250c)); // no square ┌ corners here
}

test "flowchart golden fixtures" {
    // testdata lives outside the src/ package so @embedFile can't reach it;
    // read fixtures at runtime relative to the build's working directory.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "testdata/mermaid/flowchart/";

    const bases = [_][]const u8{ "basic_lr", "labeled_edges", "diamond", "shapes" };
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
