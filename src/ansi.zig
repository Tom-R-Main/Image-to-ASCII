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
                    try writeColor(writer, fg_lead, next_fg);
                    current_fg = next_fg;
                }
                if (current_bg == null or !eqlRgb(current_bg.?, next_bg)) {
                    try writeColor(writer, bg_lead, next_bg);
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

/// Write `<lead>R;G;Bm` for a truecolor SGR sequence. Longest possible is
/// 7 (lead) + 3+1 + 3+1 + 3 + 1 = 19 bytes.
fn writeColor(writer: *std.Io.Writer, lead: []const u8, c: Rgb8) !void {
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
