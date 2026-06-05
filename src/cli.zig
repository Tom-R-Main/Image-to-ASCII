const std = @import("std");
const ascii = @import("image_to_ascii");
const image_loader = @import("image_loader");
const Io = std.Io;

const CliOptions = struct {
    input_path: ?[]const u8 = null,
    synthetic: Synthetic = .gradient,
    width: u32 = 80,
    height: u32 = 24,
    mode: ascii.RenderMode = .partition,
    partition: ascii.PartitionKind = .half_1x2,
    color: ascii.ColorMode = .truecolor,
    fit: ascii.FitMode = .stretch,
    dither: ascii.DitherMode = .none,
    invert: bool = false,
};

const Synthetic = enum {
    gradient,
    checkerboard,
    color_bars,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    if (args.len >= 2 and std.mem.eql(u8, args[1], "mermaid")) {
        runMermaid(stdout, stderr, init.io, arena, args[2..]) catch |err| {
            switch (err) {
                // These already wrote a precise message to stderr.
                error.MermaidSyntax, error.DiagramTooLarge => {},
                else => try stderr.print("error: {s}\n", .{describeCliError(err)}),
            }
            try stderr.flush();
            std.process.exit(1);
        };
        try stdout.flush();
        return;
    }

    const options = parseArgs(args) catch |err| {
        try stderr.print("error: {s}\n\n", .{describeCliError(err)});
        try writeUsage(stderr);
        try stderr.flush();
        return err;
    };

    if (argsContain(args, "--help")) {
        try writeUsage(stdout);
        try stdout.flush();
        return;
    }

    renderSelected(stdout, init.io, arena, options) catch |err| {
        try stderr.print("error: {s}\n", .{describeCliError(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.flush();
}

fn renderSelected(writer: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator, options: CliOptions) !void {
    var loaded: ?image_loader.LoadedImage = null;
    defer if (loaded) |*image| image.deinit(allocator);

    const image = if (options.input_path) |path| blk: {
        loaded = try image_loader.loadPath(io, allocator, path);
        break :blk loaded.?.imageView();
    } else try makeSynthetic(allocator, options.synthetic, 96, 48);

    try renderImage(writer, allocator, image, options);
}

fn renderImage(writer: *std.Io.Writer, allocator: std.mem.Allocator, image: ascii.ImageView, options: CliOptions) !void {
    try ascii.renderToWriter(
        writer,
        allocator,
        image,
        .{
            .columns = options.width,
            .rows = options.height,
            .color = options.color,
            .symbols = if (options.mode == .braille) .braille else .block_basic,
        },
        .{
            .mode = options.mode,
            .partition = options.partition,
            .fit = options.fit,
            .dither = options.dither,
            .invert = options.invert,
        },
    );
}

const MermaidCliOptions = struct {
    input_path: ?[]const u8 = null,
    glyph_set: ascii.GlyphSet = .unicode_box,
    color: ascii.ColorMode = .truecolor,
    // Pane fit. `width`/`height` pad to an exact pane; `max_*` only bound.
    width: ?u32 = null,
    height: ?u32 = null,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
    overflow: ascii.OverflowMode = .clip,
};

/// `mermaid <file.mmd> [--ascii|--unicode] [--color none|truecolor]`.
/// Reads a Mermaid flowchart, renders it to terminal cells, and writes the
/// frame to `writer`. Syntax errors are reported to `stderr` as
/// `file:line:col: message` and surfaced as `error.MermaidSyntax`.
fn runMermaid(
    writer: *std.Io.Writer,
    stderr: *std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    sub_args: []const []const u8,
) !void {
    if (argsContain(sub_args, "--help")) {
        try writeMermaidUsage(writer);
        return;
    }

    const options = try parseMermaidArgs(sub_args);
    const path = options.input_path orelse return error.MissingInput;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));

    var diagnostic: ?ascii.MermaidError = null;
    var frame = ascii.renderMermaid(allocator, source, .{
        .glyph_set = options.glyph_set,
        .color = options.color,
    }, &diagnostic) catch |err| {
        if (err == error.MermaidSyntax) {
            if (diagnostic) |d| {
                try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, d.line, d.column, d.message });
            }
        }
        return err;
    };
    defer frame.deinit(allocator);

    try emitMermaidFrame(writer, stderr, frame, options, path);
}

/// Emit the rendered frame, applying the pane-fit options. With no bounds set the
/// frame renders at natural size (the default). `width`/`height` pad to an exact
/// pane; `max-width`/`max-height` only bound. `overflow` decides what happens when
/// the natural diagram exceeds the bounds.
fn emitMermaidFrame(
    writer: *std.Io.Writer,
    stderr: *std.Io.Writer,
    frame: ascii.Frame,
    options: MermaidCliOptions,
    path: []const u8,
) !void {
    const bound_cols = options.width orelse options.max_width;
    const bound_rows = options.height orelse options.max_height;

    if (bound_cols == null and bound_rows == null) {
        return ascii.renderFrameToWriter(writer, frame);
    }

    const too_wide = bound_cols != null and frame.columns > bound_cols.?;
    const too_tall = bound_rows != null and frame.rows > bound_rows.?;
    if (too_wide or too_tall) {
        switch (options.overflow) {
            .allow => return ascii.renderFrameToWriter(writer, frame),
            .error_if_too_large => {
                try stderr.print(
                    "{s}: diagram is {d}x{d}, which exceeds the requested {d}x{d}\n",
                    .{ path, frame.columns, frame.rows, bound_cols orelse frame.columns, bound_rows orelse frame.rows },
                );
                return error.DiagramTooLarge;
            },
            .clip => {},
        }
    }

    // Exact pane (width/height) pads; max-* clamps to the natural size.
    const vp_cols = options.width orelse if (options.max_width) |m| @min(frame.columns, m) else frame.columns;
    const vp_rows = options.height orelse if (options.max_height) |m| @min(frame.rows, m) else frame.rows;
    try ascii.renderFrameRegionToWriter(writer, frame, .{ .columns = vp_cols, .rows = vp_rows });
}

fn parseMermaidArgs(args: []const []const u8) !MermaidCliOptions {
    var options = MermaidCliOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--ascii")) {
            options.glyph_set = .ascii;
        } else if (std.mem.eql(u8, arg, "--unicode")) {
            options.glyph_set = .unicode_box;
        } else if (std.mem.eql(u8, arg, "--color")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.color = parseMermaidColor(args[i]) orelse return error.InvalidColor;
        } else if (std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.width = try parsePositiveU32(args[i]);
        } else if (std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.height = try parsePositiveU32(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-width")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.max_width = try parsePositiveU32(args[i]);
        } else if (std.mem.eql(u8, arg, "--max-height")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.max_height = try parsePositiveU32(args[i]);
        } else if (std.mem.eql(u8, arg, "--overflow")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.overflow = parseOverflow(args[i]) orelse return error.InvalidOverflow;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else {
            if (options.input_path != null) return error.UnexpectedArgument;
            options.input_path = arg;
        }
    }

    return options;
}

fn parseOverflow(value: []const u8) ?ascii.OverflowMode {
    if (std.mem.eql(u8, value, "allow")) return .allow;
    if (std.mem.eql(u8, value, "clip")) return .clip;
    if (std.mem.eql(u8, value, "error")) return .error_if_too_large;
    return null;
}

/// The diagram renderer paints into a `CellCanvas`, which only models no-color
/// and truecolor; ANSI 16/256 are not available for diagrams yet.
fn parseMermaidColor(value: []const u8) ?ascii.ColorMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "truecolor")) return .truecolor;
    return null;
}

fn writeMermaidUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage: cell-render mermaid <file.mmd> [options]
        \\
        \\options:
        \\  --ascii              use the ASCII fallback glyph set (+ - | > etc.)
        \\  --unicode            use box-drawing glyphs (default)
        \\  --color none|truecolor   (default truecolor)
        \\  --width N            fit into an exact N-column pane (pads/clips)
        \\  --height N           fit into an exact N-row pane (pads/clips)
        \\  --max-width N        bound width to N columns (no padding)
        \\  --max-height N       bound height to N rows (no padding)
        \\  --overflow allow|clip|error   when the diagram exceeds the bounds
        \\                                (default clip)
        \\  --help
        \\
        \\Renders a Mermaid subset, auto-detected from the header:
        \\  flowchart/graph — TD/TB/LR/RL/BT; rect/round/circle/diamond nodes;
        \\                    --> --- -.-> ==> --o --x edges; pipe labels.
        \\  sequenceDiagram — participants/actors with aliases; ->> -->> -) -x
        \\                    messages; self-messages; notes; activations;
        \\                    alt/opt/loop/par blocks.
        \\  stateDiagram[-v2] — states, [*] start/end, A --> B : label.
        \\  classDiagram    — class cards with members; <|-- *-- o-- --> ..> .. .
        \\  erDiagram       — entity cards with attributes; ||--o{ cardinality.
        \\Comments use %%. Unsupported syntax is reported as file:line:col.
        \\
    );
}

fn parseArgs(args: []const []const u8) !CliOptions {
    var options = CliOptions{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.input_path = args[i];
        } else if (std.mem.eql(u8, arg, "--invert")) {
            options.invert = true;
        } else if (std.mem.eql(u8, arg, "--synthetic")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.synthetic = parseSynthetic(args[i]) orelse return error.InvalidSynthetic;
        } else if (std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.width = try parsePositiveU32(args[i]);
        } else if (std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.height = try parsePositiveU32(args[i]);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.mode = parseMode(args[i]) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, arg, "--partition")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.partition = parsePartition(args[i]) orelse return error.InvalidPartition;
        } else if (std.mem.eql(u8, arg, "--color")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.color = parseColor(args[i]) orelse return error.InvalidColor;
        } else if (std.mem.eql(u8, arg, "--fit")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.fit = parseFit(args[i]) orelse return error.InvalidFit;
        } else if (std.mem.eql(u8, arg, "--dither")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.dither = parseDither(args[i]) orelse return error.InvalidDither;
        } else {
            return error.UnknownArgument;
        }
    }

    return options;
}

fn parsePositiveU32(value: []const u8) !u32 {
    const parsed = try std.fmt.parseInt(u32, value, 10);
    if (parsed == 0) return error.InvalidDimension;
    return parsed;
}

fn parseSynthetic(value: []const u8) ?Synthetic {
    if (std.mem.eql(u8, value, "gradient")) return .gradient;
    if (std.mem.eql(u8, value, "checkerboard")) return .checkerboard;
    if (std.mem.eql(u8, value, "color-bars")) return .color_bars;
    return null;
}

fn parseMode(value: []const u8) ?ascii.RenderMode {
    if (std.mem.eql(u8, value, "density")) return .density;
    if (std.mem.eql(u8, value, "partition")) return .partition;
    if (std.mem.eql(u8, value, "braille")) return .braille;
    if (std.mem.eql(u8, value, "glyph-tone")) return .glyph_tone;
    if (std.mem.eql(u8, value, "glyph-structure")) return .glyph_structure;
    return null;
}

fn parsePartition(value: []const u8) ?ascii.PartitionKind {
    if (std.mem.eql(u8, value, "density")) return .density_1x1;
    if (std.mem.eql(u8, value, "half")) return .half_1x2;
    if (std.mem.eql(u8, value, "quadrant")) return .quadrant_2x2;
    return null;
}

fn parseColor(value: []const u8) ?ascii.ColorMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "16")) return .ansi16;
    if (std.mem.eql(u8, value, "256")) return .ansi256;
    if (std.mem.eql(u8, value, "truecolor")) return .truecolor;
    return null;
}

fn parseFit(value: []const u8) ?ascii.FitMode {
    if (std.mem.eql(u8, value, "contain")) return .contain;
    if (std.mem.eql(u8, value, "cover")) return .cover;
    if (std.mem.eql(u8, value, "stretch")) return .stretch;
    return null;
}

fn parseDither(value: []const u8) ?ascii.DitherMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "ordered-2x2")) return .ordered_2x2;
    if (std.mem.eql(u8, value, "ordered-4x4")) return .ordered_4x4;
    return null;
}

fn makeSynthetic(allocator: std.mem.Allocator, synthetic: Synthetic, width: u32, height: u32) !ascii.ImageView {
    const pixels = try allocator.alloc(ascii.Rgba8, try std.math.mul(usize, width, height));

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            pixels[@as(usize, y) * width + x] = switch (synthetic) {
                .gradient => gradientPixel(x, y, width, height),
                .checkerboard => checkerboardPixel(x, y),
                .color_bars => colorBarPixel(x, width),
            };
        }
    }

    return .{
        .width = width,
        .height = height,
        .stride = @as(usize, width) * @sizeOf(ascii.Rgba8),
        .pixels = pixels,
    };
}

fn gradientPixel(x: u32, y: u32, width: u32, height: u32) ascii.Rgba8 {
    const r: u8 = @intFromFloat((@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1))) * 255.0);
    const g: u8 = @intFromFloat((@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height - 1))) * 255.0);
    return .{ .r = r, .g = g, .b = 180, .a = 255 };
}

fn checkerboardPixel(x: u32, y: u32) ascii.Rgba8 {
    const on = ((x / 6) + (y / 3)) % 2 == 0;
    return if (on)
        .{ .r = 245, .g = 245, .b = 245, .a = 255 }
    else
        .{ .r = 20, .g = 20, .b = 20, .a = 255 };
}

fn colorBarPixel(x: u32, width: u32) ascii.Rgba8 {
    const bar = (x * 6) / width;
    return switch (bar) {
        0 => .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        1 => .{ .r = 255, .g = 255, .b = 0, .a = 255 },
        2 => .{ .r = 0, .g = 255, .b = 0, .a = 255 },
        3 => .{ .r = 0, .g = 255, .b = 255, .a = 255 },
        4 => .{ .r = 0, .g = 0, .b = 255, .a = 255 },
        else => .{ .r = 255, .g = 0, .b = 255, .a = 255 },
    };
}

fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn describeCliError(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingValue => "expected a value after the previous flag",
        error.InvalidSynthetic => "synthetic input must be gradient, checkerboard, or color-bars",
        error.InvalidMode => "mode must be density, partition, braille, glyph-tone, or glyph-structure",
        error.InvalidPartition => "partition must be density, half, or quadrant",
        error.InvalidColor => "color must be none, 16, 256, or truecolor",
        error.InvalidFit => "fit must be contain, cover, or stretch",
        error.InvalidDither => "dither must be none, ordered-2x2, or ordered-4x4",
        error.InvalidDimension => "width and height must be positive integers",
        error.UnknownArgument => "unknown argument",
        error.UnexpectedArgument => "unexpected extra argument",
        error.MissingInput => "expected a path to a .mmd file",
        error.MermaidSyntax => "mermaid source has a syntax error",
        error.InvalidOverflow => "overflow must be allow, clip, or error",
        error.DiagramTooLarge => "diagram exceeds the requested bounds",
        image_loader.DecodeError.UnsupportedFormat => "input file must be P3/P6 PPM, P7 PAM, PNG, or JPEG",
        image_loader.DecodeError.UnsupportedPixelFormat => "decoded image has an unsupported pixel format",
        image_loader.DecodeError.ImageTooLarge => "decoded image dimensions are too large",
        error.InvalidHeader => "input image header is invalid",
        error.InvalidDimensions => "input image dimensions are invalid",
        error.InvalidMaxValue => "input image max value must be 255",
        error.InvalidRaster => "input image raster data is invalid or incomplete",
        error.FileNotFound => "input file was not found",
        error.StreamTooLong => "input file is too large",
        ascii.Error.UnsupportedColorMode => "ANSI 16 and 256 color output are not implemented yet; use none or truecolor",
        ascii.Error.UnsupportedRenderMode => "requested renderer is not implemented or not supported by the selected symbols",
        else => @errorName(err),
    };
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage: cell-render [options]
        \\       cell-render mermaid <file.mmd> [--ascii|--unicode] [--color none|truecolor]
        \\                                      [--width N --height N | --max-width N --max-height N]
        \\                                      [--overflow allow|clip|error]
        \\
        \\options:
        \\  --input path.ppm|path.pam|path.png|path.jpg|path.jpeg
        \\  --synthetic gradient|checkerboard|color-bars
        \\  --width N
        \\  --height N
        \\  --mode density|partition|braille|glyph-tone|glyph-structure
        \\  --partition density|half|quadrant
        \\  --color none|16|256|truecolor
        \\  --fit contain|cover|stretch
        \\  --dither none|ordered-2x2|ordered-4x4
        \\  --invert
        \\  --help
        \\
        \\If --input is omitted, a synthetic gradient is rendered.
        \\
    );
}

test "library import is available to cli" {
    try std.testing.expectEqual(ascii.ColorMode.truecolor, ascii.ColorMode.truecolor);
}

test "parse minimal cli options" {
    const args = [_][]const u8{
        "cell-render",
        "--synthetic",
        "checkerboard",
        "--width",
        "12",
        "--height",
        "6",
        "--mode",
        "density",
        "--color",
        "none",
        "--dither",
        "ordered-2x2",
    };
    const options = try parseArgs(&args);
    try std.testing.expectEqual(Synthetic.checkerboard, options.synthetic);
    try std.testing.expectEqual(@as(u32, 12), options.width);
    try std.testing.expectEqual(@as(u32, 6), options.height);
    try std.testing.expectEqual(ascii.RenderMode.density, options.mode);
    try std.testing.expectEqual(ascii.ColorMode.none, options.color);
    try std.testing.expectEqual(ascii.DitherMode.ordered_2x2, options.dither);
}

test "CLI density gradient golden output" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const image = try makeSynthetic(arena_state.allocator(), .gradient, 96, 48);
    try renderImage(&writer, arena_state.allocator(), image, .{
        .synthetic = .gradient,
        .width = 4,
        .height = 2,
        .mode = .density,
        .color = .none,
    });

    try std.testing.expectEqualStrings("--=+\n**##\n", writer.buffered());
}

test "CLI checkerboard quadrant golden output" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const image = try makeSynthetic(arena_state.allocator(), .checkerboard, 96, 48);
    try renderImage(&writer, arena_state.allocator(), image, .{
        .synthetic = .checkerboard,
        .width = 4,
        .height = 2,
        .mode = .partition,
        .partition = .quadrant_2x2,
        .color = .none,
        .dither = .ordered_2x2,
    });

    try std.testing.expectEqualStrings("▜▜▜▜\n▜▜▜▜\n", writer.buffered());
}

test "CLI checkerboard Braille golden output" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const image = try makeSynthetic(arena_state.allocator(), .checkerboard, 96, 48);
    try renderImage(&writer, arena_state.allocator(), image, .{
        .synthetic = .checkerboard,
        .width = 4,
        .height = 2,
        .mode = .braille,
        .color = .none,
        .dither = .ordered_4x4,
    });

    try std.testing.expectEqualStrings("⢝⢽⢝⢽\n⢝⢽⢝⢽\n", writer.buffered());
}

test "CLI accepts ansi color flags even though core rejects them for now" {
    const args = [_][]const u8{
        "cell-render",
        "--color",
        "256",
    };
    const options = try parseArgs(&args);
    try std.testing.expectEqual(ascii.ColorMode.ansi256, options.color);
}

test "CLI parses input path" {
    const args = [_][]const u8{
        "cell-render",
        "--input",
        "testdata/diagonal.ppm",
    };
    const options = try parseArgs(&args);
    try std.testing.expectEqualStrings("testdata/diagonal.ppm", options.input_path.?);
}

test "parse mermaid cli options" {
    const args = [_][]const u8{ "diagram.mmd", "--ascii", "--color", "none" };
    const options = try parseMermaidArgs(&args);
    try std.testing.expectEqualStrings("diagram.mmd", options.input_path.?);
    try std.testing.expectEqual(ascii.GlyphSet.ascii, options.glyph_set);
    try std.testing.expectEqual(ascii.ColorMode.none, options.color);
}

test "mermaid rejects a second positional argument" {
    const args = [_][]const u8{ "a.mmd", "b.mmd" };
    try std.testing.expectError(error.UnexpectedArgument, parseMermaidArgs(&args));
}

test "CLI mermaid renders a flowchart fixture" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var threaded = std.Io.Threaded.init_single_threaded;

    const sub_args = [_][]const u8{ "testdata/mermaid/flowchart/basic_lr.mmd", "--ascii", "--color", "none" };
    try runMermaid(&out, &err, threaded.io(), arena_state.allocator(), &sub_args);

    const text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "+-") != null); // box corners
    try std.testing.expect(std.mem.indexOf(u8, text, ">") != null); // arrow head
    try std.testing.expect(std.mem.indexOf(u8, text, "Start") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "End") != null);
}

fn renderForViewportTest(allocator: std.mem.Allocator, src: []const u8) !ascii.Frame {
    var diag: ?ascii.MermaidError = null;
    return ascii.renderMermaid(allocator, src, .{ .glyph_set = .ascii, .color = .none }, &diag);
}

/// Assert `text` (newline-terminated rows from a no-color frame) is exactly
/// `cols` x `rows`.
fn expectGrid(text: []const u8, cols: usize, rows: usize) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        if (n == rows) {
            try std.testing.expectEqual(@as(usize, 0), line.len); // trailing split
            break;
        }
        try std.testing.expectEqual(cols, line.len);
        n += 1;
    }
    try std.testing.expectEqual(rows, n);
}

test "mermaid emit renders natural size with no bounds" {
    var frame = try renderForViewportTest(std.testing.allocator, "flowchart LR\n A --> B\n");
    defer frame.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try emitMermaidFrame(&out, &err, frame, .{}, "x.mmd");
    try expectGrid(out.buffered(), frame.columns, frame.rows);
}

test "mermaid emit clips to a bounded pane" {
    var frame = try renderForViewportTest(std.testing.allocator, "flowchart TD\n A --> B --> C\n");
    defer frame.deinit(std.testing.allocator);
    try std.testing.expect(frame.rows > 4); // ensure clipping actually happens

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try emitMermaidFrame(&out, &err, frame, .{ .width = 5, .height = 4, .overflow = .clip }, "x.mmd");
    try expectGrid(out.buffered(), 5, 4);
}

test "mermaid emit pads up to an exact pane" {
    var frame = try renderForViewportTest(std.testing.allocator, "flowchart LR\n A --> B\n");
    defer frame.deinit(std.testing.allocator);

    var out_buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try emitMermaidFrame(&out, &err, frame, .{ .width = frame.columns + 5, .height = frame.rows + 2, .overflow = .clip }, "x.mmd");
    try expectGrid(out.buffered(), frame.columns + 5, frame.rows + 2);
}

test "mermaid emit errors when the diagram exceeds error bounds" {
    var frame = try renderForViewportTest(std.testing.allocator, "flowchart TD\n A --> B --> C\n");
    defer frame.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    const result = emitMermaidFrame(&out, &err, frame, .{ .max_width = 4, .max_height = 4, .overflow = .error_if_too_large }, "x.mmd");
    try std.testing.expectError(error.DiagramTooLarge, result);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "exceeds") != null);
}

test "parse mermaid viewport flags" {
    const args = [_][]const u8{ "d.mmd", "--width", "100", "--height", "30", "--overflow", "clip" };
    const options = try parseMermaidArgs(&args);
    try std.testing.expectEqual(@as(?u32, 100), options.width);
    try std.testing.expectEqual(@as(?u32, 30), options.height);
    try std.testing.expectEqual(ascii.OverflowMode.clip, options.overflow);
}

test "CLI fixture density golden output" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var threaded = std.Io.Threaded.init_single_threaded;
    try renderSelected(&writer, threaded.io(), arena_state.allocator(), .{
        .input_path = "testdata/diagonal.ppm",
        .width = 1,
        .height = 1,
        .mode = .partition,
        .partition = .quadrant_2x2,
        .color = .none,
        .fit = .stretch,
    });

    try std.testing.expectEqualStrings("▚\n", writer.buffered());
}
