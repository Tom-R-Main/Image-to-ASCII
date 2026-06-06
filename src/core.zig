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
pub const SamplerPolicy = sample.SamplerPolicy;
pub const SampleStrategy = sample.SampleStrategy;
pub const AnsiDiffMode = ansi.DiffMode;
pub const AnsiDiffOptions = ansi.DiffOptions;
pub const AnsiDiffStats = ansi.DiffStats;

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

pub const AnsiDiffError = ansi.DiffError;

pub const Error = RenderError || AnsiDiffError;

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

pub fn resolveSamplerPolicy(
    options: Options,
    terminal: TerminalProfile,
    prepared_integral_available: bool,
) SamplerPolicy {
    if (terminal.color == .none and options.sample_strategy == .integral_luma and supportsIntegralLuma(options.mode, options.partition)) {
        return if (prepared_integral_available) .prepared_integral_luma else .integral_luma;
    }
    if (options.sample_strategy == .direct_box or options.sample_strategy == .integral_luma) return .direct_box;
    return if (shouldUseSpanPrecompute(options.mode, options.partition, terminal.color))
        .span_precompute
    else
        .direct_box;
}

pub const Frame = struct {
    columns: u32,
    rows: u32,
    color: ColorMode,
    codepoints: []u21,
    fg: []Rgb8,
    bg: []Rgb8,

    pub const empty = Frame{
        .columns = 0,
        .rows = 0,
        .color = .none,
        .codepoints = @constCast(&[_]u21{}),
        .fg = @constCast(&[_]Rgb8{}),
        .bg = @constCast(&[_]Rgb8{}),
    };

    pub fn ensureCapacity(self: *Frame, allocator: std.mem.Allocator, columns: u32, rows: u32, color_mode: ColorMode) !void {
        const len = try std.math.mul(usize, columns, rows);
        const color_len = if (color_mode == .none) 0 else len;

        if (self.codepoints.len != len) {
            self.codepoints = try allocator.realloc(self.codepoints, len);
        }

        if (self.fg.len != color_len) {
            self.fg = try allocator.realloc(self.fg, color_len);
        }

        if (self.bg.len != color_len) {
            self.bg = try allocator.realloc(self.bg, color_len);
        }

        self.columns = columns;
        self.rows = rows;
        self.color = color_mode;
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.codepoints);
        allocator.free(self.fg);
        allocator.free(self.bg);
        self.* = .empty;
    }
};

/// A rectangular region of a `Frame`, in cells. Used to render or crop a bounded
/// pane out of a larger (naturally-sized) frame. The region may extend past the
/// frame; cells outside the frame are treated as blank padding.
pub const FrameViewport = struct {
    x: u32 = 0,
    y: u32 = 0,
    columns: u32,
    rows: u32,
};

pub const RenderWorkspace = struct {
    frame: Frame = .empty,
    sample_plan: SamplePlan = .empty,

    pub const empty = RenderWorkspace{};

    pub fn deinit(self: *RenderWorkspace, allocator: std.mem.Allocator) void {
        self.frame.deinit(allocator);
        self.sample_plan.deinit(allocator);
        self.* = .empty;
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
    var workspace: RenderWorkspace = .empty;
    errdefer workspace.deinit(allocator);

    try renderIntoWorkspace(&workspace, allocator, image, terminal, options);

    const frame = workspace.frame;
    workspace.frame = .empty;
    workspace.sample_plan.deinit(allocator);
    return frame;
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
    var workspace: RenderWorkspace = .empty;
    errdefer workspace.deinit(allocator);

    try renderPreparedIntoWorkspace(&workspace, allocator, prepared, terminal, options);

    const frame = workspace.frame;
    workspace.frame = .empty;
    workspace.sample_plan.deinit(allocator);
    return frame;
}

pub fn renderIntoWorkspace(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !void {
    try validateInputs(image, terminal, options);
    try validateSupportedColor(terminal.color);

    try renderIntoWorkspaceWithContext(workspace, allocator, image, terminal, options, .{});
}

pub fn renderPreparedIntoWorkspace(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    prepared: *const PreparedImage,
    terminal: TerminalProfile,
    options: Options,
) !void {
    try validateInputs(prepared.image, terminal, options);
    try validateSupportedColor(terminal.color);

    try renderIntoWorkspaceWithContext(workspace, allocator, prepared.image, terminal, options, .{
        .luma_sat = prepared.integralFor(terminal, options),
    });
}

fn renderIntoWorkspaceWithContext(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !void {
    return switch (options.mode) {
        .density => renderDensity(workspace, allocator, image, terminal, options, context),
        .partition => switch (options.partition) {
            .density_1x1 => renderDensity(workspace, allocator, image, terminal, options, context),
            .half_1x2 => renderHalfBlock(workspace, allocator, image, terminal, options),
            .quadrant_2x2 => renderQuadrant(workspace, allocator, image, terminal, options, context),
            .sextant_2x3 => renderSubcell(workspace, allocator, image, terminal, options, context, 3, sextantGlyph),
            .octant_2x4 => renderSubcell(workspace, allocator, image, terminal, options, context, 4, octantGlyph),
        },
        .braille => renderBraille(workspace, allocator, image, terminal, options, context),
        .glyph_tone => renderGlyphTone(workspace, allocator, image, terminal, options, context),
        .glyph_structure => renderGlyphStructure(workspace, allocator, image, terminal, options, context),
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

pub fn renderFrameDiffToWriter(
    writer: *std.Io.Writer,
    previous: ?*const Frame,
    current: *const Frame,
    options: AnsiDiffOptions,
) !AnsiDiffStats {
    return ansi.writeFrameDiff(writer, previous, current, options);
}

fn validateSupportedColor(color_mode: ColorMode) RenderError!void {
    // All modes are supported; ansi16/ansi256 are quantized from truecolor at
    // emit time (see ansi.zig) so the renderer path is identical.
    switch (color_mode) {
        .none, .truecolor, .ansi16, .ansi256 => {},
    }
}

/// The RGB a cell color displays as under `mode`: identity for none/truecolor,
/// the nearest palette entry for ansi256/ansi16. Used by presentation layers
/// (glyphshot, the reconstruction harness) to preview/score quantized output;
/// the ANSI writer emits the corresponding palette index directly.
pub fn displayColor(c: Rgb8, mode: ColorMode) Rgb8 {
    return switch (mode) {
        .none, .truecolor => c,
        .ansi256 => color.ansi256Rgb(color.ansi256Index(c)),
        .ansi16 => color.ansi16Rgb(color.ansi16Index(c)),
    };
}

/// Build an integral-luma table for the monochrome hot path when it is worth it.
/// Only monochrome modes can use it (color needs per-subcell linear RGB), and
/// only when `shouldUseIntegral` says the build cost will be amortized.
fn maybeBuildIntegral(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    policy: SamplerPolicy,
) !?sample.IntegralLuma {
    if (policy != .integral_luma) return null;
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

fn renderSamplerPolicy(options: Options, terminal: TerminalProfile, context: RenderContext) SamplerPolicy {
    return resolveSamplerPolicy(options, terminal, context.luma_sat != null);
}

fn shouldUseSpanPrecompute(mode: RenderMode, partition: PartitionKind, color_mode: ColorMode) bool {
    return switch (mode) {
        .density, .glyph_tone, .glyph_structure => true,
        .braille => color_mode != .none,
        .partition => switch (partition) {
            .density_1x1 => true,
            .quadrant_2x2 => color_mode == .none,
            .half_1x2, .sextant_2x3, .octant_2x4 => false,
        },
    };
}

fn supportsIntegralLuma(mode: RenderMode, partition: PartitionKind) bool {
    return switch (mode) {
        .density, .glyph_tone, .glyph_structure, .braille => true,
        .partition => switch (partition) {
            .density_1x1, .quadrant_2x2 => true,
            .half_1x2, .sextant_2x3, .octant_2x4 => false,
        },
    };
}

fn ensureWorkspaceSamplePlan(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    mapping: sample.Mapping,
    subcells_x: u32,
    subcells_y: u32,
    policy: SamplerPolicy,
) !void {
    if (policy != .span_precompute) return;
    try workspace.sample_plan.ensure(allocator, image, mapping, subcells_x, subcells_y);
}

fn workspaceSamplePlanPtr(workspace: *const RenderWorkspace, policy: SamplerPolicy) ?*const sample.SamplePlan {
    return if (policy == .span_precompute) &workspace.sample_plan else null;
}

inline fn sampleCell(
    image: ImageView,
    terminal: TerminalProfile,
    mapping: sample.Mapping,
    plan: ?*const sample.SamplePlan,
    col: u32,
    row: u32,
    subcells_x: u32,
    subcells_y: u32,
    sub_x: u32,
    sub_y: u32,
) sample.Sample {
    if (plan) |p| {
        return sample.areaSampleSpans(image, terminal, p.xSpan(col, sub_x), p.ySpan(row, sub_y));
    }
    const region = sample.cellRegion(mapping, col, row, subcells_x, subcells_y, sub_x, sub_y);
    return sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]);
}

inline fn sampleCellLuma(
    image: ImageView,
    terminal: TerminalProfile,
    integral: ?*const sample.IntegralLuma,
    mapping: sample.Mapping,
    plan: ?*const sample.SamplePlan,
    col: u32,
    row: u32,
    subcells_x: u32,
    subcells_y: u32,
    sub_x: u32,
    sub_y: u32,
) f32 {
    if (plan) |p| {
        return sample.regionLumaSpans(image, terminal, integral, p.xSpan(col, sub_x), p.ySpan(row, sub_y));
    }
    const region = sample.cellRegion(mapping, col, row, subcells_x, subcells_y, sub_x, sub_y);
    return sample.regionLuma(image, terminal, integral, region);
}

fn renderDensity(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !void {
    const mapping = sample.fitMapping(image, terminal, options.fit);
    const frame = &workspace.frame;
    try frame.ensureCapacity(allocator, mapping.columns, mapping.rows, terminal.color);
    const policy = renderSamplerPolicy(options, terminal, context);
    try ensureWorkspaceSamplePlan(workspace, allocator, image, mapping, 1, 1, policy);
    const plan = workspaceSamplePlanPtr(workspace, policy);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, policy);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const background = rgbFromBackground(terminal.background);

    if (plan) |p| {
        var row: u32 = 0;
        while (row < mapping.rows) : (row += 1) {
            var col: u32 = 0;
            while (col < mapping.columns) : (col += 1) {
                const idx = @as(usize, row) * mapping.columns + col;
                const xs = p.xSpan(col, 0);
                const ys = p.ySpan(row, 0);

                var lum: f32 = undefined;
                if (frame.color == .none) {
                    lum = sample.areaSampleSpans(image, terminal, xs, ys).luma;
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
        return;
    }

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;

            var lum: f32 = undefined;
            if (frame.color == .none) {
                lum = sampleCellLuma(image, terminal, integral, mapping, plan, col, row, 1, 1, 0, 0);
            } else {
                const s = sampleCell(image, terminal, mapping, plan, col, row, 1, 1, 0, 0);
                lum = s.luma;
                frame.fg[idx] = s.rgb();
                frame.bg[idx] = background;
            }

            const adjusted = luma.applyAdjustments(lum, options.contrast, options.brightness, options.invert);
            frame.codepoints[idx] = rampCodepoint(options.ramp, adjusted);
        }
    }

    return;
}

fn renderGlyphTone(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !void {
    const mapping = sample.fitMapping(image, terminal, options.fit);
    const frame = &workspace.frame;
    try frame.ensureCapacity(allocator, mapping.columns, mapping.rows, terminal.color);
    const policy = renderSamplerPolicy(options, terminal, context);
    try ensureWorkspaceSamplePlan(workspace, allocator, image, mapping, 1, 1, policy);
    const plan = workspaceSamplePlanPtr(workspace, policy);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, policy);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const atlas = glyph.defaultAtlas();
    const background = rgbFromBackground(terminal.background);

    if (plan) |p| {
        var row: u32 = 0;
        while (row < mapping.rows) : (row += 1) {
            var col: u32 = 0;
            while (col < mapping.columns) : (col += 1) {
                const idx = @as(usize, row) * mapping.columns + col;
                const xs = p.xSpan(col, 0);
                const ys = p.ySpan(row, 0);

                var lum: f32 = undefined;
                if (frame.color == .none) {
                    lum = sample.areaSampleSpans(image, terminal, xs, ys).luma;
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
        return;
    }

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;

            var lum: f32 = undefined;
            if (frame.color == .none) {
                lum = sampleCellLuma(image, terminal, integral, mapping, plan, col, row, 1, 1, 0, 0);
            } else {
                const s = sampleCell(image, terminal, mapping, plan, col, row, 1, 1, 0, 0);
                lum = s.luma;
                frame.fg[idx] = s.rgb();
                frame.bg[idx] = background;
            }

            const adjusted = luma.applyAdjustments(lum, options.contrast, options.brightness, options.invert);
            frame.codepoints[idx] = atlas.selectByTone(adjusted);
        }
    }

    return;
}

fn renderGlyphStructure(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !void {
    const mapping = sample.fitMapping(image, terminal, options.fit);
    const frame = &workspace.frame;
    try frame.ensureCapacity(allocator, mapping.columns, mapping.rows, terminal.color);
    const policy = renderSamplerPolicy(options, terminal, context);
    try ensureWorkspaceSamplePlan(workspace, allocator, image, mapping, glyph.cell_width, glyph.cell_height, policy);
    const plan = workspaceSamplePlanPtr(workspace, policy);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, policy);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const atlas = glyph.defaultAtlas();

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            var cell = sampleGlyphStructureCell(image, terminal, integral, mapping, plan, col, row, options);
            const selected = selectStructuredGlyph(atlas, &cell.values, cell.binary_mask, cell.features, options.quality);
            frame.codepoints[idx] = selected.codepoint;

            if (frame.color != .none) {
                assignGlyphStructureColors(frame, idx, image, terminal, mapping, plan, col, row, selected, options);
            }
        }
    }

    return;
}

fn renderHalfBlock(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !void {
    if (terminal.symbols == .ascii_only) return Error.UnsupportedRenderMode;

    const mapping = sample.fitMapping(image, terminal, options.fit);
    const frame = &workspace.frame;
    try frame.ensureCapacity(allocator, mapping.columns, mapping.rows, terminal.color);
    const policy = renderSamplerPolicy(options, terminal, .{});
    try ensureWorkspaceSamplePlan(workspace, allocator, image, mapping, 1, 2, policy);
    const plan = workspaceSamplePlanPtr(workspace, policy);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            const top = sampleCell(image, terminal, mapping, plan, col, row, 1, 2, 0, 0);
            const bottom = sampleCell(image, terminal, mapping, plan, col, row, 1, 2, 0, 1);

            if (frame.color == .none) {
                frame.codepoints[idx] = halfBlockMonoCodepoint(top.luma, bottom.luma, options);
            } else {
                frame.codepoints[idx] = '▀';
                frame.fg[idx] = top.rgb();
                frame.bg[idx] = bottom.rgb();
            }
        }
    }

    return;
}

fn renderQuadrant(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !void {
    if (terminal.symbols == .ascii_only) return Error.UnsupportedRenderMode;

    const mapping = sample.fitMapping(image, terminal, options.fit);
    const frame = &workspace.frame;
    try frame.ensureCapacity(allocator, mapping.columns, mapping.rows, terminal.color);
    const policy = renderSamplerPolicy(options, terminal, context);
    try ensureWorkspaceSamplePlan(workspace, allocator, image, mapping, 2, 2, policy);
    const plan = workspaceSamplePlanPtr(workspace, policy);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, policy);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const fs_grid: ?[]bool = if (options.dither == .floyd_steinberg)
        try buildFsGrid(allocator, image, terminal, integral, mapping, plan, options, 2, 2)
    else
        null;
    defer if (fs_grid) |g| allocator.free(g);
    const fs_w = mapping.columns * 2;

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
                    var l: f32 = undefined;
                    if (frame.color == .none) {
                        l = sampleCellLuma(image, terminal, integral, mapping, plan, col, row, 2, 2, sx, sy);
                    } else {
                        samples[sub_idx] = sampleCell(image, terminal, mapping, plan, col, row, 2, 2, sx, sy);
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
                const on = if (fs_grid) |g|
                    g[(row * 2 + sub_y) * fs_w + (col * 2 + sub_x)]
                else
                    value >= partitionThreshold(options, col * 2 + sub_x, row * 2 + sub_y, avg, frame.color == .none);
                if (on) mask |= @as(u4, 1) << @intCast(sub_idx);
            }

            frame.codepoints[idx] = symbol.quadrantCodepoint(mask);
            if (frame.color != .none) {
                assignPartitionColors(frame, idx, &samples, mask, options.color_stat);
            }
        }
    }

    return;
}

fn sextantGlyph(mask: u8) u21 {
    return symbol.sextantCodepoint(@intCast(mask & 0x3F));
}

fn octantGlyph(mask: u8) u21 {
    return symbol.octantCodepoint(mask);
}

/// Generic 2×`rows` sub-cell partition renderer (sextant rows=3, octant rows=4).
/// Mirrors renderQuadrant: threshold each sub-pixel against the cell mean (or the
/// dither matrix) to a bitmask, map the mask to a glyph, then split the cell into
/// two representative colors. Needs Unicode legacy-computing glyphs, so it is
/// rejected for ascii-only and basic-block terminals.
fn renderSubcell(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
    comptime rows: u32,
    comptime glyphFn: fn (u8) u21,
) !void {
    if (terminal.symbols == .ascii_only or terminal.symbols == .block_basic) {
        return Error.UnsupportedRenderMode;
    }

    const mapping = sample.fitMapping(image, terminal, options.fit);
    const frame = &workspace.frame;
    try frame.ensureCapacity(allocator, mapping.columns, mapping.rows, terminal.color);
    const policy = renderSamplerPolicy(options, terminal, context);
    try ensureWorkspaceSamplePlan(workspace, allocator, image, mapping, 2, rows, policy);
    const plan = workspaceSamplePlanPtr(workspace, policy);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, policy);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const fs_grid: ?[]bool = if (options.dither == .floyd_steinberg)
        try buildFsGrid(allocator, image, terminal, integral, mapping, plan, options, 2, rows)
    else
        null;
    defer if (fs_grid) |g| allocator.free(g);
    const fs_w = mapping.columns * 2;

    const count = rows * 2;
    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            var samples: [8]sample.Sample = undefined;
            var adjusted: [8]f32 = undefined;
            var sum: f32 = 0.0;

            var sy: u32 = 0;
            while (sy < rows) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < 2) : (sx += 1) {
                    const sub_idx = sy * 2 + sx;
                    var l: f32 = undefined;
                    if (frame.color == .none) {
                        l = sampleCellLuma(image, terminal, integral, mapping, plan, col, row, 2, rows, sx, sy);
                    } else {
                        samples[sub_idx] = sampleCell(image, terminal, mapping, plan, col, row, 2, rows, sx, sy);
                        l = samples[sub_idx].luma;
                    }
                    adjusted[sub_idx] = luma.applyAdjustments(l, options.contrast, options.brightness, options.invert);
                    sum += adjusted[sub_idx];
                }
            }

            const avg = sum / @as(f32, @floatFromInt(count));
            var mask: u8 = 0;
            var sub_idx: u32 = 0;
            while (sub_idx < count) : (sub_idx += 1) {
                const sub_x = sub_idx % 2;
                const sub_y = sub_idx / 2;
                const on = if (fs_grid) |g|
                    g[(row * rows + sub_y) * fs_w + (col * 2 + sub_x)]
                else
                    adjusted[sub_idx] >= partitionThreshold(options, col * 2 + sub_x, row * rows + sub_y, avg, frame.color == .none);
                if (on) mask |= @as(u8, 1) << @intCast(sub_idx);
            }

            frame.codepoints[idx] = glyphFn(mask);
            if (frame.color != .none) {
                assignPartitionColorsN(frame, idx, samples[0..count], mask, options.color_stat);
            }
        }
    }
}

fn renderBraille(
    workspace: *RenderWorkspace,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
    context: RenderContext,
) !void {
    if (terminal.symbols == .ascii_only or terminal.symbols == .block_basic or terminal.symbols == .block_legacy) {
        return Error.UnsupportedRenderMode;
    }

    const mapping = sample.fitMapping(image, terminal, options.fit);
    const frame = &workspace.frame;
    try frame.ensureCapacity(allocator, mapping.columns, mapping.rows, terminal.color);
    const policy = renderSamplerPolicy(options, terminal, context);
    try ensureWorkspaceSamplePlan(workspace, allocator, image, mapping, 2, 4, policy);
    const plan = workspaceSamplePlanPtr(workspace, policy);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, policy);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral = resolveIntegral(&integral_opt, context);

    const background = rgbFromBackground(terminal.background);

    const fs_grid: ?[]bool = if (options.dither == .floyd_steinberg)
        try buildFsGrid(allocator, image, terminal, integral, mapping, plan, options, 2, 4)
    else
        null;
    defer if (fs_grid) |g| allocator.free(g);
    const fs_w = mapping.columns * 2;

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
                    const dither_threshold = dither.threshold(options.dither, col * 2 + sx, row * 4 + sy);
                    if (frame.color == .none) {
                        const l = sampleCellLuma(image, terminal, integral, mapping, plan, col, row, 2, 4, sx, sy);
                        const on = if (fs_grid) |g|
                            g[(row * 4 + sy) * fs_w + (col * 2 + sx)]
                        else
                            luma.applyAdjustments(l, options.contrast, options.brightness, options.invert) >= dither_threshold;
                        if (on) mask |= symbol.brailleDotMask(sx, sy);
                    } else {
                        const s = sampleCell(image, terminal, mapping, plan, col, row, 2, 4, sx, sy);
                        const on = if (fs_grid) |g|
                            g[(row * 4 + sy) * fs_w + (col * 2 + sx)]
                        else
                            luma.applyAdjustments(s.luma, options.contrast, options.brightness, options.invert) >= dither_threshold;
                        if (on) {
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

    return;
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

/// Threshold for a sub-cell partition. In color mode the cell mean splits the
/// cell into its two dominant tones (the foreground/background clusters). In
/// mono there is no second color to recover, so the mean is degenerate for flat
/// cells (every sub-pixel ties `>= avg`, filling the cell solid and inverting
/// flat regions); use a fixed midpoint instead, matching the braille and
/// half-block paths. Ordered dithering overrides both with its matrix value.
fn partitionThreshold(options: Options, x: u32, y: u32, avg: f32, mono: bool) f32 {
    if (mono) return dither.threshold(options.dither, x, y);
    return thresholdFor(options, x, y, avg);
}

/// Floyd–Steinberg error diffusion over the whole sub-pixel luma grid, returning
/// a binary on/off grid of `(cols*sub_w) x (rows*sub_h)`. Error diffusion is
/// sequential and crosses cell boundaries, so — unlike ordered dithering — it
/// must be computed once for the frame; the partition/braille renderers then read
/// bits from it instead of thresholding each sub-pixel independently. Caller owns
/// the returned slice.
fn buildFsGrid(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    integral: ?*const sample.IntegralLuma,
    mapping: sample.Mapping,
    plan: ?*const sample.SamplePlan,
    options: Options,
    sub_w: u32,
    sub_h: u32,
) ![]bool {
    const gw = mapping.columns * sub_w;
    const gh = mapping.rows * sub_h;
    const lum = try allocator.alloc(f32, @as(usize, gw) * gh);
    defer allocator.free(lum);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var sy: u32 = 0;
        while (sy < sub_h) : (sy += 1) {
            var col: u32 = 0;
            while (col < mapping.columns) : (col += 1) {
                var sx: u32 = 0;
                while (sx < sub_w) : (sx += 1) {
                    const l = sampleCellLuma(image, terminal, integral, mapping, plan, col, row, sub_w, sub_h, sx, sy);
                    const gx = col * sub_w + sx;
                    const gy = row * sub_h + sy;
                    lum[@as(usize, gy) * gw + gx] = luma.applyAdjustments(l, options.contrast, options.brightness, options.invert);
                }
            }
        }
    }

    const out = try allocator.alloc(bool, @as(usize, gw) * gh);
    var y: u32 = 0;
    while (y < gh) : (y += 1) {
        var x: u32 = 0;
        while (x < gw) : (x += 1) {
            const i = @as(usize, y) * gw + x;
            const on = lum[i] >= 0.5;
            out[i] = on;
            const err = lum[i] - (if (on) @as(f32, 1.0) else 0.0);
            if (x + 1 < gw) lum[i + 1] += err * (7.0 / 16.0);
            if (y + 1 < gh) {
                const below = i + gw;
                if (x > 0) lum[below - 1] += err * (3.0 / 16.0);
                lum[below] += err * (5.0 / 16.0);
                if (x + 1 < gw) lum[below + 1] += err * (1.0 / 16.0);
            }
        }
    }
    return out;
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
    mapping: sample.Mapping,
    plan: ?*const sample.SamplePlan,
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
            const raw = sampleGlyphStructureLuma(image, terminal, integral, mapping, plan, col, row, sx, sy);
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

fn sampleGlyphStructureLuma(
    image: ImageView,
    terminal: TerminalProfile,
    integral: ?*const sample.IntegralLuma,
    mapping: sample.Mapping,
    plan: ?*const sample.SamplePlan,
    col: u32,
    row: u32,
    sub_x: u32,
    sub_y: u32,
) f32 {
    if (plan) |p| {
        return sample.regionLumaSpansDirect(image, terminal, integral, p.xSpan(col, sub_x), p.ySpan(row, sub_y));
    }
    return sampleCellLuma(image, terminal, integral, mapping, null, col, row, glyph.cell_width, glyph.cell_height, sub_x, sub_y);
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
        return atlas.selectGlyphByTone(features.coverage);
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
    mapping: sample.Mapping,
    plan: ?*const sample.SamplePlan,
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
            const s = sampleCell(image, terminal, mapping, plan, col, row, glyph.cell_width, glyph.cell_height, sx, sy);
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
        const region = sample.cellRegion(mapping, col, row, 1, 1, 0, 0);
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
    assignPartitionColorsN(frame, idx, samples, mask, stat);
}

/// Split up to 8 sub-cell samples into a foreground (mask bit set) and background
/// representative color. Shared by the quadrant/sextant/octant renderers.
fn assignPartitionColorsN(frame: *Frame, idx: usize, samples: []const sample.Sample, mask: u8, stat: ColorStat) void {
    var fg_buf: [8]color.LinearRgb = undefined;
    var bg_buf: [8]color.LinearRgb = undefined;
    var fg_count: usize = 0;
    var bg_count: usize = 0;

    for (samples, 0..) |s, sample_idx| {
        if ((mask & (@as(u8, 1) << @intCast(sample_idx))) != 0) {
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

const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    bytes_allocated: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *CountingAllocator) void {
        self.alloc_count = 0;
        self.bytes_allocated = 0;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr);
        if (ptr != null) {
            self.alloc_count += 1;
            self.bytes_allocated += len;
        }
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr);
        if (ptr != null and new_len > memory.len) {
            self.alloc_count += 1;
            self.bytes_allocated += new_len - memory.len;
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

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

test "frame diff previous null emits full frame runs" {
    var codepoints = [_]u21{ 'A', 'B' };
    var frame = Frame{
        .columns = 2,
        .rows = 1,
        .color = .none,
        .codepoints = &codepoints,
        .fg = @constCast(&[_]Rgb8{}),
        .bg = @constCast(&[_]Rgb8{}),
    };
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const stats = try renderFrameDiffToWriter(&writer, null, &frame, .{});

    try std.testing.expectEqualStrings("\x1b[1;1HAB", writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), stats.cells_examined);
    try std.testing.expectEqual(@as(usize, 2), stats.cells_changed);
    try std.testing.expectEqual(@as(usize, 1), stats.runs_emitted);
    try std.testing.expectEqual(writer.end, stats.bytes_emitted);
}

test "frame diff identical frames emit no bytes" {
    var codepoints = [_]u21{ 'A', 'B', 'C' };
    var previous = Frame{
        .columns = 3,
        .rows = 1,
        .color = .none,
        .codepoints = &codepoints,
        .fg = @constCast(&[_]Rgb8{}),
        .bg = @constCast(&[_]Rgb8{}),
    };
    var current = previous;
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const stats = try renderFrameDiffToWriter(&writer, &previous, &current, .{});

    try std.testing.expectEqualStrings("", writer.buffered());
    try std.testing.expectEqual(@as(usize, 3), stats.cells_examined);
    try std.testing.expectEqual(@as(usize, 0), stats.cells_changed);
    try std.testing.expectEqual(@as(usize, 0), stats.runs_emitted);
    try std.testing.expectEqual(@as(usize, 0), stats.bytes_emitted);
}

test "frame diff coalesces row contiguous dirty runs" {
    var previous_codepoints = [_]u21{ 'A', 'B', 'C', 'D', 'E' };
    var current_codepoints = [_]u21{ 'A', 'X', 'Y', 'D', 'E' };
    var previous = Frame{
        .columns = 5,
        .rows = 1,
        .color = .none,
        .codepoints = &previous_codepoints,
        .fg = @constCast(&[_]Rgb8{}),
        .bg = @constCast(&[_]Rgb8{}),
    };
    var current = previous;
    current.codepoints = &current_codepoints;
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const stats = try renderFrameDiffToWriter(&writer, &previous, &current, .{});

    try std.testing.expectEqualStrings("\x1b[1;2HXY", writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), stats.cells_changed);
    try std.testing.expectEqual(@as(usize, 1), stats.runs_emitted);
}

test "frame diff emits separate row runs" {
    var previous_codepoints = [_]u21{ 'A', 'B', 'C', 'D' };
    var current_codepoints = [_]u21{ 'X', 'B', 'C', 'Y' };
    var previous = Frame{
        .columns = 2,
        .rows = 2,
        .color = .none,
        .codepoints = &previous_codepoints,
        .fg = @constCast(&[_]Rgb8{}),
        .bg = @constCast(&[_]Rgb8{}),
    };
    var current = previous;
    current.codepoints = &current_codepoints;
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const stats = try renderFrameDiffToWriter(&writer, &previous, &current, .{});

    try std.testing.expectEqualStrings("\x1b[1;1HX\x1b[2;2HY", writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), stats.cells_changed);
    try std.testing.expectEqual(@as(usize, 2), stats.runs_emitted);
}

test "frame diff rewrites color-only changes and colored spaces" {
    var previous_codepoints = [_]u21{ 'A', ' ' };
    var current_codepoints = previous_codepoints;
    var previous_fg = [_]Rgb8{
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 255, .g = 255, .b = 255 },
    };
    var previous_bg = [_]Rgb8{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
    };
    var current_fg = previous_fg;
    var current_bg = previous_bg;
    current_fg[0] = .{ .r = 255, .g = 0, .b = 0 };
    current_bg[1] = .{ .r = 0, .g = 0, .b = 255 };
    var previous = Frame{
        .columns = 2,
        .rows = 1,
        .color = .truecolor,
        .codepoints = &previous_codepoints,
        .fg = &previous_fg,
        .bg = &previous_bg,
    };
    var current = Frame{
        .columns = 2,
        .rows = 1,
        .color = .truecolor,
        .codepoints = &current_codepoints,
        .fg = &current_fg,
        .bg = &current_bg,
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const stats = try renderFrameDiffToWriter(&writer, &previous, &current, .{});
    const out = writer.buffered();

    try std.testing.expectEqual(@as(usize, 2), stats.cells_changed);
    try std.testing.expectEqual(@as(usize, 1), stats.runs_emitted);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;255;0;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[48;2;0;0;255m ") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[0m"));
}

test "frame diff mismatch behavior is explicit" {
    var previous_codepoints = [_]u21{'A'};
    var current_codepoints = [_]u21{ 'B', 'C' };
    var previous = Frame{
        .columns = 1,
        .rows = 1,
        .color = .none,
        .codepoints = &previous_codepoints,
        .fg = @constCast(&[_]Rgb8{}),
        .bg = @constCast(&[_]Rgb8{}),
    };
    var current = Frame{
        .columns = 2,
        .rows = 1,
        .color = .none,
        .codepoints = &current_codepoints,
        .fg = @constCast(&[_]Rgb8{}),
        .bg = @constCast(&[_]Rgb8{}),
    };
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(
        AnsiDiffError.FrameShapeMismatch,
        renderFrameDiffToWriter(&writer, &previous, &current, .{}),
    );

    writer = .fixed(&buffer);
    const stats = try renderFrameDiffToWriter(&writer, &previous, &current, .{ .mismatch = .full_frame_on_mismatch });
    try std.testing.expectEqualStrings("\x1b[1;1HBC", writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), stats.cells_changed);

    current.columns = 1;
    current.codepoints = current_codepoints[0..1];
    current.color = .truecolor;
    try std.testing.expectError(
        AnsiDiffError.FrameColorMismatch,
        renderFrameDiffToWriter(&writer, &previous, &current, .{}),
    );
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

test "octant renderer maps a 2x4 fixture to a block octant glyph" {
    const allocator = std.testing.allocator;
    const W: Rgba8 = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const B: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    // Positions 1,2,3 lit (TL, TR, mid-left) -> BLOCK OCTANT-123 (U+1CD02).
    const pixels = [_]Rgba8{ W, W, W, B, B, B, B, B };
    var frame = try renderToCells(
        allocator,
        .{ .width = 2, .height = 4, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .none, .symbols = .block_legacy },
        .{ .mode = .partition, .partition = .octant_2x4, .fit = .stretch },
    );
    defer frame.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 0x1CD02), frame.codepoints[0]);
}

test "sextant renderer maps a 2x3 fixture to a block sextant glyph" {
    const allocator = std.testing.allocator;
    const W: Rgba8 = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const B: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    // Only the top-left sextant lit -> first block sextant (U+1FB00).
    const pixels = [_]Rgba8{ W, B, B, B, B, B };
    var frame = try renderToCells(
        allocator,
        .{ .width = 2, .height = 3, .stride = 2 * @sizeOf(Rgba8), .pixels = &pixels },
        .{ .columns = 1, .rows = 1, .color = .none, .symbols = .block_legacy },
        .{ .mode = .partition, .partition = .sextant_2x3, .fit = .stretch },
    );
    defer frame.deinit(allocator);
    try std.testing.expectEqual(@as(u21, 0x1FB00), frame.codepoints[0]);
}

test "mono partitions don't invert flat cells" {
    // A uniform dark field must render as empty cells, not solid blocks. This
    // guards the flat-cell threshold: a per-cell mean would tie every sub-pixel
    // `>= avg` and fill the cell, inverting the image.
    const allocator = std.testing.allocator;
    const dark = [_]Rgba8{.{ .r = 51, .g = 51, .b = 51, .a = 255 }} ** 8; // luma ~0.2
    const bright = [_]Rgba8{.{ .r = 204, .g = 204, .b = 204, .a = 255 }} ** 8; // ~0.8
    inline for (.{ PartitionKind.quadrant_2x2, PartitionKind.sextant_2x3, PartitionKind.octant_2x4 }) |part| {
        var dim = try renderToCells(allocator, .{ .width = 2, .height = 4, .stride = 2 * @sizeOf(Rgba8), .pixels = &dark }, .{ .columns = 1, .rows = 1, .color = .none, .symbols = .block_legacy }, .{ .mode = .partition, .partition = part, .fit = .stretch });
        defer dim.deinit(allocator);
        try std.testing.expectEqual(@as(u21, ' '), dim.codepoints[0]);
        var lit = try renderToCells(allocator, .{ .width = 2, .height = 4, .stride = 2 * @sizeOf(Rgba8), .pixels = &bright }, .{ .columns = 1, .rows = 1, .color = .none, .symbols = .block_legacy }, .{ .mode = .partition, .partition = part, .fit = .stretch });
        defer lit.deinit(allocator);
        try std.testing.expectEqual(@as(u21, '█'), lit.codepoints[0]);
    }
}

test "floyd-steinberg diffuses a flat field that a hard threshold drops" {
    // A uniform 25%-gray field: a hard threshold (>=0.5) makes every sub-pixel
    // off -> all blank cells, losing the tone. Error diffusion must scatter ~25%
    // ink so the average brightness survives.
    const allocator = std.testing.allocator;
    const gray = [_]Rgba8{.{ .r = 64, .g = 64, .b = 64, .a = 255 }} ** (32 * 16);
    const view: ImageView = .{ .width = 32, .height = 16, .stride = 32 * @sizeOf(Rgba8), .pixels = &gray };
    const term: TerminalProfile = .{ .columns = 16, .rows = 8, .color = .none, .symbols = .block_legacy };

    var plain = try renderToCells(allocator, view, term, .{ .mode = .partition, .partition = .octant_2x4, .fit = .stretch, .dither = .none });
    defer plain.deinit(allocator);
    var fs = try renderToCells(allocator, view, term, .{ .mode = .partition, .partition = .octant_2x4, .fit = .stretch, .dither = .floyd_steinberg });
    defer fs.deinit(allocator);

    var plain_ink: usize = 0;
    var fs_ink: usize = 0;
    for (plain.codepoints) |cp| if (cp != ' ') {
        plain_ink += 1;
    };
    for (fs.codepoints) |cp| if (cp != ' ') {
        fs_ink += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), plain_ink); // hard threshold drops it
    try std.testing.expect(fs_ink > plain.codepoints.len / 2); // FS keeps the tone
}

test "octant renderer is rejected for basic-block terminals" {
    const allocator = std.testing.allocator;
    const px = [_]Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }} ** 8;
    try std.testing.expectError(Error.UnsupportedRenderMode, renderToCells(
        allocator,
        .{ .width = 2, .height = 4, .stride = 2 * @sizeOf(Rgba8), .pixels = &px },
        .{ .columns = 1, .rows = 1, .color = .none, .symbols = .block_basic },
        .{ .mode = .partition, .partition = .octant_2x4, .fit = .stretch },
    ));
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

test "ansi256 and ansi16 render and carry truecolor cells (quantized at emit)" {
    const pixels = [_]Rgba8{.{ .r = 200, .g = 40, .b = 40, .a = 255 }};
    for ([_]ColorMode{ .ansi256, .ansi16 }) |mode| {
        var frame = try renderToCells(
            std.testing.allocator,
            .{ .width = 1, .height = 1, .stride = @sizeOf(Rgba8), .pixels = &pixels },
            .{ .columns = 1, .rows = 1, .color = mode },
            .{ .mode = .partition, .partition = .half_1x2, .fit = .stretch },
        );
        defer frame.deinit(std.testing.allocator);
        try std.testing.expectEqual(mode, frame.color);
        // displayColor maps the cell to a real palette entry (a reddish one here).
        const shown = displayColor(frame.fg[0], mode);
        try std.testing.expect(shown.r > shown.g and shown.r > shown.b);
    }
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

test "render workspace matches renderToCells output" {
    const allocator = std.testing.allocator;

    var pixels: [8 * 8]Rgba8 = undefined;
    for (&pixels, 0..) |*p, i| {
        const x: u8 = @intCast(i % 8);
        const y: u8 = @intCast(i / 8);
        p.* = .{ .r = x * 30, .g = y * 30, .b = 120, .a = 255 };
    }
    const image = ImageView{ .width = 8, .height = 8, .stride = 8 * @sizeOf(Rgba8), .pixels = &pixels };
    const terminal = TerminalProfile{ .columns = 4, .rows = 4, .color = .truecolor };
    const options = Options{ .mode = .partition, .partition = .quadrant_2x2, .fit = .stretch };

    var expected = try renderToCells(allocator, image, terminal, options);
    defer expected.deinit(allocator);

    var workspace: RenderWorkspace = .empty;
    defer workspace.deinit(allocator);
    try renderIntoWorkspace(&workspace, allocator, image, terminal, options);

    try std.testing.expectEqual(expected.columns, workspace.frame.columns);
    try std.testing.expectEqual(expected.rows, workspace.frame.rows);
    try std.testing.expectEqual(expected.color, workspace.frame.color);
    try std.testing.expectEqualSlices(u21, expected.codepoints, workspace.frame.codepoints);
    try std.testing.expectEqualSlices(Rgb8, expected.fg, workspace.frame.fg);
    try std.testing.expectEqualSlices(Rgb8, expected.bg, workspace.frame.bg);
}

test "render workspace reuses frame and sample plan allocations" {
    var counting = CountingAllocator{ .child = std.testing.allocator };
    const allocator = counting.allocator();

    var pixels: [16 * 16]Rgba8 = undefined;
    for (&pixels, 0..) |*p, i| {
        const x: u8 = @intCast(i % 16);
        const y: u8 = @intCast(i / 16);
        p.* = .{ .r = x * 12, .g = y * 12, .b = 90, .a = 255 };
    }
    const image = ImageView{ .width = 16, .height = 16, .stride = 16 * @sizeOf(Rgba8), .pixels = &pixels };
    const terminal = TerminalProfile{ .columns = 8, .rows = 4, .color = .truecolor };
    const options = Options{ .mode = .density, .fit = .stretch };

    var workspace: RenderWorkspace = .empty;
    defer workspace.deinit(allocator);

    try renderIntoWorkspace(&workspace, allocator, image, terminal, options);
    try std.testing.expect(counting.alloc_count > 0);
    try std.testing.expect(workspace.sample_plan.x_spans.len > 0);

    counting.reset();
    try renderIntoWorkspace(&workspace, allocator, image, terminal, options);
    try std.testing.expectEqual(@as(usize, 0), counting.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), counting.bytes_allocated);
}

test "prepared render workspace does not allocate spans for integral reuse" {
    var counting = CountingAllocator{ .child = std.testing.allocator };
    const allocator = counting.allocator();

    var pixels: [8 * 8]Rgba8 = undefined;
    for (&pixels, 0..) |*p, i| {
        const x: u8 = @intCast(i % 8);
        p.* = .{ .r = x * 20, .g = x * 10, .b = 40, .a = 255 };
    }
    const image = ImageView{ .width = 8, .height = 8, .stride = 8 * @sizeOf(Rgba8), .pixels = &pixels };
    const terminal = TerminalProfile{ .columns = 4, .rows = 4, .color = .none };
    const options = Options{ .mode = .density, .fit = .stretch, .sample_strategy = .integral_luma };

    var prepared = try prepareImage(allocator, image, terminal, .{ .sample_strategy = .integral_luma });
    defer prepared.deinit(allocator);

    var workspace: RenderWorkspace = .empty;
    defer workspace.deinit(allocator);

    counting.reset();
    try renderPreparedIntoWorkspace(&workspace, allocator, &prepared, terminal, options);
    try std.testing.expect(counting.alloc_count > 0);
    try std.testing.expectEqual(@as(usize, 0), workspace.sample_plan.x_spans.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.sample_plan.y_spans.len);

    counting.reset();
    try renderPreparedIntoWorkspace(&workspace, allocator, &prepared, terminal, options);
    try std.testing.expectEqual(@as(usize, 0), counting.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), counting.bytes_allocated);
}

test "auto sampler policy keeps known span regressions on direct box" {
    const mono = TerminalProfile{ .columns = 80, .rows = 30, .color = .none };
    const color_term = TerminalProfile{ .columns = 80, .rows = 30, .color = .truecolor };

    try std.testing.expectEqual(SamplerPolicy.span_precompute, resolveSamplerPolicy(
        .{ .mode = .density },
        mono,
        false,
    ));
    try std.testing.expectEqual(SamplerPolicy.span_precompute, resolveSamplerPolicy(
        .{ .mode = .glyph_structure },
        color_term,
        false,
    ));
    try std.testing.expectEqual(SamplerPolicy.direct_box, resolveSamplerPolicy(
        .{ .mode = .partition, .partition = .half_1x2 },
        color_term,
        false,
    ));
    try std.testing.expectEqual(SamplerPolicy.direct_box, resolveSamplerPolicy(
        .{ .mode = .partition, .partition = .quadrant_2x2 },
        color_term,
        false,
    ));
    try std.testing.expectEqual(SamplerPolicy.direct_box, resolveSamplerPolicy(
        .{ .mode = .braille },
        mono,
        false,
    ));
    try std.testing.expectEqual(SamplerPolicy.span_precompute, resolveSamplerPolicy(
        .{ .mode = .braille },
        color_term,
        false,
    ));
    try std.testing.expectEqual(SamplerPolicy.prepared_integral_luma, resolveSamplerPolicy(
        .{ .mode = .density, .sample_strategy = .integral_luma },
        mono,
        true,
    ));
    try std.testing.expectEqual(SamplerPolicy.direct_box, resolveSamplerPolicy(
        .{ .mode = .partition, .partition = .half_1x2, .sample_strategy = .integral_luma },
        mono,
        true,
    ));
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
