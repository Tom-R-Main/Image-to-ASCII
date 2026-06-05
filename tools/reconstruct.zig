//! Reconstruct an approximate image from a rendered `Frame`.
//!
//! For the table-driven block and Braille families we know each glyph's exact
//! subcell fill, so reconstruction is faithful and needs no font rasterizer.
//! Density (and any unknown codepoint) is reconstructed as a tone halftone from
//! the default ramp coverage — this is an approximation, and is the part that a
//! real font atlas will replace once `calibrate_font.zig` is implemented.

const std = @import("std");
const ascii = @import("image_to_ascii");
const common = @import("common.zig");

const ImageBuf = common.ImageBuf;
const Rgb = common.Rgb;

/// Subpixels per cell. 2x4 matches Braille granularity and reproduces quadrant
/// (2x2) and half-block (1x2) fills exactly by row/column duplication.
pub const cell_w = 2;
pub const cell_h = 4;

pub fn reconstruct(allocator: std.mem.Allocator, frame: ascii.Frame) !ImageBuf {
    const out_w = frame.columns * cell_w;
    const out_h = frame.rows * cell_h;
    var out = try ImageBuf.alloc(allocator, out_w, out_h);
    errdefer out.deinit(allocator);

    var row: u32 = 0;
    while (row < frame.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < frame.columns) : (col += 1) {
            const idx = @as(usize, row) * frame.columns + col;
            const cp = frame.codepoints[idx];
            const fg: Rgb = if (frame.color != .none) frame.fg[idx] else .{ .r = 255, .g = 255, .b = 255 };
            const bg: Rgb = if (frame.color != .none) frame.bg[idx] else .{ .r = 0, .g = 0, .b = 0 };

            var sy: u32 = 0;
            while (sy < cell_h) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < cell_w) : (sx += 1) {
                    const on = subpixelOn(cp, sx, sy);
                    out.set(col * cell_w + sx, row * cell_h + sy, if (on) fg else bg);
                }
            }
        }
    }
    return out;
}

fn subpixelOn(cp: u21, sx: u32, sy: u32) bool {
    // Braille block U+2800..U+28FF: the low byte is the dot mask.
    if (cp >= 0x2800 and cp <= 0x28FF) {
        const mask: u8 = @intCast(cp - 0x2800);
        return (mask & brailleDotMask(sx, sy)) != 0;
    }
    // Block quadrant / half / full / space.
    if (quadrantMaskOf(cp)) |mask| {
        const qx = sx; // 0..1
        const qy = sy / 2; // rows {0,1} -> top, {2,3} -> bottom
        const bit = @as(u4, 1) << @intCast(qy * 2 + qx);
        return (mask & bit) != 0;
    }
    // Density / unknown: ordered halftone of the glyph's ramp coverage.
    return orderedOn(sx, sy, densityCoverage(cp));
}

// Mirrors src/symbol.zig brailleDotMask (kept local; symbol.zig is core-internal).
fn brailleDotMask(x: u32, y: u32) u8 {
    return switch (y) {
        0 => if (x == 0) 0x01 else 0x08,
        1 => if (x == 0) 0x02 else 0x10,
        2 => if (x == 0) 0x04 else 0x20,
        3 => if (x == 0) 0x40 else 0x80,
        else => unreachable,
    };
}

// Reverse of src/symbol.zig quadrantCodepoint: bit layout is
// 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right.
fn quadrantMaskOf(cp: u21) ?u4 {
    return switch (cp) {
        ' ' => 0x0,
        '▘' => 0x1,
        '▝' => 0x2,
        '▀' => 0x3,
        '▖' => 0x4,
        '▌' => 0x5,
        '▞' => 0x6,
        '▛' => 0x7,
        '▗' => 0x8,
        '▚' => 0x9,
        '▐' => 0xa,
        '▜' => 0xb,
        '▄' => 0xc,
        '▙' => 0xd,
        '▟' => 0xe,
        '█' => 0xf,
        else => null,
    };
}

fn densityCoverage(cp: u21) f32 {
    const ramp = ascii.default_density_ramp;
    for (ramp, 0..) |c, i| {
        if (@as(u21, c) == cp) {
            return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ramp.len - 1));
        }
    }
    return 0.5;
}

fn orderedOn(sx: u32, sy: u32, coverage: f32) bool {
    // 2x4 Bayer-style thresholds in (0, 1).
    const thresholds = [cell_h][cell_w]f32{
        .{ 0.0625, 0.5625 },
        .{ 0.8125, 0.3125 },
        .{ 0.1875, 0.6875 },
        .{ 0.9375, 0.4375 },
    };
    return coverage > thresholds[sy][sx];
}

test "braille reconstruction respects dot layout" {
    const allocator = std.testing.allocator;
    // mask 0x47 = dots at (0,0),(0,1),(0,2),(0,3): full left column.
    var frame = ascii.Frame{
        .columns = 1,
        .rows = 1,
        .color = .none,
        .codepoints = try allocator.alloc(u21, 1),
        .fg = try allocator.alloc(common.Rgb, 0),
        .bg = try allocator.alloc(common.Rgb, 0),
    };
    defer frame.deinit(allocator);
    frame.codepoints[0] = 0x2800 + 0x47;

    var img = try reconstruct(allocator, frame);
    defer img.deinit(allocator);

    // Left column white (on), right column black (off).
    try std.testing.expectEqual(@as(u8, 255), img.at(0, 0).r);
    try std.testing.expectEqual(@as(u8, 0), img.at(1, 0).r);
    try std.testing.expectEqual(@as(u8, 255), img.at(0, 3).r);
}

test "half block reconstruction splits top and bottom" {
    const allocator = std.testing.allocator;
    var frame = ascii.Frame{
        .columns = 1,
        .rows = 1,
        .color = .truecolor,
        .codepoints = try allocator.alloc(u21, 1),
        .fg = try allocator.alloc(common.Rgb, 1),
        .bg = try allocator.alloc(common.Rgb, 1),
    };
    defer frame.deinit(allocator);
    frame.codepoints[0] = '▀';
    frame.fg[0] = .{ .r = 200, .g = 0, .b = 0 };
    frame.bg[0] = .{ .r = 0, .g = 0, .b = 200 };

    var img = try reconstruct(allocator, frame);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 200), img.at(0, 0).r); // top = fg
    try std.testing.expectEqual(@as(u8, 200), img.at(0, 3).b); // bottom = bg
}
