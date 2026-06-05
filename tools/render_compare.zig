//! render_compare: render a PPM/PAM image through the core library, reconstruct
//! an approximate image from the resulting cells, and score it against the
//! source using PSNR / SSIM / edge-correlation.
//!
//! This is the quality harness scaffold described in RESEARCH.md (Milestone 9 /
//! Phase 4). It deliberately works WITHOUT a font rasterizer by reconstructing
//! the block and Braille families from their known masks; glyph modes will plug
//! in here once `calibrate_font.zig` can produce a real atlas.
//!
//! Usage:
//!   zig build compare -- --input testdata/color-bars.ppm --mode partition \
//!       --partition quadrant --color truecolor --fit contain --stat median \
//!       --write-recon out-recon.ppm --write-ref out-ref.ppm

const std = @import("std");
const ascii = @import("image_to_ascii");
const ppm = @import("ppm_support");

const common = @import("common.zig");
const metrics = @import("metrics.zig");
const reconstruct = @import("reconstruct.zig");

const Options = struct {
    input_path: ?[]const u8 = null,
    width: u32 = 80,
    height: u32 = 40,
    mode: ascii.RenderMode = .partition,
    partition: ascii.PartitionKind = .half_1x2,
    color: ascii.ColorMode = .truecolor,
    fit: ascii.FitMode = .contain,
    dither: ascii.DitherMode = .none,
    stat: ascii.ColorStat = .trimmed_mean,
    strategy: ascii.SampleStrategy = .auto,
    write_recon: ?[]const u8 = null,
    write_ref: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (argsContain(args, "--help")) {
        try writeUsage(stdout);
        try stdout.flush();
        return;
    }

    const options = parseArgs(args) catch |err| {
        try stderr.print("error: {s}\n\n", .{@errorName(err)});
        try writeUsage(stderr);
        try stderr.flush();
        return err;
    };

    run(stdout, init.io, arena, options) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.flush();
}

fn run(writer: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    const path = options.input_path orelse return error.MissingInput;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    const image = try ppm.decode(allocator, bytes);

    const terminal = ascii.TerminalProfile{
        .columns = options.width,
        .rows = options.height,
        .color = options.color,
        .symbols = if (options.mode == .braille) .braille else .block_basic,
    };
    const render_options = ascii.Options{
        .mode = options.mode,
        .partition = options.partition,
        .fit = options.fit,
        .dither = options.dither,
        .color_stat = options.stat,
        .sample_strategy = options.strategy,
    };

    var frame = try ascii.renderToCells(allocator, image, terminal, render_options);
    defer frame.deinit(allocator);

    var recon = try reconstruct.reconstruct(allocator, frame);
    defer recon.deinit(allocator);

    const background = common.Rgb{
        .r = terminal.background.r,
        .g = terminal.background.g,
        .b = terminal.background.b,
    };
    const crop = common.cropRectFor(image, terminal, options.fit);
    var reference = try common.resizeReference(allocator, image, background, crop, recon.width, recon.height);
    defer reference.deinit(allocator);

    const report = try metrics.compare(allocator, reference, recon);

    try writer.print(
        \\source        : {s} ({d}x{d})
        \\render        : mode={s} partition={s} color={s} fit={s} dither={s} stat={s}
        \\output cells  : {d}x{d}
        \\compare res   : {d}x{d}
        \\MSE           : {d:.3}
        \\PSNR          : {d:.3} dB
        \\SSIM          : {d:.4}
        \\edge corr.    : {d:.4}
        \\
    , .{
        path,                   image.width,                 image.height,
        @tagName(options.mode), @tagName(options.partition), @tagName(options.color),
        @tagName(options.fit),  @tagName(options.dither),    @tagName(options.stat),
        frame.columns,          frame.rows,                  report.width,
        report.height,          report.mse,                  report.psnr_db,
        report.ssim,            report.edge_correlation,
    });

    if (options.write_recon) |p| {
        try common.writePpm(io, allocator, p, recon);
        try writer.print("wrote reconstruction -> {s}\n", .{p});
    }
    if (options.write_ref) |p| {
        try common.writePpm(io, allocator, p, reference);
        try writer.print("wrote reference      -> {s}\n", .{p});
    }
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            options.input_path = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try parsePositive(try value(args, &i));
        } else if (std.mem.eql(u8, arg, "--height")) {
            options.height = try parsePositive(try value(args, &i));
        } else if (std.mem.eql(u8, arg, "--mode")) {
            options.mode = parseMode(try value(args, &i)) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, arg, "--partition")) {
            options.partition = parsePartition(try value(args, &i)) orelse return error.InvalidPartition;
        } else if (std.mem.eql(u8, arg, "--color")) {
            options.color = parseColor(try value(args, &i)) orelse return error.InvalidColor;
        } else if (std.mem.eql(u8, arg, "--fit")) {
            options.fit = parseFit(try value(args, &i)) orelse return error.InvalidFit;
        } else if (std.mem.eql(u8, arg, "--dither")) {
            options.dither = parseDither(try value(args, &i)) orelse return error.InvalidDither;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            options.stat = parseStat(try value(args, &i)) orelse return error.InvalidStat;
        } else if (std.mem.eql(u8, arg, "--strategy")) {
            options.strategy = parseStrategy(try value(args, &i)) orelse return error.InvalidStrategy;
        } else if (std.mem.eql(u8, arg, "--write-recon")) {
            options.write_recon = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--write-ref")) {
            options.write_ref = try value(args, &i);
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn value(args: []const []const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

fn parsePositive(v: []const u8) !u32 {
    const parsed = try std.fmt.parseInt(u32, v, 10);
    if (parsed == 0) return error.InvalidDimension;
    return parsed;
}

fn parseMode(v: []const u8) ?ascii.RenderMode {
    if (std.mem.eql(u8, v, "density")) return .density;
    if (std.mem.eql(u8, v, "partition")) return .partition;
    if (std.mem.eql(u8, v, "braille")) return .braille;
    return null;
}

fn parsePartition(v: []const u8) ?ascii.PartitionKind {
    if (std.mem.eql(u8, v, "density")) return .density_1x1;
    if (std.mem.eql(u8, v, "half")) return .half_1x2;
    if (std.mem.eql(u8, v, "quadrant")) return .quadrant_2x2;
    return null;
}

fn parseColor(v: []const u8) ?ascii.ColorMode {
    if (std.mem.eql(u8, v, "none")) return .none;
    if (std.mem.eql(u8, v, "truecolor")) return .truecolor;
    return null;
}

fn parseFit(v: []const u8) ?ascii.FitMode {
    if (std.mem.eql(u8, v, "contain")) return .contain;
    if (std.mem.eql(u8, v, "cover")) return .cover;
    if (std.mem.eql(u8, v, "stretch")) return .stretch;
    return null;
}

fn parseDither(v: []const u8) ?ascii.DitherMode {
    if (std.mem.eql(u8, v, "none")) return .none;
    if (std.mem.eql(u8, v, "ordered-2x2")) return .ordered_2x2;
    if (std.mem.eql(u8, v, "ordered-4x4")) return .ordered_4x4;
    return null;
}

fn parseStat(v: []const u8) ?ascii.ColorStat {
    if (std.mem.eql(u8, v, "mean")) return .mean;
    if (std.mem.eql(u8, v, "trimmed")) return .trimmed_mean;
    if (std.mem.eql(u8, v, "median")) return .median;
    return null;
}

fn parseStrategy(v: []const u8) ?ascii.SampleStrategy {
    if (std.mem.eql(u8, v, "auto")) return .auto;
    if (std.mem.eql(u8, v, "direct")) return .direct_box;
    if (std.mem.eql(u8, v, "integral")) return .integral_luma;
    return null;
}

fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage: render_compare --input path.ppm [options]
        \\
        \\options:
        \\  --input path.ppm|path.pam   (required)
        \\  --width N                   output columns (default 80)
        \\  --height N                  output rows (default 40)
        \\  --mode density|partition|braille
        \\  --partition density|half|quadrant
        \\  --color none|truecolor
        \\  --fit contain|cover|stretch
        \\  --dither none|ordered-2x2|ordered-4x4
        \\  --stat mean|trimmed|median  representative-color policy
        \\  --strategy auto|direct|integral  sampler (integral = monochrome SAT)
        \\  --write-recon out.ppm       write the reconstructed image
        \\  --write-ref out.ppm         write the resized reference image
        \\  --help
        \\
    );
}

test "render_compare wiring scores a fixture end to end" {
    const allocator = std.testing.allocator;

    const data =
        \\P3
        \\2 2
        \\255
        \\255 255 255  0 0 0
        \\0 0 0  255 255 255
        \\
    ;
    const image = try ppm.decode(allocator, data);
    defer allocator.free(image.pixels);

    const terminal = ascii.TerminalProfile{ .columns = 1, .rows = 1, .color = .truecolor };
    var frame = try ascii.renderToCells(allocator, image, terminal, .{
        .mode = .partition,
        .partition = .quadrant_2x2,
        .fit = .stretch,
    });
    defer frame.deinit(allocator);

    var recon = try reconstruct.reconstruct(allocator, frame);
    defer recon.deinit(allocator);

    const crop = common.cropRectFor(image, terminal, .stretch);
    var reference = try common.resizeReference(
        allocator,
        image,
        .{ .r = 0, .g = 0, .b = 0 },
        crop,
        recon.width,
        recon.height,
    );
    defer reference.deinit(allocator);

    const report = try metrics.compare(allocator, reference, recon);
    try std.testing.expect(report.psnr_db > 0.0);
    try std.testing.expect(report.ssim <= 1.0);
}
