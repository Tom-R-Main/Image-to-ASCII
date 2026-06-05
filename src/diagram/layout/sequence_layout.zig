//! Lane/time layout for sequence diagrams.
//!
//! Participants become vertical lanes (a header box plus a lifeline running the
//! full height). The event stream is walked top-to-bottom: messages take a label
//! row and an arrow row (self-messages an extra return row); notes take a boxed
//! slot; activations mark solid sub-segments of a lifeline. Lane spacing is sized
//! so header boxes, adjacent-message labels, and self-loops fit. The result is
//! shifted to the origin and reports its own canvas size.

const std = @import("std");
const ir = @import("../ir/sequence.zig");
const text_measure = @import("../../canvas/text_measure.zig");

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
pub const Interval = struct { top: i32, bottom: i32 };

pub const SequenceLayoutOptions = struct {
    lane_gap: u32 = 4,
    pad_x: u32 = 1,
    self_loop_width: u32 = 4,
    head_gap: u32 = 1,
};

pub const LaidParticipant = struct {
    participant: ir.ParticipantId,
    label: []const u8,
    rect: Rect,
    lane_x: i32,
    lifeline_top: i32,
    lifeline_bottom: i32,
    /// Sub-spans of the lifeline that are "active" (drawn solid, not dotted).
    active: []Interval = &.{},
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

pub const LaidNote = struct {
    rect: Rect,
    text: []const u8,
};

pub const Divider = struct {
    y: i32,
    label: []const u8,
};

pub const LaidBlock = struct {
    kind: ir.BlockKind,
    label: []const u8,
    rect: Rect,
    dividers: []Divider,
};

pub const SequenceLayout = struct {
    arena: std.heap.ArenaAllocator,
    columns: u32,
    rows: u32,
    participants: []LaidParticipant,
    messages: []LaidMessage,
    notes: []LaidNote,
    blocks: []LaidBlock,

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

    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();

    var eng: Engine = .{
        .arena = arena_state.allocator(),
        .scratch = scratch_state.allocator(),
        .diagram = diagram,
        .options = options,
    };
    const result = try eng.run();
    return .{
        .arena = arena_state,
        .columns = result.columns,
        .rows = result.rows,
        .participants = result.participants,
        .messages = result.messages,
        .notes = result.notes,
        .blocks = result.blocks,
    };
}

const Bounds = struct { min: i32, max: i32 };

fn extendBlocks(stack: []Engine.OpenBlock, b: Bounds) void {
    for (stack) |*ob| {
        ob.min_x = @min(ob.min_x, b.min);
        ob.max_x = @max(ob.max_x, b.max);
    }
}

/// Cells needed by a block title (`alt`, or `alt [is valid]`).
fn titleWidth(kind: ir.BlockKind, label: []const u8) LayoutError!i32 {
    const kw: i32 = switch (kind) {
        .alt, .opt, .par => 3,
        .loop => 4,
    };
    if (label.len == 0) return kw;
    return kw + 3 + @as(i32, @intCast(try text_measure.width(label)));
}

fn messageBounds(m: LaidMessage, lw: i32) Bounds {
    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    for (m.points) |pt| {
        min_x = @min(min_x, pt.x);
        max_x = @max(max_x, pt.x);
    }
    min_x = @min(min_x, m.label_at.x);
    if (lw > 0) max_x = @max(max_x, m.label_at.x + lw - 1);
    return .{ .min = min_x, .max = max_x };
}

const Engine = struct {
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    diagram: ir.SequenceDiagram,
    options: SequenceLayoutOptions,

    const RunResult = struct {
        columns: u32,
        rows: u32,
        participants: []LaidParticipant,
        messages: []LaidMessage,
        notes: []LaidNote,
        blocks: []LaidBlock,
    };

    const OpenBlock = struct {
        kind: ir.BlockKind,
        label: []const u8,
        top_y: i32,
        min_x: i32 = std.math.maxInt(i32),
        max_x: i32 = std.math.minInt(i32),
        dividers: std.ArrayList(Divider) = .empty,
    };

    fn run(self: *Engine) LayoutError!RunResult {
        const n = self.diagram.participants.len;
        if (n == 0) {
            return .{ .columns = 0, .rows = 0, .participants = &.{}, .messages = &.{}, .notes = &.{}, .blocks = &.{} };
        }

        const box_w = try self.boxWidths();
        const lane_x = try self.lanePositions(box_w);
        const participants = try self.headerBoxes(box_w, lane_x);

        // Activation tracking: a stack of open start-rows per participant, and a
        // collected interval list per participant.
        const open = try self.scratch.alloc(std.ArrayList(i32), n);
        for (open) |*o| o.* = .empty;
        const intervals = try self.arena.alloc(std.ArrayList(Interval), n);
        for (intervals) |*iv| iv.* = .empty;

        var messages = std.ArrayList(LaidMessage).empty;
        var notes = std.ArrayList(LaidNote).empty;
        var blocks = std.ArrayList(LaidBlock).empty;
        var block_stack = std.ArrayList(OpenBlock).empty;

        var y: i32 = 3 + @as(i32, @intCast(self.options.head_gap));
        for (self.diagram.events, 0..) |ev, ei| {
            switch (ev) {
                .message => |m| {
                    const lw: i32 = @intCast(try text_measure.width(m.text));
                    const arrow_y = y + 1;
                    if (m.deactivate_source) self.endActivation(&open[m.from], &intervals[m.from], arrow_y);
                    const laid = try self.layoutMessage(ei, m, lane_x, lw, y);
                    extendBlocks(block_stack.items, messageBounds(laid, lw));
                    try messages.append(self.arena, laid);
                    if (m.activate_target) try self.startActivation(&open[m.to], arrow_y);
                    y += if (m.isSelf()) 3 else 2;
                },
                .note => |note| {
                    const laid = try self.layoutNote(note, lane_x, y);
                    extendBlocks(block_stack.items, .{
                        .min = laid.rect.x,
                        .max = laid.rect.x + @as(i32, @intCast(laid.rect.width)) - 1,
                    });
                    try notes.append(self.arena, laid);
                    y += @as(i32, @intCast(laid.rect.height)) + 1;
                },
                .activate => |pid| try self.startActivation(&open[pid], y),
                .deactivate => |pid| self.endActivation(&open[pid], &intervals[pid], y),
                .block_start => |b| {
                    try block_stack.append(self.scratch, .{ .kind = b.kind, .label = b.label, .top_y = y });
                    y += 1; // top border / title row
                },
                .block_else => |label| {
                    if (block_stack.items.len > 0) {
                        try block_stack.items[block_stack.items.len - 1].dividers.append(self.scratch, .{ .y = y, .label = label });
                    }
                    y += 1;
                },
                .block_end => {
                    if (block_stack.items.len == 0) continue;
                    var ob = block_stack.pop().?;
                    if (ob.min_x > ob.max_x) {
                        ob.min_x = lane_x[0];
                        ob.max_x = lane_x[lane_x.len - 1];
                    }
                    const left = ob.min_x - 1;
                    // Width must hold the content plus the title and any divider
                    // labels, which are drawn from column left+2.
                    var width_cells: i32 = ob.max_x + 2 - left;
                    width_cells = @max(width_cells, try titleWidth(ob.kind, ob.label) + 3);
                    for (ob.dividers.items) |d| {
                        if (d.label.len > 0) {
                            width_cells = @max(width_cells, @as(i32, @intCast(try text_measure.width(d.label))) + 4);
                        }
                    }
                    const rect: Rect = .{
                        .x = left,
                        .y = ob.top_y,
                        .width = @intCast(width_cells),
                        .height = @intCast(y - ob.top_y + 1),
                    };
                    try blocks.append(self.arena, .{
                        .kind = ob.kind,
                        .label = try self.arena.dupe(u8, ob.label),
                        .rect = rect,
                        .dividers = try self.dupeDividers(ob.dividers.items),
                    });
                    // Make any enclosing block contain this frame.
                    extendBlocks(block_stack.items, .{ .min = left, .max = left + width_cells - 1 });
                    y += 1; // bottom border row
                },
            }
        }

        const lifeline_bottom = y;
        // Close any activations still open at the bottom.
        for (open, 0..) |*o, pi| {
            while (o.items.len > 0) {
                const start = o.pop().?;
                try intervals[pi].append(self.arena, .{ .top = start, .bottom = lifeline_bottom });
            }
        }
        for (participants, 0..) |*p, pi| {
            p.lifeline_bottom = lifeline_bottom;
            p.active = try intervals[pi].toOwnedSlice(self.arena);
        }

        const msgs = try messages.toOwnedSlice(self.arena);
        const nts = try notes.toOwnedSlice(self.arena);
        const blks = try blocks.toOwnedSlice(self.arena);
        const dims = try shiftToOrigin(participants, msgs, nts, blks, lifeline_bottom);

        return .{
            .columns = dims.columns,
            .rows = dims.rows,
            .participants = participants,
            .messages = msgs,
            .notes = nts,
            .blocks = blks,
        };
    }

    fn dupeDividers(self: *Engine, src: []const Divider) LayoutError![]Divider {
        const out = try self.arena.alloc(Divider, src.len);
        for (src, 0..) |d, i| out[i] = .{ .y = d.y, .label = try self.arena.dupe(u8, d.label) };
        return out;
    }

    fn boxWidths(self: *Engine) LayoutError![]u32 {
        const box_w = try self.arena.alloc(u32, self.diagram.participants.len);
        for (self.diagram.participants, 0..) |p, i| {
            box_w[i] = (try text_measure.width(p.label)) + 2 + 2 * self.options.pad_x;
        }
        return box_w;
    }

    fn lanePositions(self: *Engine, box_w: []const u32) LayoutError![]i32 {
        const n = box_w.len;
        const adj_label = try self.scratch.alloc(u32, n);
        @memset(adj_label, 0);
        const self_need = try self.scratch.alloc(u32, n);
        @memset(self_need, 0);

        for (self.diagram.events) |ev| {
            if (ev != .message) continue;
            const m = ev.message;
            const lw = try text_measure.width(m.text);
            if (m.isSelf()) {
                self_need[m.from] = @max(self_need[m.from], self.options.self_loop_width + lw + 2);
                continue;
            }
            const lo = @min(m.from, m.to);
            const hi = @max(m.from, m.to);
            if (hi - lo == 1) adj_label[lo] = @max(adj_label[lo], lw);
        }

        const lane_x = try self.arena.alloc(i32, n);
        lane_x[0] = @intCast(box_w[0] / 2);
        for (1..n) |i| {
            const base = box_w[i - 1] / 2 + box_w[i] / 2 + 2;
            const label_need = if (adj_label[i - 1] > 0) adj_label[i - 1] + 2 else 0;
            const sep: i32 = @intCast(@max(@max(base, self.options.lane_gap), @max(label_need, self_need[i - 1])));
            lane_x[i] = lane_x[i - 1] + sep;
        }
        return lane_x;
    }

    fn headerBoxes(self: *Engine, box_w: []const u32, lane_x: []const i32) LayoutError![]LaidParticipant {
        const participants = try self.arena.alloc(LaidParticipant, self.diagram.participants.len);
        for (self.diagram.participants, 0..) |p, i| {
            const w = box_w[i];
            participants[i] = .{
                .participant = @intCast(i),
                .label = try self.arena.dupe(u8, p.label),
                .rect = .{ .x = lane_x[i] - @as(i32, @intCast(w / 2)), .y = 0, .width = w, .height = 3 },
                .lane_x = lane_x[i],
                .lifeline_top = 3,
                .lifeline_bottom = 0,
            };
        }
        return participants;
    }

    fn layoutMessage(self: *Engine, ei: usize, m: ir.Message, lane_x: []const i32, lw: i32, y: i32) LayoutError!LaidMessage {
        if (m.isSelf()) {
            const x = lane_x[m.from];
            const right = x + @as(i32, @intCast(self.options.self_loop_width));
            var pts = try self.arena.alloc(Point, 4);
            pts[0] = .{ .x = x, .y = y };
            pts[1] = .{ .x = right, .y = y };
            pts[2] = .{ .x = right, .y = y + 1 };
            pts[3] = .{ .x = x, .y = y + 1 };
            return .{
                .message_index = ei,
                .points = pts,
                .head = m.head,
                .line = m.line,
                .label = try self.arena.dupe(u8, m.text),
                .label_at = .{ .x = right + 2, .y = y },
                .self_message = true,
            };
        }
        const from_x = lane_x[m.from];
        const to_x = lane_x[m.to];
        const arrow_y = y + 1;
        var pts = try self.arena.alloc(Point, 2);
        pts[0] = .{ .x = from_x, .y = arrow_y };
        pts[1] = .{ .x = to_x, .y = arrow_y };
        return .{
            .message_index = ei,
            .points = pts,
            .head = m.head,
            .line = m.line,
            .label = try self.arena.dupe(u8, m.text),
            .label_at = .{ .x = @divTrunc(from_x + to_x, 2) - @divTrunc(lw, 2), .y = y },
            .self_message = false,
        };
    }

    fn layoutNote(self: *Engine, note: ir.Note, lane_x: []const i32, y: i32) LayoutError!LaidNote {
        const tw: i32 = @intCast(try text_measure.width(note.text));
        const min_w: i32 = tw + 2 + 2 * @as(i32, @intCast(self.options.pad_x));
        var rect: Rect = undefined;
        switch (note.placement) {
            .over => {
                if (note.from == note.to) {
                    const w = min_w;
                    rect = .{ .x = lane_x[note.from] - @divTrunc(w, 2), .y = y, .width = @intCast(w), .height = 3 };
                } else {
                    const span = lane_x[note.to] - lane_x[note.from];
                    const w = @max(min_w, span + 4);
                    const center = @divTrunc(lane_x[note.from] + lane_x[note.to], 2);
                    rect = .{ .x = center - @divTrunc(w, 2), .y = y, .width = @intCast(w), .height = 3 };
                }
            },
            .right_of => rect = .{ .x = lane_x[note.from] + 2, .y = y, .width = @intCast(min_w), .height = 3 },
            .left_of => rect = .{ .x = lane_x[note.from] - 2 - min_w, .y = y, .width = @intCast(min_w), .height = 3 },
        }
        return .{ .rect = rect, .text = try self.arena.dupe(u8, note.text) };
    }

    fn startActivation(self: *Engine, open: *std.ArrayList(i32), y: i32) LayoutError!void {
        try open.append(self.scratch, y);
    }

    fn endActivation(self: *Engine, open: *std.ArrayList(i32), intervals: *std.ArrayList(Interval), y: i32) void {
        if (open.items.len == 0) return;
        const start = open.pop().?;
        intervals.append(self.arena, .{ .top = start, .bottom = y }) catch {};
    }
};

fn shiftToOrigin(
    participants: []LaidParticipant,
    messages: []LaidMessage,
    notes: []LaidNote,
    blocks: []LaidBlock,
    lifeline_bottom: i32,
) LayoutError!struct { columns: u32, rows: u32 } {
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
        const lw: i32 = @intCast(try text_measure.width(m.label));
        if (lw > 0) max_x = @max(max_x, m.label_at.x + lw - 1);
        max_y = @max(max_y, m.label_at.y);
    }
    for (notes) |note| {
        min_x = @min(min_x, note.rect.x);
        max_x = @max(max_x, note.rect.x + @as(i32, @intCast(note.rect.width)) - 1);
        max_y = @max(max_y, note.rect.y + @as(i32, @intCast(note.rect.height)) - 1);
    }
    for (blocks) |blk| {
        min_x = @min(min_x, blk.rect.x);
        max_x = @max(max_x, blk.rect.x + @as(i32, @intCast(blk.rect.width)) - 1);
        max_y = @max(max_y, blk.rect.y + @as(i32, @intCast(blk.rect.height)) - 1);
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
    for (notes) |*note| note.rect.x += dx;
    for (blocks) |*blk| blk.rect.x += dx;

    return .{ .columns = @intCast(max_x - min_x + 1), .rows = @intCast(max_y + 1) };
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
    var r = try layoutSource("sequenceDiagram\n A->>B: hi\n B->>C: yo\n");
    defer r.parse.deinit();
    defer r.layout.deinit();

    try testing.expectEqual(@as(usize, 3), r.layout.participants.len);
    var prev_right: i32 = -1;
    for (r.layout.participants) |p| {
        try testing.expect(p.rect.x > prev_right);
        prev_right = p.rect.x + @as(i32, @intCast(p.rect.width)) - 1;
    }
}

test "messages advance downward and stay in bounds" {
    var r = try layoutSource("sequenceDiagram\n A->>B: one\n B-->>A: two\n");
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
    var r = try layoutSource("sequenceDiagram\n A->>A: think\n");
    defer r.parse.deinit();
    defer r.layout.deinit();
    try testing.expect(r.layout.messages[0].self_message);
    try testing.expectEqual(@as(usize, 4), r.layout.messages[0].points.len);
}

test "activation produces an active interval on the lifeline" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    A->>+B: open
        \\    B-->>-A: close
    );
    defer r.parse.deinit();
    defer r.layout.deinit();
    // B (index 1) should have one closed activation interval.
    try testing.expectEqual(@as(usize, 1), r.layout.participants[1].active.len);
    const iv = r.layout.participants[1].active[0];
    try testing.expect(iv.bottom > iv.top);
}

test "note over produces a boxed note in bounds" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    A->>B: hi
        \\    Note over A,B: shared state
    );
    defer r.parse.deinit();
    defer r.layout.deinit();
    try testing.expectEqual(@as(usize, 1), r.layout.notes.len);
    const note = r.layout.notes[0];
    try testing.expect(note.rect.x >= 0);
    try testing.expect(note.rect.x + @as(i32, @intCast(note.rect.width)) <= @as(i32, @intCast(r.layout.columns)));
}

test "alt block frames the enclosed messages with a divider" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    A->>B: req
        \\    alt ok
        \\        B->>A: yes
        \\    else no
        \\        B->>A: nope
        \\    end
    );
    defer r.parse.deinit();
    defer r.layout.deinit();

    try testing.expectEqual(@as(usize, 1), r.layout.blocks.len);
    const b = r.layout.blocks[0];
    try testing.expectEqual(ir.BlockKind.alt, b.kind);
    try testing.expectEqual(@as(usize, 1), b.dividers.len);
    // The divider sits inside the frame's vertical span.
    try testing.expect(b.dividers[0].y > b.rect.y);
    try testing.expect(b.dividers[0].y < b.rect.y + @as(i32, @intCast(b.rect.height)));
    // The frame stays within the canvas.
    try testing.expect(b.rect.x >= 0);
    try testing.expect(b.rect.x + @as(i32, @intCast(b.rect.width)) <= @as(i32, @intCast(r.layout.columns)));
}

test "nested blocks produce enclosing frames" {
    var r = try layoutSource(
        \\sequenceDiagram
        \\    loop forever
        \\        opt maybe
        \\            A->>B: hi
        \\        end
        \\    end
    );
    defer r.parse.deinit();
    defer r.layout.deinit();

    try testing.expectEqual(@as(usize, 2), r.layout.blocks.len);
    // Inner block (opt) is popped first; the outer (loop) must enclose it.
    const inner = r.layout.blocks[0];
    const outer = r.layout.blocks[1];
    try testing.expectEqual(ir.BlockKind.opt, inner.kind);
    try testing.expectEqual(ir.BlockKind.loop, outer.kind);
    try testing.expect(outer.rect.x < inner.rect.x);
    try testing.expect(outer.rect.x + @as(i32, @intCast(outer.rect.width)) > inner.rect.x + @as(i32, @intCast(inner.rect.width)));
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
