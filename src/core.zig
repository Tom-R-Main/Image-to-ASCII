const std = @import("std");

const ansi = @import("ansi.zig");
const color = @import("color.zig");
const dither = @import("dither.zig");
const glyph = @import("glyph.zig");
const luma = @import("luma.zig");
const pixel = @import("pixel.zig");
const sample = @import("sample.zig");
const symbol = @import("symbol.zig");

pub const Rgba8 = pixel.Rgba8;
pub const Rgb8 = pixel.Rgb8;
pub const AxisSpan = sample.AxisSpan;
pub const ColorStat = color.ColorStat;
pub const SamplePlan = sample.SamplePlan;
pub const SampleStrategy = sample.SampleStrategy;

pub const ValidationError = error{
    EmptyImage,
    EmptyTerminal,
    InvalidStride,
    InvalidPixelBuffer,
    InvalidCellAspect,
    EmptyRamp,
    InvalidRampCodepoint,
};

pub const RenderError = ValidationError || error{
    UnsupportedRenderMode,
    UnsupportedColorMode,
};

pub const Error = RenderError;

pub const RenderMode = enum {
    density,
    partition,
    braille,
    glyph_tone,
    glyph_structure,
};

pub const PartitionKind = enum {
    density_1x1,
    half_1x2,
    quadrant_2x2,
    sextant_2x3,
    octant_2x4,
};

pub const Quality = enum {
    preview,
    balanced,
    high,
};

pub const ColorMode = enum {
    none,
    ansi16,
    ansi256,
    truecolor,
};

pub const TerminalSymbols = enum {
    ascii_only,
    block_basic,
    block_legacy,
    braille,
    glyphs,
};

pub const FitMode = enum {
    contain,
    cover,
    stretch,
};

pub const DitherMode = enum {
    none,
    ordered_2x2,
    ordered_4x4,
    floyd_steinberg,
};

pub const ImageView = struct {
    width: u32,
    height: u32,
    stride: usize,
    pixels: []const Rgba8,
};

pub const TerminalProfile = struct {
    columns: u32,
    rows: u32,
    cell_aspect: f32 = 0.5,
    color: ColorMode = .truecolor,
    symbols: TerminalSymbols = .block_basic,
    background: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
};

pub const default_density_ramp = " .:-=+*#%@";

pub const Options = struct {
    mode: RenderMode = .partition,
    partition: PartitionKind = .half_1x2,
    quality: Quality = .balanced,
    fit: FitMode = .contain,
    dither: DitherMode = .none,
    invert: bool = false,
    contrast: f32 = 1.0,
    brightness: f32 = 0.0,
    ramp: []const u8 = default_density_ramp,
    /// Representative-color policy for two-color symbol families (quadrant,
    /// braille, and future sextant/octant/glyph modes). Defaults to the robust
    /// trimmed mean recommended for photographic content.
    color_stat: ColorStat = .trimmed_mean,
    /// Sampling strategy. `auto` (default) uses the exact direct sampler for
    /// one-shot renders; `integral_luma` opts into summed-area-table sampling for
    /// monochrome modes (intended for reuse across renders). Both produce the
    /// same output to floating-point rounding.
    sample_strategy: SampleStrategy = .auto,
};

pub const PrepareOptions = struct {
    /// Precompute luma only when the caller opts into summed-area sampling.
    /// `auto` remains direct for one-shot renders, matching `Options`.
    sample_strategy: SampleStrategy = .auto,
};

pub const PreparedImage = struct {
    image: ImageView,
    luma_sat: ?sample.IntegralLuma = null,
    luma_background: Rgba8,

    pub fn deinit(self: *PreparedImage, allocator: std.mem.Allocator) void {
        if (self.luma_sat) |*sat| sat.deinit(allocator);
        self.* = undefined;
    }

    fn integralFor(self: *const PreparedImage, terminal: TerminalProfile, options: Options) ?*const sample.IntegralLuma {
        if (!sample.useIntegral(options.sample_strategy, self.image, terminal.color)) return null;
        if (!eqlRgba(self.luma_background, terminal.background)) return null;
        if (self.luma_sat) |*sat| return sat;
        return null;
    }
};

const RenderContext = struct {
    luma_sat: ?*const sample.IntegralLuma = null,
};

pub const Frame = struct {
    columns: u32,
    rows: u32,
    color: ColorMode,
    codepoints: []u21,
    fg: []Rgb8,
    bg: []Rgb8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.codepoints);
        allocator.free(self.fg);
        allocator.free(self.bg);
        self.* = undefined;
    }
};

pub fn validateImage(image: ImageView) ValidationError!void {
    if (image.width == 0 or image.height == 0) return ValidationError.EmptyImage;

    const min_stride = std.math.mul(usize, image.width, @sizeOf(Rgba8)) catch return ValidationError.InvalidStride;
    if (image.stride < min_stride or image.stride % @sizeOf(Rgba8) != 0) return ValidationError.InvalidStride;

    const rows_before_last = image.height - 1;
    const prefix_bytes = std.math.mul(usize, rows_before_last, image.stride) catch return ValidationError.InvalidPixelBuffer;
    const required_bytes = std.math.add(usize, prefix_bytes, min_stride) catch return ValidationError.InvalidPixelBuffer;
    const available_bytes = std.math.mul(usize, image.pixels.len, @sizeOf(Rgba8)) catch return ValidationError.InvalidPixelBuffer;
    if (available_bytes < required_bytes) return ValidationError.InvalidPixelBuffer;
}

pub fn validateTerminal(terminal: TerminalProfile) ValidationError!void {
    if (terminal.columns == 0 or terminal.rows == 0) return ValidationError.EmptyTerminal;
    if (!std.math.isFinite(terminal.cell_aspect) or terminal.cell_aspect <= 0.0) {
        return ValidationError.InvalidCellAspect;
    }
}

pub fn validateOptions(options: Options) ValidationError!void {
    if (options.ramp.len == 0) return ValidationError.EmptyRamp;
    for (options.ramp) |c| {
        if (c < 0x20 or c == 0x7f) return ValidationError.InvalidRampCodepoint;
    }
}

pub fn validateInputs(image: ImageView, terminal: TerminalProfile, options: Options) ValidationError!void {
    try validateImage(image);
    try validateTerminal(terminal);
    try validateOptions(options);
}

pub fn renderToCells(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !Frame {
    try validateInputs(image, terminal, options);
    try validateSupportedColor(terminal.color);

    return renderToCellsWithContext(allocator, image, terminal, options, .{});
}

pub fn prepareImage(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: PrepareOptions,
) !PreparedImage {
    try validateImage(image);
    try validateTerminal(terminal);

    var prepared = PreparedImage{
        .image = image,
        .luma_background = terminal.background,
    };
    errdefer prepared.deinit(allocator);

    if (sample.useIntegral(options.sample_strategy, image, terminal.color)) {
        prepared.luma_sat = try sample.IntegralLuma.build(allocator, image, terminal.background);
    }

    return prepared;
}

pub fn renderPreparedToCells(
    allocator: std.mem.Allocator,
    prepared: *const PreparedImage,
    terminal: TerminalProfile,
    options: Options,
) !Frame {
    try validateInputs(prepared.image, terminal, options);
    try validateSupportedColor(terminal.color);

    return renderToCellsWithContext(allocator, prepared.image, terminal, options, .{
        .luma_sat = prepared.integralFor(terminal, options),
    });
}

fn renderToCellsWithContext(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !Frame {
    return switch (options.mode) {
        .density => renderDensity(allocator, image, terminal, options, context),
        .partition => switch (options.partition) {
            .density_1x1 => renderDensity(allocator, image, terminal, options, context),
            .half_1x2 => renderHalfBlock(allocator, image, terminal, options),
            .quadrant_2x2 => renderQuadrant(allocator, image, terminal, options, context),
            else => Error.UnsupportedRenderMode,
        },
        .braille => renderBraille(allocator, image, terminal, options, context),
        .glyph_tone => renderGlyphTone(allocator, image, terminal, options, context),
        .glyph_structure => renderGlyphStructure(allocator, image, terminal, options, context),
    };
}

/// Coverage of a codepoint in the built-in glyph-tone atlas, for tools.
pub fn defaultGlyphCoverage(codepoint: u21) ?f32 {
    return glyph.defaultCoverage(codepoint);
}

/// Perceived tone in [0, 1] of a codepoint (coverage normalized by the densest
/// glyph), for tools reconstructing a glyph cell.
pub fn defaultGlyphTone(codepoint: u21) ?f32 {
    return glyph.defaultTone(codepoint);
}

pub fn defaultGlyphMaskBit(codepoint: u21, x: u32, y: u32) ?bool {
    return glyph.defaultMaskBit(codepoint, x, y);
}

pub const default_glyph_cell_width = glyph.cell_width;
pub const default_glyph_cell_height = glyph.cell_height;

pub fn renderToWriter(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !void {
    var frame = try renderToCells(allocator, image, terminal, options);
    defer frame.deinit(allocator);

    try ansi.writeFrame(writer, frame);
}

pub fn renderFrameToWriter(writer: *std.Io.Writer, frame: Frame) !void {
    try ansi.writeFrame(writer, frame);
}

fn validateSupportedColor(color_mode: ColorMode) RenderError!void {
    switch (color_mode) {
        .none, .truecolor => {},
        .ansi16, .ansi256 => return Error.UnsupportedColorMode,
    }
}

fn allocFrame(allocator: std.mem.Allocator, columns: u32, rows: u32, color_mode: ColorMode) !Frame {
    const len = try std.math.mul(usize, columns, rows);
    errdefer {}

    const codepoints = try allocator.alloc(u21, len);
    errdefer allocator.free(codepoints);

    const color_len = if (color_mode == .none) 0 else len;
    const fg = try allocator.alloc(Rgb8, color_len);
    errdefer allocator.free(fg);

    const bg = try allocator.alloc(Rgb8, color_len);
    errdefer allocator.free(bg);

    return .{
        .columns = columns,
        .rows = rows,
        .color = color_mode,
        .codepoints = codepoints,
        .fg = fg,
        .bg = bg,
    };
}

/// Build an integral-luma table for the monochrome hot path when it is worth it.
/// Only monochrome modes can use it (color needs per-subcell linear RGB), and
/// only when `shouldUseIntegral` says the build cost will be amortized.
fn maybeBuildIntegral(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !?sample.IntegralLuma {
    if (context.luma_sat != null) return null;
    if (!sample.useIntegral(options.sample_strategy, image, terminal.color)) return null;
    return try sample.IntegralLuma.build(allocator, image, terminal.background);
}

fn resolveIntegral(
    owned: *?sample.IntegralLuma,
    context: RenderContext,
) ?*const sample.IntegralLuma {
    if (context.luma_sat) |sat| return sat;
    if (owned.*) |*sat| return sat;
    return null;
}

fn renderDensity(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !Frame {
    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);
    var plan = try sample.SamplePlan.init(allocator, image, mapping, 1, 1);
    defer plan.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options, context);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const background = rgbFromBackground(terminal.background);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            const xs = plan.xSpan(col, 0);
            const ys = plan.ySpan(row, 0);

            var lum: f32 = undefined;
            if (frame.color == .none) {
                lum = sample.regionLumaSpans(image, terminal, integral, xs, ys);
            } else {
                const s = sample.areaSampleSpans(image, terminal, xs, ys);
                lum = s.luma;
                frame.fg[idx] = s.rgb();
                frame.bg[idx] = background;
            }

            const adjusted = luma.applyAdjustments(lum, options.contrast, options.brightness, options.invert);
            frame.codepoints[idx] = rampCodepoint(options.ramp, adjusted);
        }
    }

    return frame;
}

fn renderGlyphTone(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !Frame {
    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);
    var plan = try sample.SamplePlan.init(allocator, image, mapping, 1, 1);
    defer plan.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options, context);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const atlas = glyph.defaultAtlas();
    const background = rgbFromBackground(terminal.background);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            const xs = plan.xSpan(col, 0);
            const ys = plan.ySpan(row, 0);

            var lum: f32 = undefined;
            if (frame.color == .none) {
                lum = sample.regionLumaSpans(image, terminal, integral, xs, ys);
            } else {
                const s = sample.areaSampleSpans(image, terminal, xs, ys);
                lum = s.luma;
                frame.fg[idx] = s.rgb();
                frame.bg[idx] = background;
            }

            const adjusted = luma.applyAdjustments(lum, options.contrast, options.brightness, options.invert);
            frame.codepoints[idx] = atlas.selectByTone(adjusted);
        }
    }

    return frame;
}

fn renderGlyphStructure(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !Frame {
    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);
    var plan = try sample.SamplePlan.init(allocator, image, mapping, glyph.cell_width, glyph.cell_height);
    defer plan.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options, context);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const atlas = glyph.defaultAtlas();

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            var cell = sampleGlyphStructureCell(image, terminal, integral, plan, col, row, options);
            const selected = selectStructuredGlyph(atlas, &cell.values, cell.binary_mask, cell.features, options.quality);
            frame.codepoints[idx] = selected.codepoint;

            if (frame.color != .none) {
                assignGlyphStructureColors(&frame, idx, image, terminal, plan, col, row, selected, options);
            }
        }
    }

    return frame;
}

fn renderHalfBlock(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !Frame {
    if (terminal.symbols == .ascii_only) return Error.UnsupportedRenderMode;

    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);
    var plan = try sample.SamplePlan.init(allocator, image, mapping, 1, 2);
    defer plan.deinit(allocator);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            const xs = plan.xSpan(col, 0);
            const top = sample.areaSampleSpans(image, terminal, xs, plan.ySpan(row, 0));
            const bottom = sample.areaSampleSpans(image, terminal, xs, plan.ySpan(row, 1));

            if (frame.color == .none) {
                frame.codepoints[idx] = halfBlockMonoCodepoint(top.luma, bottom.luma, options);
            } else {
                frame.codepoints[idx] = '▀';
                frame.fg[idx] = top.rgb();
                frame.bg[idx] = bottom.rgb();
            }
        }
    }

    return frame;
}

fn renderQuadrant(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !Frame {
    if (terminal.symbols == .ascii_only) return Error.UnsupportedRenderMode;

    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);
    var plan = try sample.SamplePlan.init(allocator, image, mapping, 2, 2);
    defer plan.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options, context);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            var samples: [4]sample.Sample = undefined;
            var adjusted: [4]f32 = undefined;
            var sum: f32 = 0.0;

            var sy: u32 = 0;
            while (sy < 2) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < 2) : (sx += 1) {
                    const sub_idx = sy * 2 + sx;
                    const xs = plan.xSpan(col, sx);
                    const ys = plan.ySpan(row, sy);
                    var l: f32 = undefined;
                    if (frame.color == .none) {
                        l = sample.regionLumaSpans(image, terminal, integral, xs, ys);
                    } else {
                        samples[sub_idx] = sample.areaSampleSpans(image, terminal, xs, ys);
                        l = samples[sub_idx].luma;
                    }
                    adjusted[sub_idx] = luma.applyAdjustments(l, options.contrast, options.brightness, options.invert);
                    sum += adjusted[sub_idx];
                }
            }

            const avg = sum / 4.0;
            var mask: u4 = 0;
            for (adjusted, 0..) |value, sub_idx| {
                const sub_x: u32 = @intCast(sub_idx % 2);
                const sub_y: u32 = @intCast(sub_idx / 2);
                if (value >= thresholdFor(options, col * 2 + sub_x, row * 2 + sub_y, avg)) {
                    mask |= @as(u4, 1) << @intCast(sub_idx);
                }
            }

            frame.codepoints[idx] = symbol.quadrantCodepoint(mask);
            if (frame.color != .none) {
                assignPartitionColors(&frame, idx, &samples, mask, options.color_stat);
            }
        }
    }

    return frame;
}

fn renderBraille(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !Frame {
    if (terminal.symbols == .ascii_only or terminal.symbols == .block_basic or terminal.symbols == .block_legacy) {
        return Error.UnsupportedRenderMode;
    }

    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);
    var plan = try sample.SamplePlan.init(allocator, image, mapping, 2, 4);
    defer plan.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options, context);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const background = rgbFromBackground(terminal.background);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            var mask: u8 = 0;
            var on_buf: [8]color.LinearRgb = undefined;
            var on_count: usize = 0;

            var sy: u32 = 0;
            while (sy < 4) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < 2) : (sx += 1) {
                    const xs = plan.xSpan(col, sx);
                    const ys = plan.ySpan(row, sy);
                    const dither_threshold = dither.threshold(options.dither, col * 2 + sx, row * 4 + sy);
                    if (frame.color == .none) {
                        const l = sample.regionLumaSpans(image, terminal, integral, xs, ys);
                        if (luma.applyAdjustments(l, options.contrast, options.brightness, options.invert) >= dither_threshold) {
                            mask |= symbol.brailleDotMask(sx, sy);
                        }
                    } else {
                        const s = sample.areaSampleSpans(image, terminal, xs, ys);
                        if (luma.applyAdjustments(s.luma, options.contrast, options.brightness, options.invert) >= dither_threshold) {
                            mask |= symbol.brailleDotMask(sx, sy);
                            on_buf[on_count] = s.linear;
                            on_count += 1;
                        }
                    }
                }
            }

            frame.codepoints[idx] = symbol.brailleCodepoint(mask);
            if (frame.color != .none) {
                if (on_count > 0) {
                    frame.fg[idx] = color.encodeSrgb(color.representative(on_buf[0..on_count], options.color_stat));
                } else {
                    frame.fg[idx] = background;
                }
                frame.bg[idx] = background;
            }
        }
    }

    return frame;
}

fn rampCodepoint(ramp: []const u8, value: f32) u21 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    const last = ramp.len - 1;
    const idx: usize = @intFromFloat(@round(clamped * @as(f32, @floatFromInt(last))));
    return ramp[idx];
}

fn halfBlockMonoCodepoint(top_luma: f32, bottom_luma: f32, options: Options) u21 {
    const top_on = luma.applyAdjustments(top_luma, options.contrast, options.brightness, options.invert) >= 0.5;
    const bottom_on = luma.applyAdjustments(bottom_luma, options.contrast, options.brightness, options.invert) >= 0.5;
    if (top_on and bottom_on) return '█';
    if (top_on) return '▀';
    if (bottom_on) return '▄';
    return ' ';
}

fn thresholdFor(options: Options, x: u32, y: u32, avg: f32) f32 {
    return switch (options.dither) {
        .none, .floyd_steinberg => avg,
        .ordered_2x2, .ordered_4x4 => dither.threshold(options.dither, x, y),
    };
}

const GlyphCell = struct {
    values: [glyph.cell_bits]f32,
    binary_mask: ?u128,
    features: StructureFeatures,
};

const StructureFeatures = struct {
    coverage: f32,
    min: f32,
    max: f32,
    centroid_x: f32,
    centroid_y: f32,
    spread_x: f32,
    spread_y: f32,
    orientation: u8,
};

fn sampleGlyphStructureCell(
    image: ImageView,
    terminal: TerminalProfile,
    integral: ?*const sample.IntegralLuma,
    plan: sample.SamplePlan,
    col: u32,
    row: u32,
    options: Options,
) GlyphCell {
    var values: [glyph.cell_bits]f32 = undefined;
    var sum: f32 = 0.0;

    var sy: u32 = 0;
    while (sy < glyph.cell_height) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < glyph.cell_width) : (sx += 1) {
            const i = @as(usize, sy) * glyph.cell_width + sx;
            const raw = sample.regionLumaSpans(image, terminal, integral, plan.xSpan(col, sx), plan.ySpan(row, sy));
            const adjusted = luma.applyAdjustments(raw, options.contrast, options.brightness, options.invert);
            values[i] = adjusted;
            sum += adjusted;
        }
    }

    const features = structureFeatures(&values, sum);
    return .{
        .values = values,
        .binary_mask = if (features.max - features.min >= 0.75) packBinaryMask(&values, (features.min + features.max) / 2.0) else null,
        .features = features,
    };
}

fn packBinaryMask(values: *const [glyph.cell_bits]f32, threshold: f32) u128 {
    var mask: u128 = 0;
    for (values, 0..) |v, i| {
        if (v >= threshold) {
            mask |= @as(u128, 1) << @intCast(i);
        }
    }
    return mask;
}

fn structureFeatures(values: *const [glyph.cell_bits]f32, sum: f32) StructureFeatures {
    const cw = @as(f32, @floatFromInt(glyph.cell_width));
    const ch = @as(f32, @floatFromInt(glyph.cell_height));
    const coverage = sum / @as(f32, @floatFromInt(glyph.cell_bits));
    var min_value: f32 = 1.0;
    var max_value: f32 = 0.0;
    for (values) |v| {
        min_value = @min(min_value, v);
        max_value = @max(max_value, v);
    }

    var cx: f32 = 0.5;
    var cy: f32 = 0.5;
    if (sum > 0.0) {
        var sx_sum: f32 = 0.0;
        var sy_sum: f32 = 0.0;
        var y: u32 = 0;
        while (y < glyph.cell_height) : (y += 1) {
            var x: u32 = 0;
            while (x < glyph.cell_width) : (x += 1) {
                const v = values[@as(usize, y) * glyph.cell_width + x];
                sx_sum += v * @as(f32, @floatFromInt(x));
                sy_sum += v * @as(f32, @floatFromInt(y));
            }
        }
        cx = (sx_sum / sum) / @max(1.0, cw - 1.0);
        cy = (sy_sum / sum) / @max(1.0, ch - 1.0);
    }

    var spread_x: f32 = 0.0;
    var spread_y: f32 = 0.0;
    if (sum > 0.0) {
        const mx = cx * @max(1.0, cw - 1.0);
        const my = cy * @max(1.0, ch - 1.0);
        var y: u32 = 0;
        while (y < glyph.cell_height) : (y += 1) {
            var x: u32 = 0;
            while (x < glyph.cell_width) : (x += 1) {
                const v = values[@as(usize, y) * glyph.cell_width + x];
                const dx = @as(f32, @floatFromInt(x)) - mx;
                const dy = @as(f32, @floatFromInt(y)) - my;
                spread_x += v * dx * dx;
                spread_y += v * dy * dy;
            }
        }
        spread_x = @sqrt(spread_x / sum) / cw;
        spread_y = @sqrt(spread_y / sum) / ch;
    }

    return .{
        .coverage = coverage,
        .min = min_value,
        .max = max_value,
        .centroid_x = cx,
        .centroid_y = cy,
        .spread_x = spread_x,
        .spread_y = spread_y,
        .orientation = sourceOrientation(values),
    };
}

fn sourceOrientation(values: *const [glyph.cell_bits]f32) u8 {
    var bins = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    var y: u32 = 1;
    while (y < glyph.cell_height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < glyph.cell_width - 1) : (x += 1) {
            const gx = values[@as(usize, y) * glyph.cell_width + x + 1] -
                values[@as(usize, y) * glyph.cell_width + x - 1];
            const gy = values[@as(usize, y + 1) * glyph.cell_width + x] -
                values[@as(usize, y - 1) * glyph.cell_width + x];
            const mag = @sqrt(gx * gx + gy * gy);
            if (mag < 0.001) continue;
            var angle = std.math.atan2(gy, gx);
            if (angle < 0.0) angle += std.math.pi;
            const bin: usize = @min(3, @as(usize, @intFromFloat((angle / std.math.pi) * 4.0)));
            bins[bin] += mag;
        }
    }
    var best: usize = 0;
    for (bins, 0..) |v, i| {
        if (v > bins[best]) best = i;
    }
    return @intCast(best);
}

fn selectStructuredGlyph(
    atlas: glyph.Atlas,
    values: *const [glyph.cell_bits]f32,
    binary_mask: ?u128,
    features: StructureFeatures,
    quality: Quality,
) glyph.Glyph {
    if (features.max - features.min < 0.15) {
        return atlas.glyphFor(atlas.selectByTone(features.coverage)).?;
    }

    var best = atlas.glyphs[0];
    var best_score = std.math.inf(f32);
    const target_coverage = @min(features.coverage, atlas.max_coverage);
    const window = coverageWindow(quality, target_coverage);
    var used_prefilter = false;

    for (atlas.glyphs, 0..) |candidate, candidate_index| {
        const coverage_delta = absFloat(candidate.coverage - target_coverage);
        if (coverage_delta > window) continue;
        used_prefilter = true;
        const score = structuredGlyphScore(atlas, values, binary_mask, features, target_coverage, candidate, candidate_index, quality);
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
    }

    if (used_prefilter) return best;

    for (atlas.glyphs, 0..) |candidate, candidate_index| {
        const score = structuredGlyphScore(atlas, values, binary_mask, features, target_coverage, candidate, candidate_index, quality);
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
    }
    return best;
}

fn coverageWindow(quality: Quality, coverage_value: f32) f32 {
    const base: f32 = switch (quality) {
        .preview => 0.025,
        .balanced => 0.045,
        .high => 0.065,
    };
    return base + coverage_value * 0.05;
}

fn structuredGlyphScore(
    atlas: glyph.Atlas,
    values: *const [glyph.cell_bits]f32,
    binary_mask: ?u128,
    features: StructureFeatures,
    target_coverage: f32,
    candidate: glyph.Glyph,
    candidate_index: usize,
    quality: Quality,
) f32 {
    const shape = if (binary_mask) |mask|
        maskDistanceBinary(atlas, mask, candidate, candidate_index, quality)
    else
        maskDistance(atlas, values, candidate, quality);
    const coverage_penalty = absFloat(candidate.coverage - target_coverage) * 0.75;
    const centroid_penalty = (absFloat(candidate.centroid_x - features.centroid_x) +
        absFloat(candidate.centroid_y - features.centroid_y)) * 0.035;
    const spread_penalty = (absFloat(candidate.spread_x - features.spread_x) +
        absFloat(candidate.spread_y - features.spread_y)) * 0.025;
    const orientation_penalty = @as(f32, @floatFromInt(orientationDistance(candidate.dominant_orientation, features.orientation))) * 0.01;
    return shape + coverage_penalty + centroid_penalty + spread_penalty + orientation_penalty;
}

fn maskDistanceBinary(
    atlas: glyph.Atlas,
    source_mask: u128,
    candidate: glyph.Glyph,
    candidate_index: usize,
    quality: Quality,
) f32 {
    const radius: i32 = switch (quality) {
        .preview => 0,
        .balanced, .high => 1,
    };

    var best: u8 = @intCast(glyph.cell_bits);
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            const shifted = atlas.shiftedMask(candidate_index, candidate, dx, dy);
            const mismatch: u8 = @intCast(@popCount(source_mask ^ shifted));
            if (mismatch < best) best = mismatch;
        }
    }

    return @as(f32, @floatFromInt(best)) / @as(f32, @floatFromInt(glyph.cell_bits));
}

fn maskDistance(
    atlas: glyph.Atlas,
    values: *const [glyph.cell_bits]f32,
    candidate: glyph.Glyph,
    quality: Quality,
) f32 {
    const radius: i32 = switch (quality) {
        .preview => 0,
        .balanced, .high => 1,
    };

    var best = std.math.inf(f32);
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            const dist = maskDistanceAtOffset(atlas, values, candidate, dx, dy);
            if (dist < best) best = dist;
        }
    }
    return best;
}

fn maskDistanceAtOffset(
    atlas: glyph.Atlas,
    values: *const [glyph.cell_bits]f32,
    candidate: glyph.Glyph,
    dx: i32,
    dy: i32,
) f32 {
    var sum: f32 = 0.0;
    var y: u32 = 0;
    while (y < glyph.cell_height) : (y += 1) {
        var x: u32 = 0;
        while (x < glyph.cell_width) : (x += 1) {
            const sx = @as(i32, @intCast(x)) - dx;
            const sy = @as(i32, @intCast(y)) - dy;
            const on = if (sx >= 0 and sx < glyph.cell_width and sy >= 0 and sy < glyph.cell_height)
                atlas.maskBit(candidate, @intCast(sx), @intCast(sy))
            else
                false;
            const predicted: f32 = if (on) 1.0 else 0.0;
            const actual = values[@as(usize, y) * glyph.cell_width + x];
            const diff = predicted - actual;
            sum += diff * diff;
        }
    }
    return sum / @as(f32, @floatFromInt(glyph.cell_bits));
}

fn assignGlyphStructureColors(
    frame: *Frame,
    idx: usize,
    image: ImageView,
    terminal: TerminalProfile,
    plan: sample.SamplePlan,
    col: u32,
    row: u32,
    selected: glyph.Glyph,
    options: Options,
) void {
    const atlas = glyph.defaultAtlas();
    var fg_buf: [glyph.cell_bits]color.LinearRgb = undefined;
    var bg_buf: [glyph.cell_bits]color.LinearRgb = undefined;
    var fg_count: usize = 0;
    var bg_count: usize = 0;

    var sy: u32 = 0;
    while (sy < glyph.cell_height) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < glyph.cell_width) : (sx += 1) {
            const s = sample.areaSampleSpans(image, terminal, plan.xSpan(col, sx), plan.ySpan(row, sy));
            if (atlas.maskBit(selected, sx, sy)) {
                fg_buf[fg_count] = s.linear;
                fg_count += 1;
            } else {
                bg_buf[bg_count] = s.linear;
                bg_count += 1;
            }
        }
    }

    if (fg_count == 0) {
        const region = sample.cellRegion(plan.mapping, col, row, 1, 1, 0, 0);
        frame.fg[idx] = sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]).rgb();
    } else {
        frame.fg[idx] = color.encodeSrgb(color.representative(fg_buf[0..fg_count], options.color_stat));
    }

    if (bg_count == 0) {
        frame.bg[idx] = frame.fg[idx];
    } else {
        frame.bg[idx] = color.encodeSrgb(color.representative(bg_buf[0..bg_count], options.color_stat));
    }
}

fn orientationDistance(a: u8, b: u8) u8 {
    const raw = if (a > b) a - b else b - a;
    return @min(raw, 4 - raw);
}

fn absFloat(v: f32) f32 {
    return if (v < 0.0) -v else v;
}

fn assignPartitionColors(frame: *Frame, idx: usize, samples: *const [4]sample.Sample, mask: u4, stat: ColorStat) void {
    var fg_buf: [4]color.LinearRgb = undefined;
    var bg_buf: [4]color.LinearRgb = undefined;
    var fg_count: usize = 0;
    var bg_count: usize = 0;

    for (samples, 0..) |s, sample_idx| {
        if ((mask & (@as(u4, 1) << @intCast(sample_idx))) != 0) {
            fg_buf[fg_count] = s.linear;
            fg_count += 1;
        } else {
            bg_buf[bg_count] = s.linear;
            bg_count += 1;
        }
    }

    if (fg_count == 0) {
        frame.fg[idx] = samples[0].rgb();
    } else {
        frame.fg[idx] = color.encodeSrgb(color.representative(fg_buf[0..fg_count], stat));
    }

    if (bg_count == 0) {
        frame.bg[idx] = frame.fg[idx];
    } else {
        frame.bg[idx] = color.encodeSrgb(color.representative(bg_buf[0..bg_count], stat));
    }
}

fn rgbFromBackground(background: Rgba8) Rgb8 {
    return .{ .r = background.r, .g = background.g, .b = background.b };
}

fn eqlRgba(a: Rgba8, b: Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "validates image dimensions" {
    const pixels = [_]Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }};

    try validateImage(.{
        .width = 1,
        .height = 1,
        .stride = @sizeOf(Rgba8),
        .pixels = &pixels,
    });

    try std.testing.expectError(ValidationError.EmptyImage, validateImage(.{
        .width = 0,
        .height = 1,
        .stride = @sizeOf(Rgba8),
        .pixels = &pixels,
    }));
}

test "validates stride and pixel buffer length" {
    const pixels = [_]Rgba8{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    try std.testing.expectError(ValidationError.InvalidStride, validateImage(.{
        .width = 2,
        .height = 1,
        .stride = @sizeOf(Rgba8),
        .pixels = &pixels,
    }));

    try std.testing.expectError(ValidationError.InvalidStride, validateImage(.{
        .width = 1,
        .height = 1,
        .stride = @sizeOf(Rgba8) + 1,
        .pixels = &pixels,
    }));

    try std.testing.expectError(ValidationError.InvalidPixelBuffer, validateImage(.{
        .width = 2,
        .height = 2,
        .stride = 2 * @sizeOf(Rgba8),
        .pixels = &pixels,
    }));
}

test "validates terminal dimensions and aspect" {
    try validateTerminal(.{ .columns = 80, .rows = 24 });

    try std.testing.expectError(ValidationError.EmptyTerminal, validateTerminal(.{
        .columns = 0,
        .rows = 24,
    }));

    try std.testing.expectError(ValidationError.InvalidCellAspect, validateTerminal(.{
        .columns = 80,
        .rows = 24,
        .cell_aspect = 0.0,
    }));
}

test "validates density ramp" {
    try validateOptions(.{});
    try std.testing.expectError(ValidationError.EmptyRamp, validateOptions(.{ .ramp = "" }));
    try std.testing.expectError(ValidationError.InvalidRampCodepoint, validateOptions(.{ .ramp = "\x1b" }));
}

test "frame deinit frees all buffers" {
    const allocator = std.testing.allocator;
    var frame = Frame{
        .columns = 1,
        .rows = 1,
        .color = .truecolor,
        .codepoints = try allocator.alloc(u21, 1),
        .fg = try allocator.alloc(Rgb8, 1),
        .bg = try allocator.alloc(Rgb8, 1),
    };

    frame.deinit(allocator);
}

test "density renderer produces fitted frame" {
    const allocator = std.testing.allocator;
    const pixels = [_]Rgba8{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };

    var frame = try renderToCells(
        allocator,
        .{ .width = 2, .height = 1, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 2, .rows = 1, .color = .none },
        .{ .mode = .density, .fit = .stretch, .ramp = " @" },
    );
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), frame.columns);
    try std.testing.expectEqual(@as(u32, 1), frame.rows);
    try std.testing.expectEqual(@as(u21, ' '), frame.codepoints[0]);
    try std.testing.expectEqual(@as(u21, '@'), frame.codepoints[1]);
    try std.testing.expectEqual(@as(usize, 0), frame.fg.len);
}

test "truecolor half-block maps top to fg and bottom to bg" {
    const allocator = std.testing.allocator;
    const pixels = [_]Rgba8{
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 255, .a = 255 },
    };

    var frame = try renderToCells(
        allocator,
        .{ .width = 1, .height = 2, .stride = @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .truecolor },
        .{ .mode = .partition, .partition = .half_1x2, .fit = .stretch },
    );
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u21, '▀'), frame.codepoints[0]);
    try std.testing.expect(frame.fg[0].r > 250);
    try std.testing.expect(frame.bg[0].b > 250);
}

test "writer emits plain density text" {
    const allocator = std.testing.allocator;
    const pixels = [_]Rgba8{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try renderToWriter(
        &writer,
        allocator,
        .{ .width = 2, .height = 1, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 2, .rows = 1, .color = .none },
        .{ .mode = .density, .fit = .stretch, .ramp = " @" },
    );

    try std.testing.expectEqualStrings(" @\n", writer.buffered());
}

test "writer emits truecolor SGR and reset" {
    const allocator = std.testing.allocator;
    const pixels = [_]Rgba8{
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 255, .a = 255 },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try renderToWriter(
        &writer,
        allocator,
        .{ .width = 1, .height = 2, .stride = @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .truecolor },
        .{ .mode = .partition, .partition = .half_1x2, .fit = .stretch },
    );

    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;255;0;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[48;2;0;0;255m") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[0m\n"));
}

test "quadrant renderer maps diagonal fixture to quadrant glyph" {
    const allocator = std.testing.allocator;
    const pixels = [_]Rgba8{
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };

    var frame = try renderToCells(
        allocator,
        .{ .width = 2, .height = 2, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .none },
        .{ .mode = .partition, .partition = .quadrant_2x2, .fit = .stretch },
    );
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u21, '▚'), frame.codepoints[0]);
}

test "braille renderer maps vertical dots to Unicode layout" {
    const allocator = std.testing.allocator;
    const pixels = [_]Rgba8{
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    var frame = try renderToCells(
        allocator,
        .{ .width = 2, .height = 4, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .none, .symbols = .braille },
        .{ .mode = .braille, .fit = .stretch },
    );
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u21, 0x2847), frame.codepoints[0]);
}

test "ordered dithering changes low quadrant fixture deterministically" {
    const allocator = std.testing.allocator;
    const pixels = [_]Rgba8{
        .{ .r = 80, .g = 80, .b = 80, .a = 255 },
        .{ .r = 80, .g = 80, .b = 80, .a = 255 },
        .{ .r = 80, .g = 80, .b = 80, .a = 255 },
        .{ .r = 80, .g = 80, .b = 80, .a = 255 },
    };

    var frame = try renderToCells(
        allocator,
        .{ .width = 2, .height = 2, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .none },
        .{ .mode = .partition, .partition = .quadrant_2x2, .fit = .stretch, .dither = .ordered_2x2 },
    );
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u21, '▘'), frame.codepoints[0]);
}

test "unsupported color modes are rejected explicitly" {
    const pixels = [_]Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }};

    try std.testing.expectError(Error.UnsupportedColorMode, renderToCells(
        std.testing.allocator,
        .{ .width = 1, .height = 1, .stride = @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .ansi256 },
        .{ .mode = .density, .fit = .stretch },
    ));
}

test "quadrant renderer is rejected for ascii-only terminals" {
    const pixels = [_]Rgba8{
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };

    try std.testing.expectError(Error.UnsupportedRenderMode, renderToCells(
        std.testing.allocator,
        .{ .width = 2, .height = 2, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .none, .symbols = .ascii_only },
        .{ .mode = .partition, .partition = .quadrant_2x2, .fit = .stretch },
    ));
}

test "glyph-tone maps tone extremes to space and the densest glyph" {
    const allocator = std.testing.allocator;
    const black = [_]Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }};
    const white = [_]Rgba8{.{ .r = 255, .g = 255, .b = 255, .a = 255 }};

    var dark = try renderToCells(
        allocator,
        .{ .width = 1, .height = 1, .stride = @sizeOf(Rgba8), .pixels = &black },
        .{ .columns = 1, .rows = 1, .color = .none },
        .{ .mode = .glyph_tone, .fit = .stretch },
    );
    defer dark.deinit(allocator);
    try std.testing.expectEqual(@as(u21, ' '), dark.codepoints[0]);

    var light = try renderToCells(
        allocator,
        .{ .width = 1, .height = 1, .stride = @sizeOf(Rgba8), .pixels = &white },
        .{ .columns = 1, .rows = 1, .color = .none },
        .{ .mode = .glyph_tone, .fit = .stretch },
    );
    defer light.deinit(allocator);
    // The brightest tone selects a high-coverage glyph (not a space or a dot).
    try std.testing.expect(light.codepoints[0] != ' ');
    try std.testing.expect(glyph.defaultCoverage(light.codepoints[0]).? > 0.2);
}

test "glyph-structure recovers a calibrated slash mask" {
    const allocator = std.testing.allocator;
    const atlas = glyph.defaultAtlas();
    const slash = atlas.glyphFor('/').?;

    var pixels: [glyph.cell_bits]Rgba8 = undefined;
    var y: u32 = 0;
    while (y < glyph.cell_height) : (y += 1) {
        var x: u32 = 0;
        while (x < glyph.cell_width) : (x += 1) {
            pixels[@as(usize, y) * glyph.cell_width + x] = if (atlas.maskBit(slash, x, y))
                .{ .r = 255, .g = 255, .b = 255, .a = 255 }
            else
                .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        }
    }

    var frame = try renderToCells(
        allocator,
        .{
            .width = glyph.cell_width,
            .height = glyph.cell_height,
            .stride = glyph.cell_width * @sizeOf(Rgba8),
            .pixels = &pixels,
        },
        .{ .columns = 1, .rows = 1, .color = .none },
        .{ .mode = .glyph_structure, .fit = .stretch, .quality = .high },
    );
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u21, '/'), frame.codepoints[0]);
}

test "integral_luma sampling matches direct_box for monochrome modes" {
    const allocator = std.testing.allocator;

    // A non-trivial gradient-ish image so cells average several pixels.
    var pixels: [8 * 8]Rgba8 = undefined;
    for (&pixels, 0..) |*p, i| {
        const x: u8 = @intCast(i % 8);
        const y: u8 = @intCast(i / 8);
        p.* = .{ .r = x * 30, .g = y * 30, .b = @intCast((@as(u32, x) * y) % 256), .a = 255 };
    }
    const image = ImageView{ .width = 8, .height = 8, .stride = 8 * @sizeOf(Rgba8), .pixels = &pixels };
    const terminal = TerminalProfile{ .columns = 3, .rows = 3, .color = .none };

    const modes = [_]Options{
        .{ .mode = .density, .fit = .stretch },
        .{ .mode = .partition, .partition = .quadrant_2x2, .fit = .stretch },
        .{ .mode = .braille, .fit = .stretch },
        .{ .mode = .glyph_structure, .fit = .stretch },
    };
    const braille_terminal = TerminalProfile{ .columns = 3, .rows = 3, .color = .none, .symbols = .braille };

    for (modes) |base| {
        const term = if (base.mode == .braille) braille_terminal else terminal;

        var direct = try renderToCells(allocator, image, term, .{
            .mode = base.mode,
            .partition = base.partition,
            .fit = base.fit,
            .sample_strategy = .direct_box,
        });
        defer direct.deinit(allocator);

        var integral = try renderToCells(allocator, image, term, .{
            .mode = base.mode,
            .partition = base.partition,
            .fit = base.fit,
            .sample_strategy = .integral_luma,
        });
        defer integral.deinit(allocator);

        try std.testing.expectEqualSlices(u21, direct.codepoints, integral.codepoints);
    }
}

test "prepared integral_luma render matches direct render" {
    const allocator = std.testing.allocator;

    var pixels: [6 * 6]Rgba8 = undefined;
    for (&pixels, 0..) |*p, i| {
        const x: u8 = @intCast(i % 6);
        const y: u8 = @intCast(i / 6);
        p.* = .{ .r = x * 35, .g = y * 35, .b = 90, .a = 255 };
    }
    const image = ImageView{ .width = 6, .height = 6, .stride = 6 * @sizeOf(Rgba8), .pixels = &pixels };
    const terminal = TerminalProfile{ .columns = 3, .rows = 2, .color = .none };
    const options = Options{ .mode = .density, .fit = .stretch, .sample_strategy = .integral_luma };

    var prepared = try prepareImage(allocator, image, terminal, .{ .sample_strategy = .integral_luma });
    defer prepared.deinit(allocator);
    try std.testing.expect(prepared.luma_sat != null);

    var direct = try renderToCells(allocator, image, terminal, options);
    defer direct.deinit(allocator);

    var reused = try renderPreparedToCells(allocator, &prepared, terminal, options);
    defer reused.deinit(allocator);

    try std.testing.expectEqualSlices(u21, direct.codepoints, reused.codepoints);
}

test "braille renderer requires braille symbol capability" {
    const pixels = [_]Rgba8{
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    try std.testing.expectError(Error.UnsupportedRenderMode, renderToCells(
        std.testing.allocator,
        .{ .width = 2, .height = 4, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .none, .symbols = .block_basic },
        .{ .mode = .braille, .fit = .stretch },
    ));
}
