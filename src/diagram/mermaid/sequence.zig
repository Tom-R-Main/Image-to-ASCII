//! Line-based parser for the Mermaid sequence-diagram subset, producing the
//! sequence IR. Sequence syntax is statement-per-line, so a small line scanner is
//! clearer here than the flowchart's token stream.
//!
//! Supported subset (v0):
//!   header:        `sequenceDiagram`
//!   participants:  `participant A`, `participant A as Alice`, `actor A`
//!   messages:      `A->>B: text`  (and `->`, `-->`, `-->>`, `-)`, `--)`,
//!                  `-x`, `--x`); self-messages (`A->>A: ...`)
//!   comments:      `%% ...`
//!
//! Participants may be implicit (created in first-seen order) or declared
//! explicitly to fix order and aliases. Syntax errors return
//! `error.MermaidSyntax` with a `MermaidError` (kind + 1-based line/column).
//! The result owns an arena; all strings are copied into it.

const std = @import("std");
const ir = @import("../ir/sequence.zig");
const errors = @import("errors.zig");

pub const MermaidError = errors.MermaidError;
pub const MermaidErrorKind = errors.MermaidErrorKind;
pub const ParseError = errors.ParseError;

pub const SequenceResult = struct {
    arena: std.heap.ArenaAllocator,
    diagram: ir.SequenceDiagram,

    pub fn deinit(self: *SequenceResult) void {
        self.arena.deinit();
    }
};

pub fn parseSequence(
    gpa: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?MermaidError,
) ParseError!SequenceResult {
    diagnostic.* = null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var parser: Parser = .{ .arena = arena_state.allocator(), .diagnostic = diagnostic };
    const diagram = try parser.run(source);

    return .{ .arena = arena_state, .diagram = diagram };
}

const Parser = struct {
    arena: std.mem.Allocator,
    diagnostic: *?MermaidError,

    participants: std.ArrayList(ir.Participant) = .empty,
    messages: std.ArrayList(ir.Message) = .empty,
    index: std.StringHashMapUnmanaged(ir.ParticipantId) = .empty,

    fn run(self: *Parser, source: []const u8) ParseError!ir.SequenceDiagram {
        var line_no: u32 = 0;
        var seen_header = false;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |raw| {
            line_no += 1;
            const line = stripComment(raw);
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            if (!seen_header) {
                if (!std.mem.eql(u8, trimmed, "sequenceDiagram")) {
                    return self.fail(.missing_header, line_no, 1, "expected 'sequenceDiagram' header");
                }
                seen_header = true;
                continue;
            }

            try self.parseStatement(trimmed, line_no);
        }

        if (!seen_header) {
            return self.fail(.missing_header, 1, 1, "expected 'sequenceDiagram' header");
        }

        return .{
            .participants = try self.participants.toOwnedSlice(self.arena),
            .messages = try self.messages.toOwnedSlice(self.arena),
        };
    }

    fn parseStatement(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        const first = firstWord(line);
        if (std.mem.eql(u8, first, "participant")) {
            return self.parseParticipant(line[first.len..], line_no, .participant);
        }
        if (std.mem.eql(u8, first, "actor")) {
            return self.parseParticipant(line[first.len..], line_no, .actor);
        }
        return self.parseMessage(line, line_no);
    }

    /// `rest` is everything after the `participant`/`actor` keyword.
    fn parseParticipant(self: *Parser, rest: []const u8, line_no: u32, kind: ir.ParticipantKind) ParseError!void {
        const decl = std.mem.trim(u8, rest, " \t\r");
        const id = firstWord(decl);
        if (id.len == 0) {
            return self.fail(.expected_participant, line_no, 1, "expected a participant identifier after 'participant'");
        }

        var label = id;
        const after = std.mem.trim(u8, decl[id.len..], " \t\r");
        if (after.len > 0) {
            const kw = firstWord(after);
            if (!std.mem.eql(u8, kw, "as")) {
                return self.fail(.unexpected_token, line_no, 1, "expected 'as <label>' after participant id");
            }
            const alias = std.mem.trim(u8, after[kw.len..], " \t\r");
            if (alias.len == 0) {
                return self.fail(.unexpected_token, line_no, 1, "expected a label after 'as'");
            }
            label = alias;
        }

        _ = try self.upsertParticipant(id, label, kind, true);
    }

    fn parseMessage(self: *Parser, line: []const u8, line_no: u32) ParseError!void {
        var i: usize = 0;
        skipSpaces(line, &i);

        const sender = readIdent(line, &i);
        if (sender.len == 0) {
            return self.fail(.expected_participant, line_no, @intCast(i + 1), "expected a participant before the message arrow");
        }
        skipSpaces(line, &i);

        const arrow = parseArrow(line, &i) orelse
            return self.fail(.invalid_arrow, line_no, @intCast(i + 1), "expected a message arrow (->> --> -)  -x ...)");
        skipSpaces(line, &i);

        const receiver = readIdent(line, &i);
        if (receiver.len == 0) {
            return self.fail(.expected_participant, line_no, @intCast(i + 1), "expected a participant after the message arrow");
        }
        skipSpaces(line, &i);

        var text: []const u8 = "";
        if (i < line.len and line[i] == ':') {
            text = std.mem.trim(u8, line[i + 1 ..], " \t\r");
        } else if (i < line.len) {
            return self.fail(.unexpected_token, line_no, @intCast(i + 1), "expected ':' and message text");
        }

        const from = try self.upsertParticipant(sender, sender, .participant, false);
        const to = try self.upsertParticipant(receiver, receiver, .participant, false);
        try self.messages.append(self.arena, .{
            .from = from,
            .to = to,
            .text = try self.arena.dupe(u8, text),
            .line = arrow.line,
            .head = arrow.head,
        });
    }

    fn upsertParticipant(
        self: *Parser,
        id: []const u8,
        label: []const u8,
        kind: ir.ParticipantKind,
        explicit: bool,
    ) ParseError!ir.ParticipantId {
        const gop = try self.index.getOrPut(self.arena, id);
        if (gop.found_existing) {
            if (explicit) {
                const p = &self.participants.items[gop.value_ptr.*];
                p.label = try self.arena.dupe(u8, label);
                p.kind = kind;
            }
            return gop.value_ptr.*;
        }

        const owned_id = try self.arena.dupe(u8, id);
        gop.key_ptr.* = owned_id;
        const pid: ir.ParticipantId = @intCast(self.participants.items.len);
        gop.value_ptr.* = pid;
        try self.participants.append(self.arena, .{
            .id = owned_id,
            .label = try self.arena.dupe(u8, label),
            .kind = kind,
        });
        return pid;
    }

    fn fail(self: *Parser, kind: MermaidErrorKind, line: u32, column: u32, message: []const u8) ParseError {
        self.diagnostic.* = .{ .kind = kind, .line = line, .column = column, .message = message };
        return error.MermaidSyntax;
    }
};

const ArrowOp = struct { line: ir.LineStyle, head: ir.HeadStyle };

/// Parse a message arrow starting at `line[i.*]`, advancing `i`. Returns null
/// (leaving `i` at the bad byte) on a malformed operator.
fn parseArrow(line: []const u8, i: *usize) ?ArrowOp {
    if (i.* >= line.len or line[i.*] != '-') return null;
    i.* += 1;

    var dotted = false;
    if (i.* < line.len and line[i.*] == '-') {
        dotted = true;
        i.* += 1;
    }

    var head: ir.HeadStyle = undefined;
    if (i.* < line.len and line[i.*] == '>') {
        i.* += 1;
        if (i.* < line.len and line[i.*] == '>') {
            i.* += 1;
            head = .arrow;
        } else {
            head = .none;
        }
    } else if (i.* < line.len and line[i.*] == 'x') {
        i.* += 1;
        head = .cross;
    } else if (i.* < line.len and line[i.*] == ')') {
        i.* += 1;
        head = .open;
    } else {
        return null;
    }

    return .{ .line = if (dotted) .dotted else .solid, .head = head };
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "%%")) |pos| return line[0..pos];
    return line;
}

fn firstWord(s: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t\r");
    var end: usize = 0;
    while (end < trimmed.len and !isSpace(trimmed[end])) : (end += 1) {}
    return trimmed[0..end];
}

fn skipSpaces(line: []const u8, i: *usize) void {
    while (i.* < line.len and isSpace(line[i.*])) : (i.* += 1) {}
}

fn readIdent(line: []const u8, i: *usize) []const u8 {
    const start = i.*;
    while (i.* < line.len and isIdentChar(line[i.*])) : (i.* += 1) {}
    return line[start..i.*];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(source: []const u8) !SequenceResult {
    var diag: ?MermaidError = null;
    return parseSequence(testing.allocator, source, &diag) catch |err| {
        if (diag) |d| std.debug.print("parse error {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        return err;
    };
}

test "parses participants and a message" {
    var r = try parseForTest(
        \\sequenceDiagram
        \\    participant A as Alice
        \\    participant B as Bob
        \\    A->>B: Request
    );
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.diagram.participants.len);
    try testing.expectEqualStrings("A", r.diagram.participants[0].id);
    try testing.expectEqualStrings("Alice", r.diagram.participants[0].label);
    try testing.expectEqualStrings("Bob", r.diagram.participants[1].label);

    try testing.expectEqual(@as(usize, 1), r.diagram.messages.len);
    const m = r.diagram.messages[0];
    try testing.expectEqual(@as(ir.ParticipantId, 0), m.from);
    try testing.expectEqual(@as(ir.ParticipantId, 1), m.to);
    try testing.expectEqual(ir.LineStyle.solid, m.line);
    try testing.expectEqual(ir.HeadStyle.arrow, m.head);
    try testing.expectEqualStrings("Request", m.text);
}

test "implicit participants are created in first-seen order" {
    var r = try parseForTest(
        \\sequenceDiagram
        \\    A->>B: hi
        \\    C->>A: yo
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.diagram.participants.len);
    try testing.expectEqualStrings("A", r.diagram.participants[0].id);
    try testing.expectEqualStrings("B", r.diagram.participants[1].id);
    try testing.expectEqualStrings("C", r.diagram.participants[2].id);
}

test "parses all supported arrow forms" {
    var r = try parseForTest(
        \\sequenceDiagram
        \\    A->B: solid none
        \\    A-->B: dotted none
        \\    A->>B: solid arrow
        \\    A-->>B: dotted arrow
        \\    A-)B: solid open
        \\    A--)B: dotted open
        \\    A-xB: solid cross
        \\    A--xB: dotted cross
    );
    defer r.deinit();

    const m = r.diagram.messages;
    try testing.expectEqual(@as(usize, 8), m.len);
    try testing.expectEqual(ir.HeadStyle.none, m[0].head);
    try testing.expectEqual(ir.LineStyle.solid, m[0].line);
    try testing.expectEqual(ir.LineStyle.dotted, m[1].line);
    try testing.expectEqual(ir.HeadStyle.arrow, m[2].head);
    try testing.expectEqual(ir.LineStyle.dotted, m[3].line);
    try testing.expectEqual(ir.HeadStyle.arrow, m[3].head);
    try testing.expectEqual(ir.HeadStyle.open, m[4].head);
    try testing.expectEqual(ir.HeadStyle.open, m[5].head);
    try testing.expectEqual(ir.HeadStyle.cross, m[6].head);
    try testing.expectEqual(ir.HeadStyle.cross, m[7].head);
}

test "parses a self message" {
    var r = try parseForTest(
        \\sequenceDiagram
        \\    A->>A: think
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagram.participants.len);
    try testing.expect(r.diagram.messages[0].isSelf());
}

test "tight spacing without spaces parses" {
    var r = try parseForTest("sequenceDiagram\nA-->>B:ok\n");
    defer r.deinit();
    try testing.expectEqual(ir.LineStyle.dotted, r.diagram.messages[0].line);
    try testing.expectEqualStrings("ok", r.diagram.messages[0].text);
}

test "comments are ignored" {
    var r = try parseForTest(
        \\sequenceDiagram
        \\    %% a note to self
        \\    A->>B: hi %% trailing
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagram.messages.len);
    try testing.expectEqualStrings("hi", r.diagram.messages[0].text);
}

test "rejects a missing header" {
    var diag: ?MermaidError = null;
    const r = parseSequence(testing.allocator, "A->>B: hi\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.missing_header, diag.?.kind);
}

test "reports an invalid arrow with a location" {
    var diag: ?MermaidError = null;
    const r = parseSequence(testing.allocator, "sequenceDiagram\n A ~~ B: hi\n", &diag);
    try testing.expectError(error.MermaidSyntax, r);
    try testing.expectEqual(MermaidErrorKind.invalid_arrow, diag.?.kind);
    try testing.expectEqual(@as(u32, 2), diag.?.line);
}
