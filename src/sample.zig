const std = @import("std");

const color = @import("color.zig");
const core = @import("core.zig");
const luma = @import("luma.zig");

pub const Size = struct {
    columns: u32,
    rows: u32,
};

pub const Sample = struct {
    linear: color.LinearRgb,
    rgb: core.Rgb8,
    luma: f32,
};

pub fn fittedSize(image: core.ImageView, terminal: core.TerminalProfile, fit: core.FitMode) Size {
    if (fit == .stretch or fit == .cover) {
        return .{ .columns = terminal.columns, .rows = terminal.rows };
    }

    const source_aspect = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(image.height));
    const terminal_aspect = (@as(f32, @floatFromInt(terminal.columns)) /
        @as(f32, @floatFromInt(terminal.rows))) * terminal.cell_aspect;

    if (terminal_aspect > source_aspect) {
        const rows = terminal.rows;
        const cols_float = (@as(f32, @floatFromInt(rows)) * source_aspect) / terminal.cell_aspect;
        return .{
            .columns = @max(1, @min(terminal.columns, @as(u32, @intFromFloat(@floor(cols_float))))),
            .rows = rows,
        };
    }

    const columns = terminal.columns;
    const rows_float = (@as(f32, @floatFromInt(columns)) * terminal.cell_aspect) / source_aspect;
    return .{
        .columns = columns,
        .rows = @max(1, @min(terminal.rows, @as(u32, @intFromFloat(@floor(rows_float))))),
    };
}

pub fn areaSample(
    image: core.ImageView,
    terminal: core.TerminalProfile,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
) Sample {
    const clamped_x0 = std.math.clamp(x0, 0.0, @as(f32, @floatFromInt(image.width)));
    const clamped_y0 = std.math.clamp(y0, 0.0, @as(f32, @floatFromInt(image.height)));
    const clamped_x1 = std.math.clamp(x1, clamped_x0, @as(f32, @floatFromInt(image.width)));
    const clamped_y1 = std.math.clamp(y1, clamped_y0, @as(f32, @floatFromInt(image.height)));

    const start_x: u32 = @intFromFloat(@floor(clamped_x0));
    const start_y: u32 = @intFromFloat(@floor(clamped_y0));
    const end_x: u32 = @max(start_x + 1, @as(u32, @intFromFloat(@ceil(clamped_x1))));
    const end_y: u32 = @max(start_y + 1, @as(u32, @intFromFloat(@ceil(clamped_y1))));

    var accum = color.LinearRgb{ .r = 0.0, .g = 0.0, .b = 0.0 };
    var weight_sum: f32 = 0.0;

    var y = start_y;
    while (y < @min(end_y, image.height)) : (y += 1) {
        const py0 = @as(f32, @floatFromInt(y));
        const py1 = py0 + 1.0;
        const y_overlap = @max(0.0, @min(py1, clamped_y1) - @max(py0, clamped_y0));

        var x = start_x;
        while (x < @min(end_x, image.width)) : (x += 1) {
            const px0 = @as(f32, @floatFromInt(x));
            const px1 = px0 + 1.0;
            const x_overlap = @max(0.0, @min(px1, clamped_x1) - @max(px0, clamped_x0));
            const weight = x_overlap * y_overlap;
            if (weight == 0.0) continue;

            const rgb = color.compositeOver(pixelAt(image, x, y), terminal.background);
            accum.r += rgb.r * weight;
            accum.g += rgb.g * weight;
            accum.b += rgb.b * weight;
            weight_sum += weight;
        }
    }

    if (weight_sum > 0.0) {
        accum.r /= weight_sum;
        accum.g /= weight_sum;
        accum.b /= weight_sum;
    }

    return .{
        .linear = accum,
        .rgb = color.encodeSrgb(accum),
        .luma = luma.perceptualLuminance(accum.r, accum.g, accum.b),
    };
}

pub fn cellRegion(image: core.ImageView, size: Size, cell_x: u32, cell_y: u32, sx: u32, sy: u32, sub_x: u32, sub_y: u32) [4]f32 {
    const virtual_w = size.columns * sx;
    const virtual_h = size.rows * sy;
    const vx = cell_x * sx + sub_x;
    const vy = cell_y * sy + sub_y;

    const x0 = (@as(f32, @floatFromInt(vx)) * @as(f32, @floatFromInt(image.width))) /
        @as(f32, @floatFromInt(virtual_w));
    const x1 = (@as(f32, @floatFromInt(vx + 1)) * @as(f32, @floatFromInt(image.width))) /
        @as(f32, @floatFromInt(virtual_w));
    const y0 = (@as(f32, @floatFromInt(vy)) * @as(f32, @floatFromInt(image.height))) /
        @as(f32, @floatFromInt(virtual_h));
    const y1 = (@as(f32, @floatFromInt(vy + 1)) * @as(f32, @floatFromInt(image.height))) /
        @as(f32, @floatFromInt(virtual_h));

    return .{ x0, y0, x1, y1 };
}

fn pixelAt(image: core.ImageView, x: u32, y: u32) core.Rgba8 {
    const row_pixels = image.stride / @sizeOf(core.Rgba8);
    return image.pixels[@as(usize, y) * row_pixels + x];
}

test "contain fit accounts for terminal cell aspect" {
    const pixels = [_]core.Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }};
    const size = fittedSize(
        .{ .width = 1, .height = 1, .stride = @sizeOf(core.Rgba8), .pixels = &pixels },
        .{ .columns = 80, .rows = 80, .cell_aspect = 0.5 },
        .contain,
    );

    try std.testing.expectEqual(@as(u32, 80), size.columns);
    try std.testing.expectEqual(@as(u32, 40), size.rows);
}

test "area sample averages tiny image in linear light" {
    const pixels = [_]core.Rgba8{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    const s = areaSample(
        .{ .width = 2, .height = 1, .stride = 2 * @sizeOf(core.Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1 },
        0.0,
        0.0,
        2.0,
        1.0,
    );

    try std.testing.expect(s.rgb.r > 180 and s.rgb.r < 190);
}
