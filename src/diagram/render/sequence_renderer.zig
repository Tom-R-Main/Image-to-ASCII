//! Renders a laid-out sequence diagram onto a `CellCanvas` and exports a `Frame`.
//! Consumes the sequence IR + lane/time layout; knows nothing about Mermaid.

const std = @import("std");
const core = @import("../../core.zig");
const cc = @import("../../canvas/cell_canvas.zig");
const text_measure = @import("../../canvas/text_measure.zig");
const ir = @import("../ir/sequence.zig");
const seqlayout = @import("../layout/sequence_layout.zig");
const sequence = @import("../mermaid/sequence.zig");

pub const SequenceRenderOptions = struct {
    layout: seqlayout.SequenceLayoutOptions = .{},
    glyph_set: cc.GlyphSet = .unicode_box,
    color: core.ColorMode = .truecolor,
    participant_fg: core.Rgb8 = .{ .r = 235, .g = 235, .b = 235 },
    participant_bg: core.Rgb8 = .{ .r = 0, .g = 0, .b = 0 },
    lifeline_fg: core.Rgb8 = .{ .r = 110, .g = 110, .b = 120 },
    message_fg: core.Rgb8 = .{ .r = 150, .g = 180, .b = 220 },
    bg: core.Rgb8 = .{ .r = 0, .g = 0, .b = 0 },
};

pub const SequenceRenderError = error{ OutOfMemory, InvalidUtf8, Overflow, NonOrthogonalLine };

/// Render an already-parsed sequence diagram to a `Frame`.
pub fn renderSequence(
    gpa: std.mem.Allocator,
    diagram: ir.SequenceDiagram,
    options: SequenceRenderOptions,
) SequenceRenderError!core.Frame {
    var lay = try seqlayout.layoutSequence(gpa, diagram, options.layout);
    defer lay.deinit();

    var canvas = try cc.CellCanvas.init(gpa, lay.columns, lay.rows, options.color);
    defer canvas.deinit(gpa);

    const lifeline_opts: cc.LineOptions = .{
        .glyph_set = options.glyph_set,
        .stroke = .dotted,
        .fg = options.lifeline_fg,
        .bg = options.bg,
    };
    const box_opts: cc.BoxOptions = .{ .glyph_set = options.glyph_set, .fg = options.participant_fg, .bg = options.bg };
    const participant_text: cc.TextOptions = .{ .fg = options.participant_fg, .bg = options.bg };
    const message_text: cc.TextOptions = .{ .fg = options.message_fg, .bg = options.bg };

    // 1. Lifelines first (messages and boxes draw over them).
    for (lay.participants) |p| {
        try canvas.drawLine(
            .{ .x = p.lane_x, .y = p.lifeline_top },
            .{ .x = p.lane_x, .y = p.lifeline_bottom },
            lifeline_opts,
        );
    }

    // 2. Header boxes and participant labels.
    for (lay.participants) |p| {
        try canvas.drawBox(toCanvasRect(p.rect), box_opts);
        try drawCenteredLabel(&canvas, p.rect, p.label, participant_text);
    }

    // 3. Message shafts.
    for (lay.messages) |m| {
        const line_opts: cc.LineOptions = .{
            .glyph_set = options.glyph_set,
            .stroke = strokeFor(m.line),
            .fg = options.message_fg,
            .bg = options.bg,
        };
        if (m.self_message) {
            try drawPolyline(&canvas, m.points, line_opts);
        } else {
            try canvas.drawLine(
                .{ .x = m.points[0].x, .y = m.points[0].y },
                .{ .x = m.points[1].x, .y = m.points[1].y },
                line_opts,
            );
        }
    }

    // 4. Arrowheads (drawn after shafts so they stay visible at the lifeline).
    for (lay.messages) |m| {
        try drawHead(&canvas, m, options.glyph_set, message_text);
    }

    // 5. Message labels last, so they stay readable over lifelines.
    for (lay.messages) |m| {
        if (m.label.len > 0) {
            try canvas.drawText(m.label_at.x, m.label_at.y, m.label, message_text);
        }
    }

    return canvas.toFrame(gpa);
}

/// Parse Mermaid sequence source and render it to a `Frame`.
pub fn renderMermaidSequence(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: SequenceRenderOptions,
    diagnostic: *?sequence.MermaidError,
) (SequenceRenderError || sequence.ParseError)!core.Frame {
    var parsed = try sequence.parseSequence(gpa, source, diagnostic);
    defer parsed.deinit();
    return renderSequence(gpa, parsed.diagram, options);
}

fn strokeFor(line: ir.LineStyle) cc.Stroke {
    return switch (line) {
        .solid => .light,
        .dotted => .dotted,
    };
}

fn toCanvasRect(r: seqlayout.Rect) cc.Rect {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

fn drawPolyline(canvas: *cc.CellCanvas, points: []const seqlayout.Point, opts: cc.LineOptions) !void {
    if (points.len < 2) return;
    var i: usize = 1;
    while (i < points.len) : (i += 1) {
        try canvas.drawLine(
            .{ .x = points[i - 1].x, .y = points[i - 1].y },
            .{ .x = points[i].x, .y = points[i].y },
            opts,
        );
    }
}

fn drawCenteredLabel(canvas: *cc.CellCanvas, rect: seqlayout.Rect, label: []const u8, opts: cc.TextOptions) !void {
    if (rect.width < 3) return;
    const interior: i32 = @intCast(rect.width - 2);
    const w: i32 = @intCast(text_measure.width(label) catch return);
    const pad = @max(@as(i32, 0), @divTrunc(interior - w, 2));
    const lx = rect.x + 1 + pad;
    const ly = rect.y + @divTrunc(@as(i32, @intCast(rect.height)), 2);
    try canvas.drawText(lx, ly, label, opts);
}

fn drawHead(canvas: *cc.CellCanvas, m: seqlayout.LaidMessage, glyph_set: cc.GlyphSet, opts: cc.TextOptions) !void {
    if (m.head == .none) return;
    const tip = m.points[m.points.len - 1];
    const prev = m.points[m.points.len - 2];
    const left = tip.x < prev.x;
    if (headGlyph(m.head, left, glyph_set)) |g| {
        try canvas.drawText(tip.x, tip.y, g, opts);
    }
}

fn headGlyph(head: ir.HeadStyle, left: bool, glyph_set: cc.GlyphSet) ?[]const u8 {
    return switch (head) {
        .none => null,
        .arrow => switch (glyph_set) {
            .unicode_box => if (left) "\u{25C4}" else "\u{25BA}", // ◄ ►
            .ascii => if (left) "<" else ">",
        },
        .open => switch (glyph_set) {
            .unicode_box => if (left) "\u{25C1}" else "\u{25B7}", // ◁ ▷
            .ascii => if (left) "<" else ">",
        },
        .cross => switch (glyph_set) {
            .unicode_box => "\u{00D7}", // ×
            .ascii => "x",
        },
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderToText(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var diag: ?sequence.MermaidError = null;
    var frame = renderMermaidSequence(allocator, source, .{ .glyph_set = .ascii, .color = .none }, &diag) catch |err| {
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

test "renders participants, a lifeline, and a message" {
    const text = try renderToText(testing.allocator,
        \\sequenceDiagram
        \\    A->>B: Request
    );
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "+-") != null); // header box
    try testing.expect(std.mem.indexOf(u8, text, "A") != null);
    try testing.expect(std.mem.indexOf(u8, text, "B") != null);
    try testing.expect(std.mem.indexOf(u8, text, ">") != null); // arrowhead
    try testing.expect(std.mem.indexOf(u8, text, "Request") != null);
    try testing.expect(std.mem.indexOf(u8, text, ":") != null); // dotted lifeline (ascii ':')
}

test "renders a reply pointing left" {
    const text = try renderToText(testing.allocator,
        \\sequenceDiagram
        \\    A->>B: go
        \\    B-->>A: back
    );
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "<") != null); // left arrowhead on the reply
    try testing.expect(std.mem.indexOf(u8, text, "back") != null);
}

test "unicode lifelines and heads use distinct glyphs" {
    var diag: ?sequence.MermaidError = null;
    var frame = try renderMermaidSequence(testing.allocator,
        \\sequenceDiagram
        \\    A-)B: async
    , .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    var has_lifeline = false;
    var has_open = false;
    for (frame.codepoints) |c| {
        if (c == 0x2506) has_lifeline = true; // ┆ dotted vertical
        if (c == 0x25B7) has_open = true; // ▷ open async head
    }
    try testing.expect(has_lifeline);
    try testing.expect(has_open);
}

test "sequence golden fixtures" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "testdata/mermaid/sequence/";

    const bases = [_][]const u8{ "basic", "self_message" };
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

test "frame dimensions are positive" {
    var diag: ?sequence.MermaidError = null;
    var frame = try renderMermaidSequence(testing.allocator, "sequenceDiagram\n A->>A: loop\n", .{ .color = .none }, &diag);
    defer frame.deinit(testing.allocator);
    try testing.expect(frame.columns > 0 and frame.rows > 0);
    try testing.expectEqual(frame.codepoints.len, frame.columns * frame.rows);
}
