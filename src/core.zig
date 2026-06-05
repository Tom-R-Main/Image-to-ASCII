const std = @import("std");

const color = @import("color.zig");
const dither = @import("dither.zig");
const luma = @import("luma.zig");
const pixel = @import("pixel.zig");
const sample = @import("sample.zig");
const symbol = @import("symbol.zig");

pub const Rgba8 = pixel.Rgba8;
pub const Rgb8 = pixel.Rgb8;
pub const ColorStat = color.ColorStat;
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

    return switch (options.mode) {
        .density => renderDensity(allocator, image, terminal, options),
        .partition => switch (options.partition) {
            .density_1x1 => renderDensity(allocator, image, terminal, options),
            .half_1x2 => renderHalfBlock(allocator, image, terminal, options),
            .quadrant_2x2 => renderQuadrant(allocator, image, terminal, options),
            else => Error.UnsupportedRenderMode,
        },
        .braille => renderBraille(allocator, image, terminal, options),
        else => Error.UnsupportedRenderMode,
    };
}

pub fn renderToWriter(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !void {
    var frame = try renderToCells(allocator, image, terminal, options);
    defer frame.deinit(allocator);

    try writeFrameAnsi(writer, frame);
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
) !?sample.IntegralLuma {
    if (!sample.useIntegral(options.sample_strategy, image, terminal.color)) return null;
    return try sample.IntegralLuma.build(allocator, image, terminal.background);
}

fn renderDensity(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !Frame {
    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral: ?*const sample.IntegralLuma = if (integral_opt) |*it| it else null;

    const background = rgbFromBackground(terminal.background);

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            const region = sample.cellRegion(mapping, col, row, 1, 1, 0, 0);

            var lum: f32 = undefined;
            if (frame.color == .none) {
                lum = sample.regionLuma(image, terminal, integral, region);
            } else {
                const s = sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]);
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

    var row: u32 = 0;
    while (row < mapping.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < mapping.columns) : (col += 1) {
            const idx = @as(usize, row) * mapping.columns + col;
            const top_region = sample.cellRegion(mapping, col, row, 1, 2, 0, 0);
            const bottom_region = sample.cellRegion(mapping, col, row, 1, 2, 0, 1);
            const top = sample.areaSample(image, terminal, top_region[0], top_region[1], top_region[2], top_region[3]);
            const bottom = sample.areaSample(image, terminal, bottom_region[0], bottom_region[1], bottom_region[2], bottom_region[3]);

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
) !Frame {
    if (terminal.symbols == .ascii_only) return Error.UnsupportedRenderMode;

    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral: ?*const sample.IntegralLuma = if (integral_opt) |*it| it else null;

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
                    const region = sample.cellRegion(mapping, col, row, 2, 2, sx, sy);
                    var l: f32 = undefined;
                    if (frame.color == .none) {
                        l = sample.regionLuma(image, terminal, integral, region);
                    } else {
                        samples[sub_idx] = sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]);
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
) !Frame {
    if (terminal.symbols == .ascii_only or terminal.symbols == .block_basic or terminal.symbols == .block_legacy) {
        return Error.UnsupportedRenderMode;
    }

    const mapping = sample.fitMapping(image, terminal, options.fit);
    var frame = try allocFrame(allocator, mapping.columns, mapping.rows, terminal.color);
    errdefer frame.deinit(allocator);

    var integral_opt = try maybeBuildIntegral(allocator, image, terminal, options);
    defer if (integral_opt) |*it| it.deinit(allocator);
    const integral: ?*const sample.IntegralLuma = if (integral_opt) |*it| it else null;

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
                    const region = sample.cellRegion(mapping, col, row, 2, 4, sx, sy);
                    const dither_threshold = dither.threshold(options.dither, col * 2 + sx, row * 4 + sy);
                    if (frame.color == .none) {
                        const l = sample.regionLuma(image, terminal, integral, region);
                        if (luma.applyAdjustments(l, options.contrast, options.brightness, options.invert) >= dither_threshold) {
                            mask |= symbol.brailleDotMask(sx, sy);
                        }
                    } else {
                        const s = sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]);
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

fn eqlRgb(a: Rgb8, b: Rgb8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

fn writeFrameAnsi(writer: *std.Io.Writer, frame: Frame) !void {
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
                    try writer.print("\x1b[38;2;{};{};{}m", .{ next_fg.r, next_fg.g, next_fg.b });
                    current_fg = next_fg;
                }
                if (current_bg == null or !eqlRgb(current_bg.?, next_bg)) {
                    try writer.print("\x1b[48;2;{};{};{}m", .{ next_bg.r, next_bg.g, next_bg.b });
                    current_bg = next_bg;
                }
            }

            try writer.printUnicodeCodepoint(frame.codepoints[idx]);
        }

        if (frame.color != .none) {
            try writer.writeAll("\x1b[0m");
            current_fg = null;
            current_bg = null;
        }
        try writer.writeByte('\n');
    }
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
