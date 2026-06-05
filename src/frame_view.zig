//! Bounded-pane helpers over a rendered `Frame`. Diagrams (and images) render to
//! their natural size; these primitives fit that output into a fixed terminal/TUI
//! pane by padding, clipping, or reporting overflow. They are renderer-agnostic —
//! reusable for any `Frame`, not just Mermaid.
//!
//! First version is deterministic and does not scale or relayout: a frame is
//! emitted natural, padded to a pane, clipped from the origin, or rejected.

const std = @import("std");
const core = @import("core.zig");
const ansi = @import("ansi.zig");

pub const FrameViewport = core.FrameViewport;

pub const OverflowMode = enum {
    /// Render at natural size even if it exceeds the requested bounds.
    allow,
    /// Clip to the bounds (from the origin).
    clip,
    /// Treat exceeding the bounds as an error.
    error_if_too_large,
};

/// Whether a frame fits within `columns` x `rows`.
pub fn frameFits(frame: core.Frame, columns: u32, rows: u32) bool {
    return frame.columns <= columns and frame.rows <= rows;
}

/// Emit a bounded region of `frame` as ANSI. Cells outside the frame (when the
/// viewport overhangs) are blank padding, so this both clips (viewport smaller
/// than the frame) and pads (viewport larger).
pub fn renderFrameRegionToWriter(writer: *std.Io.Writer, frame: core.Frame, viewport: FrameViewport) !void {
    try ansi.writeFrameRegion(writer, frame, viewport);
}

/// Copy a `viewport`-sized region of `frame` into a new owned `Frame`. Overhang
/// is blank-padded. Useful when a caller needs the cropped cells as data (e.g. to
/// blit into a TUI buffer) rather than as a stream.
pub fn cropFrameToCells(allocator: std.mem.Allocator, frame: core.Frame, viewport: FrameViewport) !core.Frame {
    const pad: core.Rgb8 = .{ .r = 0, .g = 0, .b = 0 };

    var out: core.Frame = .empty;
    errdefer out.deinit(allocator);
    try out.ensureCapacity(allocator, viewport.columns, viewport.rows, frame.color);

    var row: u32 = 0;
    while (row < viewport.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < viewport.columns) : (col += 1) {
            const dst = @as(usize, row) * viewport.columns + col;
            const sx = viewport.x + col;
            const sy = viewport.y + row;
            if (sx < frame.columns and sy < frame.rows) {
                const src = @as(usize, sy) * frame.columns + sx;
                out.codepoints[dst] = frame.codepoints[src];
                if (frame.color != .none) {
                    out.fg[dst] = frame.fg[src];
                    out.bg[dst] = frame.bg[src];
                }
            } else {
                out.codepoints[dst] = ' ';
                if (frame.color != .none) {
                    out.fg[dst] = pad;
                    out.bg[dst] = pad;
                }
            }
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeFrame(allocator: std.mem.Allocator, rows: []const []const u8) !core.Frame {
    var frame: core.Frame = .empty;
    errdefer frame.deinit(allocator);
    try frame.ensureCapacity(allocator, @intCast(rows[0].len), @intCast(rows.len), .none);
    for (rows, 0..) |line, y| {
        for (line, 0..) |ch, x| {
            frame.codepoints[y * frame.columns + x] = ch;
        }
    }
    return frame;
}

fn regionText(allocator: std.mem.Allocator, frame: core.Frame, vp: FrameViewport) ![]u8 {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try renderFrameRegionToWriter(&writer, frame, vp);
    return allocator.dupe(u8, writer.buffered());
}

test "frameFits compares both dimensions" {
    var frame = try makeFrame(testing.allocator, &.{ "abc", "def" });
    defer frame.deinit(testing.allocator);
    try testing.expect(frameFits(frame, 3, 2));
    try testing.expect(frameFits(frame, 10, 10));
    try testing.expect(!frameFits(frame, 2, 2));
    try testing.expect(!frameFits(frame, 3, 1));
}

test "full-frame region equals natural output" {
    var frame = try makeFrame(testing.allocator, &.{ "abc", "def" });
    defer frame.deinit(testing.allocator);
    const got = try regionText(testing.allocator, frame, .{ .columns = 3, .rows = 2 });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abc\ndef\n", got);
}

test "clipping a region drops out-of-bounds cells" {
    var frame = try makeFrame(testing.allocator, &.{ "abcd", "efgh", "ijkl" });
    defer frame.deinit(testing.allocator);
    const got = try regionText(testing.allocator, frame, .{ .columns = 2, .rows = 2 });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ab\nef\n", got);
}

test "an overhanging region is blank-padded" {
    var frame = try makeFrame(testing.allocator, &.{"ab"});
    defer frame.deinit(testing.allocator);
    const got = try regionText(testing.allocator, frame, .{ .columns = 4, .rows = 2 });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ab  \n    \n", got);
}

test "cropFrameToCells clips and pads into an owned frame" {
    var frame = try makeFrame(testing.allocator, &.{ "abcd", "efgh" });
    defer frame.deinit(testing.allocator);
    var cropped = try cropFrameToCells(testing.allocator, frame, .{ .x = 1, .y = 0, .columns = 4, .rows = 2 });
    defer cropped.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), cropped.columns);
    try testing.expectEqual(@as(u32, 2), cropped.rows);
    try testing.expectEqualSlices(u21, &.{ 'b', 'c', 'd', ' ' }, cropped.codepoints[0..4]);
    try testing.expectEqualSlices(u21, &.{ 'f', 'g', 'h', ' ' }, cropped.codepoints[4..8]);
}

test "truecolor region carries colors and resets per row" {
    var frame: core.Frame = .empty;
    defer frame.deinit(testing.allocator);
    try frame.ensureCapacity(testing.allocator, 1, 1, .truecolor);
    frame.codepoints[0] = 'X';
    frame.fg[0] = .{ .r = 10, .g = 20, .b = 30 };
    frame.bg[0] = .{ .r = 0, .g = 0, .b = 0 };
    const got = try regionText(testing.allocator, frame, .{ .columns = 1, .rows = 1 });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "38;2;10;20;30") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\x1b[0m") != null);
}
