const std = @import("std");

const dither = @import("dither.zig");
const luma = @import("luma.zig");
const pixel = @import("pixel.zig");
const sample = @import("sample.zig");
const symbol = @import("symbol.zig");

pub const Rgba8 = pixel.Rgba8;
pub const Rgb8 = pixel.Rgb8;

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

fn renderDensity(
    allocator: std.mem.Allocator,
    image: ImageView,
    terminal: TerminalProfile,
    options: Options,
) !Frame {
    const size = sample.fittedSize(image, terminal, options.fit);
    var frame = try allocFrame(allocator, size.columns, size.rows, terminal.color);
    errdefer frame.deinit(allocator);

    const background = rgbFromBackground(terminal.background);

    var row: u32 = 0;
    while (row < size.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < size.columns) : (col += 1) {
            const idx = @as(usize, row) * size.columns + col;
            const region = sample.cellRegion(image, size, col, row, 1, 1, 0, 0);
            const s = sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]);
            const adjusted = luma.applyAdjustments(s.luma, options.contrast, options.brightness, options.invert);
            frame.codepoints[idx] = rampCodepoint(options.ramp, adjusted);

            if (frame.color != .none) {
                frame.fg[idx] = s.rgb;
                frame.bg[idx] = background;
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

    const size = sample.fittedSize(image, terminal, options.fit);
    var frame = try allocFrame(allocator, size.columns, size.rows, terminal.color);
    errdefer frame.deinit(allocator);

    var row: u32 = 0;
    while (row < size.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < size.columns) : (col += 1) {
            const idx = @as(usize, row) * size.columns + col;
            const top_region = sample.cellRegion(image, size, col, row, 1, 2, 0, 0);
            const bottom_region = sample.cellRegion(image, size, col, row, 1, 2, 0, 1);
            const top = sample.areaSample(image, terminal, top_region[0], top_region[1], top_region[2], top_region[3]);
            const bottom = sample.areaSample(image, terminal, bottom_region[0], bottom_region[1], bottom_region[2], bottom_region[3]);

            if (frame.color == .none) {
                frame.codepoints[idx] = halfBlockMonoCodepoint(top.luma, bottom.luma, options);
            } else {
                frame.codepoints[idx] = '▀';
                frame.fg[idx] = top.rgb;
                frame.bg[idx] = bottom.rgb;
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

    const size = sample.fittedSize(image, terminal, options.fit);
    var frame = try allocFrame(allocator, size.columns, size.rows, terminal.color);
    errdefer frame.deinit(allocator);

    var row: u32 = 0;
    while (row < size.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < size.columns) : (col += 1) {
            const idx = @as(usize, row) * size.columns + col;
            var samples: [4]sample.Sample = undefined;
            var adjusted: [4]f32 = undefined;
            var sum: f32 = 0.0;

            var sy: u32 = 0;
            while (sy < 2) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < 2) : (sx += 1) {
                    const sub_idx = sy * 2 + sx;
                    const region = sample.cellRegion(image, size, col, row, 2, 2, sx, sy);
                    samples[sub_idx] = sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]);
                    adjusted[sub_idx] = luma.applyAdjustments(samples[sub_idx].luma, options.contrast, options.brightness, options.invert);
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
                assignPartitionColors(&frame, idx, &samples, mask);
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

    const size = sample.fittedSize(image, terminal, options.fit);
    var frame = try allocFrame(allocator, size.columns, size.rows, terminal.color);
    errdefer frame.deinit(allocator);

    const background = rgbFromBackground(terminal.background);

    var row: u32 = 0;
    while (row < size.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < size.columns) : (col += 1) {
            const idx = @as(usize, row) * size.columns + col;
            var mask: u8 = 0;
            var samples: [8]sample.Sample = undefined;
            var on_accum = sample.Sample{
                .linear = .{ .r = 0.0, .g = 0.0, .b = 0.0 },
                .rgb = background,
                .luma = 0.0,
            };
            var on_count: u32 = 0;

            var sy: u32 = 0;
            while (sy < 4) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < 2) : (sx += 1) {
                    const sub_idx = sy * 2 + sx;
                    const region = sample.cellRegion(image, size, col, row, 2, 4, sx, sy);
                    samples[sub_idx] = sample.areaSample(image, terminal, region[0], region[1], region[2], region[3]);
                    const adjusted = luma.applyAdjustments(samples[sub_idx].luma, options.contrast, options.brightness, options.invert);
                    if (adjusted >= dither.threshold(options.dither, col * 2 + sx, row * 4 + sy)) {
                        mask |= symbol.brailleDotMask(sx, sy);
                        on_accum.linear.r += samples[sub_idx].linear.r;
                        on_accum.linear.g += samples[sub_idx].linear.g;
                        on_accum.linear.b += samples[sub_idx].linear.b;
                        on_count += 1;
                    }
                }
            }

            frame.codepoints[idx] = symbol.brailleCodepoint(mask);
            if (frame.color != .none) {
                if (on_count > 0) {
                    const denom = @as(f32, @floatFromInt(on_count));
                    on_accum.linear.r /= denom;
                    on_accum.linear.g /= denom;
                    on_accum.linear.b /= denom;
                    frame.fg[idx] = @import("color.zig").encodeSrgb(on_accum.linear);
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

fn assignPartitionColors(frame: *Frame, idx: usize, samples: *const [4]sample.Sample, mask: u4) void {
    var fg = @import("color.zig").LinearRgb{ .r = 0.0, .g = 0.0, .b = 0.0 };
    var bg = @import("color.zig").LinearRgb{ .r = 0.0, .g = 0.0, .b = 0.0 };
    var fg_count: u32 = 0;
    var bg_count: u32 = 0;

    for (samples, 0..) |s, sample_idx| {
        if ((mask & (@as(u4, 1) << @intCast(sample_idx))) != 0) {
            fg.r += s.linear.r;
            fg.g += s.linear.g;
            fg.b += s.linear.b;
            fg_count += 1;
        } else {
            bg.r += s.linear.r;
            bg.g += s.linear.g;
            bg.b += s.linear.b;
            bg_count += 1;
        }
    }

    if (fg_count == 0) {
        frame.fg[idx] = samples[0].rgb;
    } else {
        const denom = @as(f32, @floatFromInt(fg_count));
        fg.r /= denom;
        fg.g /= denom;
        fg.b /= denom;
        frame.fg[idx] = @import("color.zig").encodeSrgb(fg);
    }

    if (bg_count == 0) {
        frame.bg[idx] = frame.fg[idx];
    } else {
        const denom = @as(f32, @floatFromInt(bg_count));
        bg.r /= denom;
        bg.g /= denom;
        bg.b /= denom;
        frame.bg[idx] = @import("color.zig").encodeSrgb(bg);
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
