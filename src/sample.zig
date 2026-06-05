const std = @import("std");

const color = @import("color.zig");
const core = @import("core.zig");
const integral = @import("integral.zig");
const luma = @import("luma.zig");

pub const IntegralLuma = integral.IntegralLuma;

pub const SampleStrategy = enum {
    /// Choose per the pixel-visit threshold (currently: always direct for
    /// one-shot, because building an integral image is itself an O(image) pass
    /// and only pays off when reused across renders).
    auto,
    /// Exact per-cell area weighting. The reference path.
    direct_box,
    /// Integral-image (summed-area table) luma sampling. O(1) per cell after an
    /// O(image) build. Monochrome only; intended for reuse (e.g. live resize).
    integral_luma,
};

pub const SamplerPolicy = enum {
    direct_box,
    span_precompute,
    integral_luma,
    prepared_integral_luma,
};

/// Building the integral table is an O(image) pass, so for a single one-shot
/// render it is at best a wash; only reuse across multiple renders (live resize)
/// amortizes it. `auto` therefore stays on the direct sampler until a reuse path
/// exists. The threshold is in source pixels for future opt-in.
pub const integral_pixel_threshold: usize = std.math.maxInt(usize);

/// Decide whether to build/use the integral luma table. Color modes always use
/// the direct sampler because the luma table cannot reconstruct per-subcell RGB.
pub fn useIntegral(strategy: SampleStrategy, image: core.ImageView, color_mode: core.ColorMode) bool {
    if (color_mode != .none) return false;
    return switch (strategy) {
        .direct_box => false,
        .integral_luma => true,
        .auto => (@as(usize, image.width) * @as(usize, image.height)) >= integral_pixel_threshold,
    };
}

/// Average perceptual luma over a source region, via the integral table when
/// provided, otherwise the direct area sampler. Both produce the same value to
/// floating-point rounding (see integral.zig).
pub fn regionLuma(
    image: core.ImageView,
    terminal: core.TerminalProfile,
    table: ?*const IntegralLuma,
    region: [4]f32,
) f32 {
    if (table) |t| return t.regionLuma(region[0], region[1], region[2], region[3]);
    return areaSample(image, terminal, region[0], region[1], region[2], region[3]).luma;
}

pub const Size = struct {
    columns: u32,
    rows: u32,
};

/// A render mapping describes both the output cell grid and the rectangle of
/// source pixels (in source coordinates) that maps onto it. `contain` and
/// `stretch` use the whole source; `cover` fills the grid and crops the source.
pub const Mapping = struct {
    columns: u32,
    rows: u32,
    src_x0: f32,
    src_y0: f32,
    src_x1: f32,
    src_y1: f32,
};

pub const Sample = struct {
    linear: color.LinearRgb,
    luma: f32,

    /// Encode this sample's linear color to sRGB. Deferred (not computed during
    /// sampling) because most subcell samples are only used for their linear
    /// color or luma; encoding eagerly would run `linearToSrgb` (a `pow`) for
    /// every subcell even when the result is discarded.
    pub fn rgb(self: Sample) core.Rgb8 {
        return color.encodeSrgb(self.linear);
    }
};

pub const AxisSpan = struct {
    start: u32,
    end: u32,
    lo: f32,
    hi: f32,
    first_weight: f32,
    last_weight: f32,

    fn weight(self: AxisSpan, pixel: u32) f32 {
        if (self.end <= self.start) return 0.0;
        if (self.end == self.start + 1) return self.hi - self.lo;
        if (pixel == self.start) return self.first_weight;
        if (pixel == self.end - 1) return self.last_weight;
        return 1.0;
    }
};

pub const SamplePlan = struct {
    mapping: Mapping,
    subcells_x: u32,
    subcells_y: u32,
    x_spans: []AxisSpan,
    y_spans: []AxisSpan,

    pub fn init(
        allocator: std.mem.Allocator,
        image: core.ImageView,
        mapping: Mapping,
        subcells_x: u32,
        subcells_y: u32,
    ) !SamplePlan {
        const virtual_w = try std.math.mul(usize, mapping.columns, subcells_x);
        const virtual_h = try std.math.mul(usize, mapping.rows, subcells_y);

        const x_spans = try allocator.alloc(AxisSpan, virtual_w);
        errdefer allocator.free(x_spans);
        const y_spans = try allocator.alloc(AxisSpan, virtual_h);
        errdefer allocator.free(y_spans);

        fillSpans(x_spans, mapping.src_x0, mapping.src_x1, image.width);
        fillSpans(y_spans, mapping.src_y0, mapping.src_y1, image.height);

        return .{
            .mapping = mapping,
            .subcells_x = subcells_x,
            .subcells_y = subcells_y,
            .x_spans = x_spans,
            .y_spans = y_spans,
        };
    }

    pub fn deinit(self: *SamplePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.x_spans);
        allocator.free(self.y_spans);
        self.* = undefined;
    }

    pub fn xSpan(self: SamplePlan, cell_x: u32, sub_x: u32) AxisSpan {
        return self.x_spans[cell_x * self.subcells_x + sub_x];
    }

    pub fn ySpan(self: SamplePlan, cell_y: u32, sub_y: u32) AxisSpan {
        return self.y_spans[cell_y * self.subcells_y + sub_y];
    }
};

pub fn fittedSize(image: core.ImageView, terminal: core.TerminalProfile, fit: core.FitMode) Size {
    const mapping = fitMapping(image, terminal, fit);
    return .{ .columns = mapping.columns, .rows = mapping.rows };
}

pub fn fitMapping(image: core.ImageView, terminal: core.TerminalProfile, fit: core.FitMode) Mapping {
    const w = @as(f32, @floatFromInt(image.width));
    const h = @as(f32, @floatFromInt(image.height));
    const full_source = Mapping{
        .columns = terminal.columns,
        .rows = terminal.rows,
        .src_x0 = 0.0,
        .src_y0 = 0.0,
        .src_x1 = w,
        .src_y1 = h,
    };

    const source_aspect = w / h;
    const terminal_aspect = (@as(f32, @floatFromInt(terminal.columns)) /
        @as(f32, @floatFromInt(terminal.rows))) * terminal.cell_aspect;

    switch (fit) {
        .stretch => return full_source,
        .cover => {
            // Keep the full grid; crop the source so its displayed aspect
            // matches the grid and the grid is fully covered (centered crop).
            var mapping = full_source;
            if (source_aspect > terminal_aspect) {
                const crop_w = h * terminal_aspect;
                const x0 = (w - crop_w) / 2.0;
                mapping.src_x0 = x0;
                mapping.src_x1 = x0 + crop_w;
            } else {
                const crop_h = w / terminal_aspect;
                const y0 = (h - crop_h) / 2.0;
                mapping.src_y0 = y0;
                mapping.src_y1 = y0 + crop_h;
            }
            return mapping;
        },
        .contain => {
            // Shrink the grid so the whole source fits without distortion.
            if (terminal_aspect > source_aspect) {
                const rows = terminal.rows;
                const cols_float = (@as(f32, @floatFromInt(rows)) * source_aspect) / terminal.cell_aspect;
                return .{
                    .columns = @max(1, @min(terminal.columns, @as(u32, @intFromFloat(@floor(cols_float))))),
                    .rows = rows,
                    .src_x0 = 0.0,
                    .src_y0 = 0.0,
                    .src_x1 = w,
                    .src_y1 = h,
                };
            }

            const columns = terminal.columns;
            const rows_float = (@as(f32, @floatFromInt(columns)) * terminal.cell_aspect) / source_aspect;
            return .{
                .columns = columns,
                .rows = @max(1, @min(terminal.rows, @as(u32, @intFromFloat(@floor(rows_float))))),
                .src_x0 = 0.0,
                .src_y0 = 0.0,
                .src_x1 = w,
                .src_y1 = h,
            };
        },
    }
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
        .luma = luma.perceptualLuminance(accum.r, accum.g, accum.b),
    };
}

pub fn areaSampleSpans(
    image: core.ImageView,
    terminal: core.TerminalProfile,
    x_span: AxisSpan,
    y_span: AxisSpan,
) Sample {
    var accum = color.LinearRgb{ .r = 0.0, .g = 0.0, .b = 0.0 };
    var weight_sum: f32 = 0.0;

    var y = y_span.start;
    while (y < y_span.end) : (y += 1) {
        const y_weight = y_span.weight(y);
        if (y_weight == 0.0) continue;

        var x = x_span.start;
        while (x < x_span.end) : (x += 1) {
            const weight = x_span.weight(x) * y_weight;
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
        .luma = luma.perceptualLuminance(accum.r, accum.g, accum.b),
    };
}

pub fn regionLumaSpans(
    image: core.ImageView,
    terminal: core.TerminalProfile,
    table: ?*const IntegralLuma,
    x_span: AxisSpan,
    y_span: AxisSpan,
) f32 {
    if (table) |t| return t.regionLuma(x_span.lo, y_span.lo, x_span.hi, y_span.hi);
    return areaSampleSpans(image, terminal, x_span, y_span).luma;
}

pub fn cellRegion(mapping: Mapping, cell_x: u32, cell_y: u32, sx: u32, sy: u32, sub_x: u32, sub_y: u32) [4]f32 {
    const virtual_w = mapping.columns * sx;
    const virtual_h = mapping.rows * sy;
    const vx = cell_x * sx + sub_x;
    const vy = cell_y * sy + sub_y;

    const span_x = mapping.src_x1 - mapping.src_x0;
    const span_y = mapping.src_y1 - mapping.src_y0;

    const x0 = mapping.src_x0 + (@as(f32, @floatFromInt(vx)) * span_x) / @as(f32, @floatFromInt(virtual_w));
    const x1 = mapping.src_x0 + (@as(f32, @floatFromInt(vx + 1)) * span_x) / @as(f32, @floatFromInt(virtual_w));
    const y0 = mapping.src_y0 + (@as(f32, @floatFromInt(vy)) * span_y) / @as(f32, @floatFromInt(virtual_h));
    const y1 = mapping.src_y0 + (@as(f32, @floatFromInt(vy + 1)) * span_y) / @as(f32, @floatFromInt(virtual_h));

    return .{ x0, y0, x1, y1 };
}

fn fillSpans(spans: []AxisSpan, src_0: f32, src_1: f32, source_len: u32) void {
    const span = src_1 - src_0;
    const virtual_len = @as(f32, @floatFromInt(spans.len));
    for (spans, 0..) |*out, i| {
        const i_f = @as(f32, @floatFromInt(i));
        out.* = axisSpan(
            source_len,
            src_0 + (i_f * span) / virtual_len,
            src_0 + ((i_f + 1.0) * span) / virtual_len,
        );
    }
}

fn axisSpan(source_len: u32, lo: f32, hi: f32) AxisSpan {
    const source_len_f = @as(f32, @floatFromInt(source_len));
    const clamped_lo = std.math.clamp(lo, 0.0, source_len_f);
    const clamped_hi = std.math.clamp(hi, clamped_lo, source_len_f);

    const start: u32 = @intFromFloat(@floor(clamped_lo));
    const unclipped_end: u32 = @max(start + 1, @as(u32, @intFromFloat(@ceil(clamped_hi))));
    const end = @min(unclipped_end, source_len);
    const effective_start = @min(start, source_len - 1);
    const effective_end = @max(effective_start + 1, end);
    const first_hi = @min(@as(f32, @floatFromInt(effective_start + 1)), clamped_hi);
    const last_lo = @max(@as(f32, @floatFromInt(effective_end - 1)), clamped_lo);

    return .{
        .start = effective_start,
        .end = effective_end,
        .lo = clamped_lo,
        .hi = clamped_hi,
        .first_weight = @max(0.0, first_hi - clamped_lo),
        .last_weight = @max(0.0, clamped_hi - last_lo),
    };
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

test "cover fit fills the grid and crops the source" {
    const pixels = [_]core.Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }};
    // 100x100 source into an 80x40 grid at cell_aspect 0.5 has a display aspect
    // of (80/40)*0.5 = 1.0, which matches the square source, so no crop.
    const square = fitMapping(
        .{ .width = 100, .height = 100, .stride = @sizeOf(core.Rgba8), .pixels = &pixels },
        .{ .columns = 80, .rows = 40, .cell_aspect = 0.5 },
        .cover,
    );
    try std.testing.expectEqual(@as(u32, 80), square.columns);
    try std.testing.expectEqual(@as(u32, 40), square.rows);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), square.src_x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), square.src_x1, 0.001);

    // A wide 200x100 source into the same grid (display aspect 1.0) must crop
    // the sides: crop_w = height * display_aspect = 100, centered at x in [50,150].
    const wide = fitMapping(
        .{ .width = 200, .height = 100, .stride = @sizeOf(core.Rgba8), .pixels = &pixels },
        .{ .columns = 80, .rows = 40, .cell_aspect = 0.5 },
        .cover,
    );
    try std.testing.expectEqual(@as(u32, 80), wide.columns);
    try std.testing.expectEqual(@as(u32, 40), wide.rows);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), wide.src_x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), wide.src_x1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), wide.src_y0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), wide.src_y1, 0.001);
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

    try std.testing.expect(s.rgb().r > 180 and s.rgb().r < 190);
}

test "sample plan spans match cell regions" {
    const allocator = std.testing.allocator;
    const pixels = [_]core.Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }};
    const image = core.ImageView{ .width = 17, .height = 11, .stride = @sizeOf(core.Rgba8), .pixels = &pixels };
    const mapping = fitMapping(image, .{ .columns = 5, .rows = 3 }, .stretch);

    var plan = try SamplePlan.init(allocator, image, mapping, 2, 4);
    defer plan.deinit(allocator);

    const region = cellRegion(mapping, 3, 2, 2, 4, 1, 3);
    const xs = plan.xSpan(3, 1);
    const ys = plan.ySpan(2, 3);

    try std.testing.expectApproxEqAbs(region[0], xs.lo, 0.0001);
    try std.testing.expectApproxEqAbs(region[2], xs.hi, 0.0001);
    try std.testing.expectApproxEqAbs(region[1], ys.lo, 0.0001);
    try std.testing.expectApproxEqAbs(region[3], ys.hi, 0.0001);
}

test "span sampler matches direct area sampler" {
    const allocator = std.testing.allocator;
    var pixels: [7 * 5]core.Rgba8 = undefined;
    for (&pixels, 0..) |*p, i| {
        const x: u8 = @intCast(i % 7);
        const y: u8 = @intCast(i / 7);
        p.* = .{ .r = x * 31, .g = y * 47, .b = x * y * 9, .a = 255 };
    }
    const image = core.ImageView{ .width = 7, .height = 5, .stride = 7 * @sizeOf(core.Rgba8), .pixels = &pixels };
    const terminal = core.TerminalProfile{ .columns = 3, .rows = 2 };
    const mapping = fitMapping(image, terminal, .cover);

    var plan = try SamplePlan.init(allocator, image, mapping, 4, 3);
    defer plan.deinit(allocator);

    var cell_y: u32 = 0;
    while (cell_y < mapping.rows) : (cell_y += 1) {
        var cell_x: u32 = 0;
        while (cell_x < mapping.columns) : (cell_x += 1) {
            var sub_y: u32 = 0;
            while (sub_y < 3) : (sub_y += 1) {
                var sub_x: u32 = 0;
                while (sub_x < 4) : (sub_x += 1) {
                    const region = cellRegion(mapping, cell_x, cell_y, 4, 3, sub_x, sub_y);
                    const direct = areaSample(image, terminal, region[0], region[1], region[2], region[3]);
                    const planned = areaSampleSpans(image, terminal, plan.xSpan(cell_x, sub_x), plan.ySpan(cell_y, sub_y));

                    try std.testing.expectApproxEqAbs(direct.linear.r, planned.linear.r, 0.0001);
                    try std.testing.expectApproxEqAbs(direct.linear.g, planned.linear.g, 0.0001);
                    try std.testing.expectApproxEqAbs(direct.linear.b, planned.linear.b, 0.0001);
                    try std.testing.expectApproxEqAbs(direct.luma, planned.luma, 0.0001);
                }
            }
        }
    }
}
