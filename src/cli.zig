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
        \\usage: image-to-ascii [options]
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
        "image-to-ascii",
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
        "image-to-ascii",
        "--color",
        "256",
    };
    const options = try parseArgs(&args);
    try std.testing.expectEqual(ascii.ColorMode.ansi256, options.color);
}

test "CLI parses input path" {
    const args = [_][]const u8{
        "image-to-ascii",
        "--input",
        "testdata/diagonal.ppm",
    };
    const options = try parseArgs(&args);
    try std.testing.expectEqualStrings("testdata/diagonal.ppm", options.input_path.?);
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
