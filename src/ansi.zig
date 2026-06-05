//! ANSI/SGR emission for a rendered Frame.
//!
//! Output is byte-identical to formatted printing, but truecolor SGR sequences
//! are built with a hand-rolled decimal encoder into a small stack buffer and
//! flushed with a single writeAll, avoiding the format-string machinery and the
//! generic integer formatter on the per-color-change hot path. SGR runs are
//! coalesced (only emit on fg/bg change) and reset once per row.

const std = @import("std");

const core = @import("core.zig");

const Rgb8 = core.Rgb8;

const fg_lead = "\x1b[38;2;";
const bg_lead = "\x1b[48;2;";
const reset = "\x1b[0m";

pub const DiffError = error{
    FrameShapeMismatch,
    FrameColorMismatch,
};

pub const DiffMode = enum {
    error_on_mismatch,
    full_frame_on_mismatch,
};

pub const DiffOptions = struct {
    origin_row: u32 = 1,
    origin_col: u32 = 1,
    mismatch: DiffMode = .error_on_mismatch,
    reset_at_end: bool = true,
};

pub const DiffStats = struct {
    cells_examined: usize = 0,
    cells_changed: usize = 0,
    runs_emitted: usize = 0,
    bytes_emitted: usize = 0,
};

pub fn writeFrame(writer: *std.Io.Writer, frame: core.Frame) !void {
    var current_fg: ?Rgb8 = null;
    var current_bg: ?Rgb8 = null;

    var row: u32 = 0;
    while (row < frame.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < frame.columns) : (col += 1) {
            const idx = @as(usize, row) * frame.columns + col;
            if (frame.color != .none) {
                const next_fg = frame.fg[idx];
                const next_bg = frame.bg[idx];
                if (current_fg == null or !eqlRgb(current_fg.?, next_fg)) {
                    _ = try writeColor(writer, fg_lead, next_fg);
                    current_fg = next_fg;
                }
                if (current_bg == null or !eqlRgb(current_bg.?, next_bg)) {
                    _ = try writeColor(writer, bg_lead, next_bg);
                    current_bg = next_bg;
                }
            }

            try writer.printUnicodeCodepoint(frame.codepoints[idx]);
        }

        if (frame.color != .none) {
            try writer.writeAll(reset);
            current_fg = null;
            current_bg = null;
        }
        try writer.writeByte('\n');
    }
}

pub fn writeFrameDiff(
    writer: *std.Io.Writer,
    previous: ?*const core.Frame,
    current: *const core.Frame,
    options: DiffOptions,
) !DiffStats {
    if (previous) |prev| {
        if (prev.columns != current.columns or prev.rows != current.rows) {
            return switch (options.mismatch) {
                .error_on_mismatch => DiffError.FrameShapeMismatch,
                .full_frame_on_mismatch => writeFullFrameRuns(writer, current, options),
            };
        }
        if (prev.color != current.color) {
            return switch (options.mismatch) {
                .error_on_mismatch => DiffError.FrameColorMismatch,
                .full_frame_on_mismatch => writeFullFrameRuns(writer, current, options),
            };
        }

        return writeChangedRuns(writer, prev, current, options);
    }

    return writeFullFrameRuns(writer, current, options);
}

fn writeFullFrameRuns(writer: *std.Io.Writer, frame: *const core.Frame, options: DiffOptions) !DiffStats {
    var stats = DiffStats{
        .cells_examined = @as(usize, frame.columns) * frame.rows,
        .cells_changed = @as(usize, frame.columns) * frame.rows,
    };
    var state = ColorState{};

    var row: u32 = 0;
    while (row < frame.rows) : (row += 1) {
        if (frame.columns == 0) continue;
        stats.runs_emitted += 1;
        stats.bytes_emitted += try writeCursorMove(writer, options.origin_row + row, options.origin_col);
        stats.bytes_emitted += try writeCells(writer, frame, @as(usize, row) * frame.columns, frame.columns, &state);
    }

    if (options.reset_at_end and frame.color != .none) {
        try writer.writeAll(reset);
        stats.bytes_emitted += reset.len;
    }

    return stats;
}

fn writeChangedRuns(
    writer: *std.Io.Writer,
    previous: *const core.Frame,
    current: *const core.Frame,
    options: DiffOptions,
) !DiffStats {
    var stats = DiffStats{
        .cells_examined = @as(usize, current.columns) * current.rows,
    };
    var state = ColorState{};

    var row: u32 = 0;
    while (row < current.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < current.columns) {
            const idx = @as(usize, row) * current.columns + col;
            if (!cellChanged(previous, current, idx)) {
                col += 1;
                continue;
            }

            const run_start = col;
            var run_len: u32 = 0;
            while (col < current.columns) : (col += 1) {
                const run_idx = @as(usize, row) * current.columns + col;
                if (!cellChanged(previous, current, run_idx)) break;
                run_len += 1;
            }

            stats.cells_changed += run_len;
            stats.runs_emitted += 1;
            stats.bytes_emitted += try writeCursorMove(writer, options.origin_row + row, options.origin_col + run_start);
            stats.bytes_emitted += try writeCells(writer, current, @as(usize, row) * current.columns + run_start, run_len, &state);
        }
    }

    if (options.reset_at_end and current.color != .none and stats.runs_emitted > 0) {
        try writer.writeAll(reset);
        stats.bytes_emitted += reset.len;
    }

    return stats;
}

fn cellChanged(previous: *const core.Frame, current: *const core.Frame, idx: usize) bool {
    if (previous.codepoints[idx] != current.codepoints[idx]) return true;
    if (current.color == .none) return false;
    return !eqlRgb(previous.fg[idx], current.fg[idx]) or !eqlRgb(previous.bg[idx], current.bg[idx]);
}

const ColorState = struct {
    fg: ?Rgb8 = null,
    bg: ?Rgb8 = null,
};

fn writeCells(
    writer: *std.Io.Writer,
    frame: *const core.Frame,
    start_idx: usize,
    len: u32,
    state: *ColorState,
) !usize {
    var bytes: usize = 0;
    var offset: u32 = 0;
    while (offset < len) : (offset += 1) {
        const idx = start_idx + offset;
        if (frame.color != .none) {
            const next_fg = frame.fg[idx];
            const next_bg = frame.bg[idx];
            if (state.fg == null or !eqlRgb(state.fg.?, next_fg)) {
                bytes += try writeColor(writer, fg_lead, next_fg);
                state.fg = next_fg;
            }
            if (state.bg == null or !eqlRgb(state.bg.?, next_bg)) {
                bytes += try writeColor(writer, bg_lead, next_bg);
                state.bg = next_bg;
            }
        }
        bytes += try writeCodepoint(writer, frame.codepoints[idx]);
    }
    return bytes;
}

fn writeCursorMove(writer: *std.Io.Writer, row: u32, col: u32) !usize {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    buf[n] = 0x1b;
    n += 1;
    buf[n] = '[';
    n += 1;
    n += writeU32Decimal(buf[n..], row);
    buf[n] = ';';
    n += 1;
    n += writeU32Decimal(buf[n..], col);
    buf[n] = 'H';
    n += 1;
    try writer.writeAll(buf[0..n]);
    return n;
}

fn writeCodepoint(writer: *std.Io.Writer, codepoint: u21) !usize {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch |err| switch (err) {
        error.CodepointTooLarge, error.Utf8CannotEncodeSurrogateHalf => l: {
            buf[0..3].* = std.unicode.replacement_character_utf8;
            break :l 3;
        },
    };
    try writer.writeAll(buf[0..len]);
    return len;
}

/// Write `<lead>R;G;Bm` for a truecolor SGR sequence. Longest possible is
/// 7 (lead) + 3+1 + 3+1 + 3 + 1 = 19 bytes.
fn writeColor(writer: *std.Io.Writer, lead: []const u8, c: Rgb8) !usize {
    var buf: [24]u8 = undefined;
    @memcpy(buf[0..lead.len], lead);
    var n: usize = lead.len;
    n += writeDecimal(buf[n..], c.r);
    buf[n] = ';';
    n += 1;
    n += writeDecimal(buf[n..], c.g);
    buf[n] = ';';
    n += 1;
    n += writeDecimal(buf[n..], c.b);
    buf[n] = 'm';
    n += 1;
    try writer.writeAll(buf[0..n]);
    return n;
}

/// Minimal-width decimal for a byte (no leading zeros), matching `{d}`.
fn writeDecimal(dst: []u8, v: u8) usize {
    if (v >= 100) {
        dst[0] = '0' + v / 100;
        dst[1] = '0' + (v / 10) % 10;
        dst[2] = '0' + v % 10;
        return 3;
    } else if (v >= 10) {
        dst[0] = '0' + v / 10;
        dst[1] = '0' + v % 10;
        return 2;
    } else {
        dst[0] = '0' + v;
        return 1;
    }
}

fn writeU32Decimal(dst: []u8, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var value = v;
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(value % 10));
        n += 1;
        value /= 10;
        if (value == 0) break;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = tmp[n - 1 - i];
    }
    return n;
}

fn eqlRgb(a: Rgb8, b: Rgb8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

test "writeDecimal matches std formatting for all bytes" {
    var v: u16 = 0;
    while (v < 256) : (v += 1) {
        var mine: [3]u8 = undefined;
        const n = writeDecimal(&mine, @intCast(v));
        var expected: [3]u8 = undefined;
        const exp = try std.fmt.bufPrint(&expected, "{d}", .{v});
        try std.testing.expectEqualStrings(exp, mine[0..n]);
    }
}
