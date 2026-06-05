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
//!   zig build compare -- --corpus testdata/corpus --out bench/results/quality-corpus.json

const std = @import("std");
const builtin = @import("builtin");
const ascii = @import("image_to_ascii");
const ppm = @import("ppm_support");

const common = @import("common.zig");
const metrics = @import("metrics.zig");
const reconstruct = @import("reconstruct.zig");

const default_input = "testdata/color-bars.ppm";
const default_slash_input = "testdata/slash-line.ppm";

const Options = struct {
    input_path: ?[]const u8 = null,
    corpus_path: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
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

const CorpusCase = struct {
    name: []const u8,
    file: []const u8,
    width: u32,
    height: u32,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind = .density_1x1,
    color: ascii.ColorMode = .none,
    fit: ascii.FitMode = .stretch,
    dither: ascii.DitherMode = .none,
    stat: ascii.ColorStat = .trimmed_mean,
    strategy: ascii.SampleStrategy = .auto,
    min_psnr_db: f64,
    min_ssim: f64,
    min_edge_correlation: f64,
    slash_golden: bool = false,
};

const QualityResult = struct {
    fixture_name: []const u8,
    input_path: []const u8,
    image_width: u32,
    image_height: u32,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind,
    color: ascii.ColorMode,
    sampler_policy: ascii.SamplerPolicy,
    output_columns: u32,
    output_rows: u32,
    compare_width: u32,
    compare_height: u32,
    mse: f64,
    psnr_db: f64,
    ssim: f64,
    edge_correlation: f64,
    slash_golden: bool,
    slash_golden_pass: bool,
    observed_codepoint: u21,
};

const corpus_cases = [_]CorpusCase{
    .{ .name = "slash-glyph-structure", .file = "slash-line.ppm", .width = 1, .height = 1, .mode = .glyph_structure, .min_psnr_db = 3.0, .min_ssim = 0.01, .min_edge_correlation = 0.01, .slash_golden = true },
    .{ .name = "checkerboard-braille", .file = "checkerboard.ppm", .width = 7, .height = 3, .mode = .braille, .partition = .octant_2x4, .dither = .ordered_4x4, .min_psnr_db = 3.0, .min_ssim = 0.01, .min_edge_correlation = 0.01 },
    .{ .name = "thin-lines-quadrant", .file = "thin-lines.ppm", .width = 8, .height = 8, .mode = .partition, .partition = .quadrant_2x2, .min_psnr_db = 1.0, .min_ssim = 0.001, .min_edge_correlation = 0.5 },
    .{ .name = "gradient-density", .file = "grayscale-gradient.ppm", .width = 16, .height = 8, .mode = .density, .min_psnr_db = 3.0, .min_ssim = 0.01, .min_edge_correlation = 0.0 },
    .{ .name = "color-bars-half-truecolor", .file = "color-bars.ppm", .width = 13, .height = 5, .mode = .partition, .partition = .half_1x2, .color = .truecolor, .min_psnr_db = 3.0, .min_ssim = 0.01, .min_edge_correlation = 0.01 },
    .{ .name = "shape-glyph-tone", .file = "shape-edge.ppm", .width = 16, .height = 8, .mode = .glyph_tone, .min_psnr_db = 3.0, .min_ssim = 0.01, .min_edge_correlation = 0.01 },
    .{ .name = "low-contrast-glyph-structure", .file = "low-contrast-edge.ppm", .width = 8, .height = 4, .mode = .glyph_structure, .min_psnr_db = 6.0, .min_ssim = 0.001, .min_edge_correlation = -0.1 },
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
    if (options.corpus_path) |path| {
        try runCorpus(writer, io, allocator, path, options.out_path);
        return;
    }

    if (options.input_path) |path| {
        const result = try evaluatePath(allocator, io, path, options);
        try writeHumanReport(writer, result, options, path);
        try writeSingleArtifacts(writer, io, allocator, options, path);
        return;
    }

    try runDefaultSmoke(writer, io, allocator, options);
}

fn runDefaultSmoke(writer: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    var color_options = options;
    color_options.input_path = default_input;
    const color_result = try evaluatePath(allocator, io, default_input, color_options);
    try writeHumanReport(writer, color_result, color_options, default_input);

    var slash_options = options;
    slash_options.input_path = default_slash_input;
    slash_options.width = 1;
    slash_options.height = 1;
    slash_options.mode = .glyph_structure;
    slash_options.partition = .density_1x1;
    slash_options.color = .none;
    slash_options.fit = .stretch;
    const slash_result = try evaluatePath(allocator, io, default_slash_input, slash_options);
    if (!slash_result.slash_golden_pass) return error.SlashGoldenFailed;
    try writer.print("slash golden : {u}\n", .{slash_result.observed_codepoint});
}

fn evaluatePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
) !QualityResult {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    const image = try ppm.decode(allocator, bytes);

    const terminal = ascii.TerminalProfile{
        .columns = options.width,
        .rows = options.height,
        .color = options.color,
        .symbols = symbolsForMode(options.mode),
    };
    const render_options = ascii.Options{
        .mode = options.mode,
        .partition = options.partition,
        .fit = options.fit,
        .dither = options.dither,
        .color_stat = options.stat,
        .sample_strategy = options.strategy,
    };
    const sampler_policy = ascii.resolveSamplerPolicy(render_options, terminal, false);

    var frame = try ascii.renderToCells(allocator, image, terminal, render_options);
    defer frame.deinit(allocator);

    var recon = try reconstruct.reconstructForMode(allocator, frame, options.mode);
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

    const observed = if (frame.codepoints.len > 0) frame.codepoints[0] else 0;
    return .{
        .fixture_name = path,
        .input_path = path,
        .image_width = image.width,
        .image_height = image.height,
        .mode = options.mode,
        .partition = options.partition,
        .color = options.color,
        .sampler_policy = sampler_policy,
        .output_columns = frame.columns,
        .output_rows = frame.rows,
        .compare_width = report.width,
        .compare_height = report.height,
        .mse = report.mse,
        .psnr_db = report.psnr_db,
        .ssim = report.ssim,
        .edge_correlation = report.edge_correlation,
        .slash_golden = options.mode == .glyph_structure and options.width == 1 and options.height == 1,
        .slash_golden_pass = observed == '/',
        .observed_codepoint = observed,
    };
}

fn writeHumanReport(writer: *std.Io.Writer, result: QualityResult, options: Options, path: []const u8) !void {
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
        path,                   result.image_width,          result.image_height,
        @tagName(options.mode), @tagName(options.partition), @tagName(options.color),
        @tagName(options.fit),  @tagName(options.dither),    @tagName(options.stat),
        result.output_columns,  result.output_rows,          result.compare_width,
        result.compare_height,  result.mse,                  result.psnr_db,
        result.ssim,            result.edge_correlation,
    });
}

fn writeSingleArtifacts(
    writer: *std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    path: []const u8,
) !void {
    if (options.write_recon == null and options.write_ref == null) return;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    const image = try ppm.decode(allocator, bytes);
    const terminal = ascii.TerminalProfile{
        .columns = options.width,
        .rows = options.height,
        .color = options.color,
        .symbols = symbolsForMode(options.mode),
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
    var recon = try reconstruct.reconstructForMode(allocator, frame, options.mode);
    defer recon.deinit(allocator);
    const background = common.Rgb{
        .r = terminal.background.r,
        .g = terminal.background.g,
        .b = terminal.background.b,
    };
    const crop = common.cropRectFor(image, terminal, options.fit);
    var reference = try common.resizeReference(allocator, image, background, crop, recon.width, recon.height);
    defer reference.deinit(allocator);

    if (options.write_recon) |p| {
        try common.writePpm(io, allocator, p, recon);
        try writer.print("wrote reconstruction -> {s}\n", .{p});
    }
    if (options.write_ref) |p| {
        try common.writePpm(io, allocator, p, reference);
        try writer.print("wrote reference      -> {s}\n", .{p});
    }
}

fn runCorpus(
    writer: *std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    out_path: ?[]const u8,
) !void {
    var results: [corpus_cases.len]QualityResult = undefined;
    var failures: usize = 0;

    for (corpus_cases, 0..) |case, idx| {
        const path = try std.fs.path.join(allocator, &.{ corpus_path, case.file });
        const options = optionsForCase(case);
        var result = try evaluatePath(allocator, io, path, options);
        result.fixture_name = case.name;
        results[idx] = result;

        const passed = validateCorpusResult(result, case);
        if (!passed) {
            failures += 1;
            try writeThresholdFailure(writer, result, case);
        }

        try writer.print(
            "{s}: mode={s} color={s} policy={s} psnr={d:.3} ssim={d:.4} edge={d:.4} slash={s}\n",
            .{
                case.name,
                @tagName(result.mode),
                @tagName(result.color),
                @tagName(result.sampler_policy),
                result.psnr_db,
                result.ssim,
                result.edge_correlation,
                if (!case.slash_golden) "n/a" else if (result.slash_golden_pass) "pass" else "fail",
            },
        );
    }

    if (out_path) |path| {
        try writeCorpusJson(io, path, results[0..]);
        try writer.print("wrote quality corpus -> {s}\n", .{path});
    }

    if (failures > 0) return error.QualityThresholdFailed;
}

fn optionsForCase(case: CorpusCase) Options {
    return .{
        .width = case.width,
        .height = case.height,
        .mode = case.mode,
        .partition = case.partition,
        .color = case.color,
        .fit = case.fit,
        .dither = case.dither,
        .stat = case.stat,
        .strategy = case.strategy,
    };
}

fn symbolsForMode(mode: ascii.RenderMode) ascii.TerminalSymbols {
    return switch (mode) {
        .braille => .braille,
        .glyph_tone, .glyph_structure => .glyphs,
        else => .block_basic,
    };
}

fn validateCorpusResult(result: QualityResult, case: CorpusCase) bool {
    if (!std.math.isFinite(result.mse)) return false;
    if (!std.math.isFinite(result.psnr_db)) return false;
    if (!std.math.isFinite(result.ssim)) return false;
    if (!std.math.isFinite(result.edge_correlation)) return false;
    if (case.slash_golden and !result.slash_golden_pass) return false;
    if (result.psnr_db < case.min_psnr_db) return false;
    if (result.ssim < case.min_ssim) return false;
    if (result.edge_correlation < case.min_edge_correlation) return false;
    return true;
}

fn writeThresholdFailure(writer: *std.Io.Writer, result: QualityResult, case: CorpusCase) !void {
    if (!std.math.isFinite(result.mse)) try writer.print("  fail: {s} mse is not finite\n", .{case.name});
    if (!std.math.isFinite(result.psnr_db)) try writer.print("  fail: {s} psnr is not finite\n", .{case.name});
    if (!std.math.isFinite(result.ssim)) try writer.print("  fail: {s} ssim is not finite\n", .{case.name});
    if (!std.math.isFinite(result.edge_correlation)) try writer.print("  fail: {s} edge correlation is not finite\n", .{case.name});
    if (case.slash_golden and !result.slash_golden_pass) {
        try writer.print("  fail: {s} expected slash '/' but observed codepoint {d}\n", .{ case.name, result.observed_codepoint });
    }
    if (result.psnr_db < case.min_psnr_db) {
        try writer.print("  fail: {s} psnr {d:.3} below {d:.3}\n", .{ case.name, result.psnr_db, case.min_psnr_db });
    }
    if (result.ssim < case.min_ssim) {
        try writer.print("  fail: {s} ssim {d:.4} below {d:.4}\n", .{ case.name, result.ssim, case.min_ssim });
    }
    if (result.edge_correlation < case.min_edge_correlation) {
        try writer.print("  fail: {s} edge {d:.4} below {d:.4}\n", .{ case.name, result.edge_correlation, case.min_edge_correlation });
    }
}

fn writeCorpusJson(io: std.Io, out_path: []const u8, results: []const QualityResult) !void {
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.createDirPath(.cwd(), io, dir);
    }

    const file = try std.Io.Dir.createFile(.cwd(), io, out_path, .{ .truncate = true });
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buffer);
    const writer = &file_writer.interface;

    try writer.print(
        \\{{
        \\  "schema_version": 1,
        \\  "zig_version": "{s}",
        \\  "target": {{
        \\    "os": "{s}",
        \\    "cpu_arch": "{s}"
        \\  }},
        \\  "corpus": {{
        \\    "name": "quality-corpus",
        \\    "cases": {d}
        \\  }},
        \\  "results": [
        \\
    , .{
        builtin.zig_version_string,
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.cpu.arch),
        results.len,
    });

    for (results, 0..) |result, idx| {
        if (idx != 0) try writer.writeAll(",\n");
        try writeJsonResult(writer, result);
    }

    try writer.writeAll(
        \\
        \\  ]
        \\}
        \\
    );
    try writer.flush();
}

fn writeJsonResult(writer: *std.Io.Writer, result: QualityResult) !void {
    try writer.print(
        \\    {{
        \\      "fixture_name": "{s}",
        \\      "input_path": "{s}",
        \\      "mode": "{s}",
        \\      "partition": "{s}",
        \\      "color_mode": "{s}",
        \\      "sampler_policy": "{s}",
        \\      "output_columns": {d},
        \\      "output_rows": {d},
        \\      "compare_width": {d},
        \\      "compare_height": {d},
        \\      "mse": {d:.6},
        \\      "psnr_db": {d:.6},
        \\      "ssim": {d:.6},
        \\      "edge_correlation": {d:.6},
        \\      "slash_golden": {s},
        \\      "slash_golden_pass": {s},
        \\      "observed_codepoint": {d}
        \\    }}
    , .{
        result.fixture_name,
        result.input_path,
        @tagName(result.mode),
        @tagName(result.partition),
        @tagName(result.color),
        @tagName(result.sampler_policy),
        result.output_columns,
        result.output_rows,
        result.compare_width,
        result.compare_height,
        result.mse,
        result.psnr_db,
        result.ssim,
        result.edge_correlation,
        if (result.slash_golden) "true" else "false",
        if (result.slash_golden_pass) "true" else "false",
        result.observed_codepoint,
    });
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            options.input_path = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            options.corpus_path = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--out")) {
            options.out_path = try value(args, &i);
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
    if (std.mem.eql(u8, v, "glyph-tone")) return .glyph_tone;
    if (std.mem.eql(u8, v, "glyph-structure")) return .glyph_structure;
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
        \\usage: render_compare [--input path.ppm] [options]
        \\       render_compare --corpus testdata/corpus --out bench/results/quality-corpus.json
        \\
        \\options:
        \\  --input path.ppm|path.pam   input fixture
        \\  --corpus dir                run checked-in quality corpus fixtures
        \\  --out path.json             write corpus JSON artifact
        \\  --width N                   output columns (default 80)
        \\  --height N                  output rows (default 40)
        \\  --mode density|partition|braille|glyph-tone|glyph-structure
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
