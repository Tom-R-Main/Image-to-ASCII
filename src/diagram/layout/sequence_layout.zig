//! Lane/time layout for sequence diagrams.
//!
//! Participants become vertical lanes (a header box plus a lifeline running the
//! full height). Messages are stacked top-to-bottom in source order; each takes
//! a label row and an arrow row (self-messages take an extra return row). Lane
//! spacing is sized so header boxes, adjacent-message labels, and self-loops fit.
//! The result is shifted to the origin and reports its own canvas size.

const std = @import("std");
const ir = @import("../ir/sequence.zig");
const text_measure = @import("../../canvas/text_measure.zig");

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

pub const SequenceLayoutOptions = struct {
    /// Minimum horizontal gap between adjacent lifelines.
    lane_gap: u32 = 4,
    /// Horizontal padding inside a header box on each side of its label.
    pad_x: u32 = 1,
    /// How far a self-message loop extends to the right of its lifeline.
    self_loop_width: u32 = 4,
    /// Blank rows between the header boxes and the first message.
    head_gap: u32 = 1,
};

pub const LaidParticipant = struct {
    participant: ir.ParticipantId,
    label: []const u8,
    rect: Rect,
    lane_x: i32,
    lifeline_top: i32,
    lifeline_bottom: i32,
};

pub const LaidMessage = struct {
    message_index: usize,
    points: []Point,
    head: ir.HeadStyle,
    line: ir.LineStyle,
    label: []const u8,
    label_at: Point,
    self_message: bool,
};

pub const SequenceLayout = struct {
    arena: std.heap.ArenaAllocator,
    columns: u32,
    rows: u32,
    participants: []LaidParticipant,
    messages: []LaidMessage,

    pub fn deinit(self: *SequenceLayout) void {
        self.arena.deinit();
    }
};

pub const LayoutError = error{ OutOfMemory, InvalidUtf8 };

pub fn layoutSequence(
    gpa: std.mem.Allocator,
    diagram: ir.SequenceDiagram,
    options: SequenceLayoutOptions,
) LayoutError!SequenceLayout {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const n = diagram.participants.len;
    if (n == 0) {
        return .{ .arena = arena_state, .columns = 0, .rows = 0, .participants = &.{}, .messages = &.{} };
    }

    // --- header box widths ---------------------------------------------------
    const box_w = try arena.alloc(u32, n);
    for (diagram.participants, 0..) |p, i| {
        const lw = try text_measure.width(p.label);
        box_w[i] = lw + 2 + 2 * options.pad_x;
    }

    // --- per-gap requirements from adjacent-message labels and self-loops -----
    const adj_label = try arena.alloc(u32, n); // adj_label[i] = widest label on a message between i and i+1
    @memset(adj_label, 0);
    const self_need = try arena.alloc(u32, n); // self_need[i] = right-room a self-message on i wants
    @memset(self_need, 0);

    for (diagram.messages) |m| {
        const lw = try text_measure.width(m.text);
        if (m.isSelf()) {
            const want = options.self_loop_width + lw + 2;
            self_need[m.from] = @max(self_need[m.from], want);
            continue;
        }
        const lo = @min(m.from, m.to);
        const hi = @max(m.from, m.to);
        if (hi - lo == 1) adj_label[lo] = @max(adj_label[lo], lw);
    }

    // --- lane x positions ----------------------------------------------------
    const lane_x = try arena.alloc(i32, n);
    lane_x[0] = @intCast(box_w[0] / 2);
    for (1..n) |i| {
        const base = box_w[i - 1] / 2 + box_w[i] / 2 + 2;
        const label_need = if (adj_label[i - 1] > 0) adj_label[i - 1] + 2 else 0;
        const sep: i32 = @intCast(@max(@max(base, options.lane_gap), @max(label_need, self_need[i - 1])));
        lane_x[i] = lane_x[i - 1] + sep;
    }

    // --- header boxes + lifelines (bottom filled in after messages) ----------
    const participants = try arena.alloc(LaidParticipant, n);
    for (diagram.participants, 0..) |p, i| {
        const w = box_w[i];
        participants[i] = .{
            .participant = @intCast(i),
            .label = try arena.dupe(u8, p.label),
            .rect = .{ .x = lane_x[i] - @as(i32, @intCast(w / 2)), .y = 0, .width = w, .height = 3 },
            .lane_x = lane_x[i],
            .lifeline_top = 3,
            .lifeline_bottom = 0,
        };
    }

    // --- stack messages ------------------------------------------------------
    var messages = try arena.alloc(LaidMessage, diagram.messages.len);
    var y: i32 = 3 + @as(i32, @intCast(options.head_gap));
    for (diagram.messages, 0..) |m, mi| {
        const lw: i32 = @intCast(try text_measure.width(m.text));
        if (m.isSelf()) {
            const x = lane_x[m.from];
            const right = x + @as(i32, @intCast(options.self_loop_width));
            const top = y;
            const bottom = y + 1;
            var pts = try arena.alloc(Point, 4);
            pts[0] = .{ .x = x, .y = top };
            pts[1] = .{ .x = right, .y = top };
            pts[2] = .{ .x = right, .y = bottom };
            pts[3] = .{ .x = x, .y = bottom };
            messages[mi] = .{
                .message_index = mi,
                .points = pts,
                .head = m.head,
                .line = m.line,
                .label = try arena.dupe(u8, m.text),
                .label_at = .{ .x = right + 2, .y = top },
                .self_message = true,
            };
            y += 3;
        } else {
            const from_x = lane_x[m.from];
            const to_x = lane_x[m.to];
            const arrow_y = y + 1;
            var pts = try arena.alloc(Point, 2);
            pts[0] = .{ .x = from_x, .y = arrow_y };
            pts[1] = .{ .x = to_x, .y = arrow_y };
            messages[mi] = .{
                .message_index = mi,
                .points = pts,
                .head = m.head,
                .line = m.line,
                .label = try arena.dupe(u8, m.text),
                .label_at = .{ .x = @divTrunc(from_x + to_x, 2) - @divTrunc(lw, 2), .y = y },
                .self_message = false,
            };
            y += 2;
        }
    }

    const lifeline_bottom = y;
    for (participants) |*p| p.lifeline_bottom = lifeline_bottom;

    // --- bounds + shift to origin -------------------------------------------
    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = lifeline_bottom;

    for (participants) |p| {
        min_x = @min(min_x, p.rect.x);
        max_x = @max(max_x, p.rect.x + @as(i32, @intCast(p.rect.width)) - 1);
    }
    for (messages) |m| {
        for (m.points) |pt| {
            min_x = @min(min_x, pt.x);
            max_x = @max(max_x, pt.x);
            max_y = @max(max_y, pt.y);
        }
        min_x = @min(min_x, m.label_at.x);
        const label_w: i32 = @intCast(try text_measure.width(m.label));
        if (label_w > 0) max_x = @max(max_x, m.label_at.x + label_w - 1);
        max_y = @max(max_y, m.label_at.y);
    }

    const dx = -min_x;
    for (participants) |*p| {
        p.rect.x += dx;
        p.lane_x += dx;
    }
    for (messages) |*m| {
        for (m.points) |*pt| pt.x += dx;
        m.label_at.x += dx;
    }

    return .{
        .arena = arena_state,
        .columns = @intCast(max_x - min_x + 1),
        .rows = @intCast(max_y + 1),
        .participants = participants,
        .messages = messages,
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const sequence = @import("../mermaid/sequence.zig");

fn layoutSource(src: []const u8) !struct { parse: sequence.SequenceResult, layout: SequenceLayout } {
    var diag: ?sequence.MermaidError = null;
    var parse = try sequence.parseSequence(testing.allocator, src, &diag);
    errdefer parse.deinit();
    const lay = try layoutSequence(testing.allocator, parse.diagram, .{});
    return .{ .parse = parse, .layout = lay };
}

test "participants get ordered lanes with non-overlapping boxes" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    A->>B: hi
        \\    B->>C: yo
    );
    defer r.parse.deinit();
    defer r.layout.deinit();

    try testing.expectEqual(@as(usize, 3), r.layout.participants.len);
    var prev_right: i32 = -1;
    for (r.layout.participants) |p| {
        try testing.expect(p.rect.x > prev_right);
        prev_right = p.rect.x + @as(i32, @intCast(p.rect.width)) - 1;
        try testing.expect(p.lane_x > 0);
    }
}

test "messages advance downward and stay in bounds" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    A->>B: one
        \\    B-->>A: two
    );
    defer r.parse.deinit();
    defer r.layout.deinit();

    try testing.expectEqual(@as(usize, 2), r.layout.messages.len);
    try testing.expect(r.layout.messages[1].label_at.y > r.layout.messages[0].label_at.y);
    for (r.layout.messages) |m| {
        for (m.points) |pt| {
            try testing.expect(pt.x >= 0 and pt.x < @as(i32, @intCast(r.layout.columns)));
            try testing.expect(pt.y >= 0 and pt.y < @as(i32, @intCast(r.layout.rows)));
        }
    }
}

test "self message produces a four-point loop" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    A->>A: think
    );
    defer r.parse.deinit();
    defer r.layout.deinit();
    try testing.expect(r.layout.messages[0].self_message);
    try testing.expectEqual(@as(usize, 4), r.layout.messages[0].points.len);
}

test "lifelines span from header to last message" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    A->>B: hi
    );
    defer r.parse.deinit();
    defer r.layout.deinit();
    for (r.layout.participants) |p| {
        try testing.expectEqual(@as(i32, 3), p.lifeline_top);
        try testing.expect(p.lifeline_bottom >= 3);
    }
}

test "empty diagram yields empty layout" {
    var diag: ?sequence.MermaidError = null;
    var parse = try sequence.parseSequence(testing.allocator, "sequenceDiagram\n", &diag);
    defer parse.deinit();
    var lay = try layoutSequence(testing.allocator, parse.diagram, .{});
    defer lay.deinit();
    try testing.expectEqual(@as(usize, 0), lay.participants.len);
    try testing.expectEqual(@as(u32, 0), lay.columns);
}
