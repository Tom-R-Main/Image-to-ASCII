const std = @import("std");
const builtin = @import("builtin");
const ascii = @import("image_to_ascii");
const image_loader = @import("image_loader");
const quality_tools = @import("quality_tools");

const common = quality_tools.common;
const metrics = quality_tools.metrics;
const reconstruct = quality_tools.reconstruct;

const Synthetic = enum { gradient, checkerboard, color_mix };
const DiffScenario = enum { none, noop, single_cell, small_run, one_row, full };
const BenchKind = enum {
    render,
    render_prepared,
    render_writer,
    ansi_encode_only,
    quality_compare_only,
    workspace_repeat,
    prepared_workspace_repeat,
    ansi_diff,
    workspace_render_diff_repeat,
    prepared_workspace_render_diff_repeat,
};

const BenchCase = struct {
    name: []const u8,
    kind: BenchKind = .render,
    synthetic: Synthetic = .gradient,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind,
    color: ascii.ColorMode,
    dither: ascii.DitherMode = .none,
    sample_strategy: ascii.SampleStrategy = .auto,
    diff_scenario: DiffScenario = .none,
};

const BenchResult = struct {
    name: []const u8,
    kind: BenchKind,
    synthetic: Synthetic,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind,
    color: ascii.ColorMode,
    dither: ascii.DitherMode,
    sample_strategy: ascii.SampleStrategy,
    sampler_policy: ascii.SamplerPolicy,
    input_width: u32,
    input_height: u32,
    output_columns: u32,
    output_rows: u32,
    iterations: u64,
    ns_per_iter: u64,
    median_ns: u64,
    p95_ns: u64,
    ns_per_cell: u64,
    cells_per_sec: u64,
    allocated_bytes: u64,
    allocations_first_render: usize = 0,
    allocations_steady_state: usize = 0,
    bytes_allocated_first_render: usize = 0,
    bytes_allocated_steady_state: usize = 0,
    cells_changed: usize = 0,
    runs_emitted: usize = 0,
    ansi_bytes: u64,
};

const cases = [_]BenchCase{
    .{ .name = "density-none", .mode = .density, .partition = .density_1x1, .color = .none },
    .{ .name = "density-truecolor", .mode = .density, .partition = .density_1x1, .color = .truecolor },
    .{ .name = "half-truecolor", .mode = .partition, .partition = .half_1x2, .color = .truecolor },
    .{ .name = "quadrant-none", .mode = .partition, .partition = .quadrant_2x2, .color = .none },
    .{ .name = "quadrant-truecolor", .synthetic = .color_mix, .mode = .partition, .partition = .quadrant_2x2, .color = .truecolor },
    .{ .name = "braille-none-dither", .synthetic = .checkerboard, .mode = .braille, .partition = .octant_2x4, .color = .none, .dither = .ordered_4x4 },
    .{ .name = "braille-truecolor", .synthetic = .color_mix, .mode = .braille, .partition = .octant_2x4, .color = .truecolor },
    .{ .name = "glyph-tone-none", .mode = .glyph_tone, .partition = .density_1x1, .color = .none },
    .{ .name = "glyph-tone-truecolor", .mode = .glyph_tone, .partition = .density_1x1, .color = .truecolor },
    .{ .name = "glyph-structure-none", .synthetic = .checkerboard, .mode = .glyph_structure, .partition = .density_1x1, .color = .none },
    .{ .name = "glyph-structure-truecolor", .synthetic = .checkerboard, .mode = .glyph_structure, .partition = .density_1x1, .color = .truecolor },
    .{ .name = "density-integral-none", .mode = .density, .partition = .density_1x1, .color = .none, .sample_strategy = .integral_luma },
    .{ .name = "prepared-density-integral-none", .kind = .render_prepared, .mode = .density, .partition = .density_1x1, .color = .none, .sample_strategy = .integral_luma },
    .{ .name = "render-writer-half-truecolor", .kind = .render_writer, .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor },
    .{ .name = "ansi-encode-only", .kind = .ansi_encode_only, .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor },
    .{ .name = "quality-compare-only", .kind = .quality_compare_only, .mode = .density, .partition = .density_1x1, .color = .none },
    .{ .name = "workspace-density-none-repeat", .kind = .workspace_repeat, .mode = .density, .partition = .density_1x1, .color = .none },
    .{ .name = "workspace-density-truecolor-repeat", .kind = .workspace_repeat, .mode = .density, .partition = .density_1x1, .color = .truecolor },
    .{ .name = "workspace-half-truecolor-repeat", .kind = .workspace_repeat, .mode = .partition, .partition = .half_1x2, .color = .truecolor },
    .{ .name = "workspace-glyph-structure-none-repeat", .kind = .workspace_repeat, .synthetic = .checkerboard, .mode = .glyph_structure, .partition = .density_1x1, .color = .none },
    .{ .name = "workspace-glyph-structure-truecolor-repeat", .kind = .workspace_repeat, .synthetic = .checkerboard, .mode = .glyph_structure, .partition = .density_1x1, .color = .truecolor },
    .{ .name = "prepared-workspace-density-integral-repeat", .kind = .prepared_workspace_repeat, .mode = .density, .partition = .density_1x1, .color = .none, .sample_strategy = .integral_luma },
    .{ .name = "ansi-diff-noop", .kind = .ansi_diff, .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor, .diff_scenario = .noop },
    .{ .name = "ansi-diff-single-cell-change", .kind = .ansi_diff, .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor, .diff_scenario = .single_cell },
    .{ .name = "ansi-diff-small-run-change", .kind = .ansi_diff, .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor, .diff_scenario = .small_run },
    .{ .name = "ansi-diff-one-row-change", .kind = .ansi_diff, .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor, .diff_scenario = .one_row },
    .{ .name = "ansi-diff-full-change", .kind = .ansi_diff, .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor, .diff_scenario = .full },
    .{ .name = "workspace-render-plus-diff-repeat", .kind = .workspace_render_diff_repeat, .mode = .density, .partition = .density_1x1, .color = .truecolor },
    .{ .name = "prepared-workspace-render-plus-diff-repeat", .kind = .prepared_workspace_render_diff_repeat, .mode = .density, .partition = .density_1x1, .color = .none, .sample_strategy = .integral_luma },
};

const in_w = 400;
const in_h = 240;
const out_w = 80;
const out_h = 30;
const iterations: u64 = 200;

const Args = struct {
    out_path: ?[]const u8 = null,
};

const RealImageSmokeCase = struct {
    name: []const u8,
    path: []const u8,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind = .density_1x1,
    color: ascii.ColorMode = .none,
    fit: ascii.FitMode = .contain,
    dither: ascii.DitherMode = .none,
    width: u32 = 80,
    height: u32 = 24,
};

const RealImageSmokeResult = struct {
    name: []const u8,
    path: []const u8,
    adapter: image_loader.Adapter,
    format: image_loader.Format,
    decoded_pixel_format: []const u8,
    decoded_width: u32,
    decoded_height: u32,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind,
    color: ascii.ColorMode,
    sampler_policy: ascii.SamplerPolicy,
    output_columns: u32,
    output_rows: u32,
    psnr_db: f64,
    ssim: f64,
    edge_correlation: f64,
    status: []const u8,
};

const real_image_smoke_cases = [_]RealImageSmokeCase{
    .{ .name = "gradient-png-density", .path = "testdata/real/gradient.png", .mode = .density, .color = .none },
    .{ .name = "line-art-png-glyph-structure", .path = "testdata/real/line-art.png", .mode = .glyph_structure, .color = .none },
    .{ .name = "photo-jpeg-half-truecolor", .path = "testdata/real/photo-small.jpg", .mode = .partition, .partition = .half_1x2, .color = .truecolor },
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = parseArgs(init.minimal.args);

    const gradient = try makeImage(allocator, .gradient, in_w, in_h);
    defer allocator.free(gradient.pixels);
    const checkerboard = try makeImage(allocator, .checkerboard, in_w, in_h);
    defer allocator.free(checkerboard.pixels);
    const color_mix = try makeImage(allocator, .color_mix, in_w, in_h);
    defer allocator.free(color_mix.pixels);

    const ansi_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(ansi_buf);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var results: [cases.len]BenchResult = undefined;

    try stdout.writeAll("case,policy,input,output,iters,ns_per_iter,median_ns,p95_ns,ns_per_cell,cells_per_sec,allocated_bytes,allocs_first,allocs_steady,bytes_first,bytes_steady,cells_changed,runs_emitted,ansi_bytes\n");
    for (cases, 0..) |bench_case, idx| {
        const image = switch (bench_case.synthetic) {
            .gradient => gradient,
            .checkerboard => checkerboard,
            .color_mix => color_mix,
        };
        results[idx] = try runCase(init.io, allocator, image, ansi_buf, bench_case);
        try writeCsvRow(stdout, results[idx]);
    }
    try stdout.flush();

    if (args.out_path) |path| {
        if (std.mem.eql(u8, std.fs.path.basename(path), "real-image-smoke.json")) {
            try writeRealImageSmokeJson(init.io, allocator, path);
        } else {
            try writeJsonResults(init.io, path, results[0..]);
        }
    }
}

fn parseArgs(process_args: std.process.Args) Args {
    var parsed = Args{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.next();

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            parsed.out_path = it.next() orelse std.debug.panic("missing path after --out", .{});
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            parsed.out_path = arg["--out=".len..];
        } else {
            std.debug.panic("unknown benchmark argument: {s}", .{arg});
        }
    }

    return parsed;
}

fn runCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: ascii.ImageView,
    ansi_buf: []u8,
    bench_case: BenchCase,
) !BenchResult {
    const terminal = ascii.TerminalProfile{
        .columns = out_w,
        .rows = out_h,
        .color = bench_case.color,
        .symbols = if (bench_case.mode == .braille) .braille else if (bench_case.mode == .glyph_structure) .glyphs else .block_basic,
    };
    const options = ascii.Options{
        .mode = bench_case.mode,
        .partition = bench_case.partition,
        .fit = .stretch,
        .dither = bench_case.dither,
        .sample_strategy = bench_case.sample_strategy,
    };

    if (bench_case.kind == .workspace_repeat or bench_case.kind == .prepared_workspace_repeat) {
        return runWorkspaceCase(io, allocator, image, terminal, options, bench_case);
    }
    if (bench_case.kind == .ansi_diff) {
        return runAnsiDiffCase(io, allocator, image, terminal, options, ansi_buf, bench_case);
    }
    if (bench_case.kind == .workspace_render_diff_repeat or bench_case.kind == .prepared_workspace_render_diff_repeat) {
        return runWorkspaceDiffCase(io, allocator, image, terminal, options, ansi_buf, bench_case);
    }

    var prepared: ?ascii.PreparedImage = null;
    defer if (prepared) |*p| p.deinit(allocator);
    if (bench_case.kind == .render_prepared) {
        prepared = try ascii.prepareImage(allocator, image, terminal, .{ .sample_strategy = bench_case.sample_strategy });
    }
    const prepared_integral = if (prepared) |p| p.luma_sat != null else false;
    const sampler_policy = ascii.resolveSamplerPolicy(options, terminal, prepared_integral);

    var pre_frame: ?ascii.Frame = null;
    defer if (pre_frame) |*frame| frame.deinit(allocator);
    if (bench_case.kind == .ansi_encode_only or bench_case.kind == .quality_compare_only) {
        pre_frame = try ascii.renderToCells(allocator, image, terminal, options);
    }

    var bytes: u64 = try runOnce(allocator, image, terminal, options, ansi_buf, bench_case.kind, if (prepared) |*p| p else null, if (pre_frame) |*f| f else null);

    var timings: [iterations]u64 = undefined;
    var total_ns: u64 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        bytes = try runOnce(allocator, image, terminal, options, ansi_buf, bench_case.kind, if (prepared) |*p| p else null, if (pre_frame) |*f| f else null);
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const elapsed: u64 = @intCast(end - start);
        timings[@intCast(i)] = elapsed;
        total_ns += elapsed;
    }

    insertionSortU64(&timings);

    const ns_per_iter = total_ns / iterations;
    const cells = @as(u64, out_w) * out_h;
    return .{
        .name = bench_case.name,
        .kind = bench_case.kind,
        .synthetic = bench_case.synthetic,
        .mode = bench_case.mode,
        .partition = bench_case.partition,
        .color = bench_case.color,
        .dither = bench_case.dither,
        .sample_strategy = bench_case.sample_strategy,
        .sampler_policy = sampler_policy,
        .input_width = in_w,
        .input_height = in_h,
        .output_columns = out_w,
        .output_rows = out_h,
        .iterations = iterations,
        .ns_per_iter = ns_per_iter,
        .median_ns = timings[timings.len / 2],
        .p95_ns = timings[(timings.len * 95 + 99) / 100 - 1],
        .ns_per_cell = ns_per_iter / cells,
        .cells_per_sec = if (ns_per_iter == 0) 0 else (cells * std.time.ns_per_s) / ns_per_iter,
        .allocated_bytes = allocatedBytes(bench_case, out_w, out_h),
        .ansi_bytes = if (bench_case.kind == .render_writer or bench_case.kind == .ansi_encode_only) bytes else 0,
    };
}

fn runAnsiDiffCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: ascii.ImageView,
    terminal: ascii.TerminalProfile,
    options: ascii.Options,
    ansi_buf: []u8,
    bench_case: BenchCase,
) !BenchResult {
    var previous = try ascii.renderToCells(allocator, image, terminal, options);
    defer previous.deinit(allocator);
    var current = try cloneFrame(allocator, previous);
    defer current.deinit(allocator);
    mutateFrameForDiff(&current, bench_case.diff_scenario);

    const sampler_policy = ascii.resolveSamplerPolicy(options, terminal, false);
    var stats = try runFrameDiffOnce(ansi_buf, &previous, &current);

    var timings: [iterations]u64 = undefined;
    var total_ns: u64 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        stats = try runFrameDiffOnce(ansi_buf, &previous, &current);
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const elapsed: u64 = @intCast(end - start);
        timings[@intCast(i)] = elapsed;
        total_ns += elapsed;
    }

    insertionSortU64(&timings);

    const ns_per_iter = total_ns / iterations;
    const cells = @as(u64, out_w) * out_h;
    return .{
        .name = bench_case.name,
        .kind = bench_case.kind,
        .synthetic = bench_case.synthetic,
        .mode = bench_case.mode,
        .partition = bench_case.partition,
        .color = bench_case.color,
        .dither = bench_case.dither,
        .sample_strategy = bench_case.sample_strategy,
        .sampler_policy = sampler_policy,
        .input_width = in_w,
        .input_height = in_h,
        .output_columns = out_w,
        .output_rows = out_h,
        .iterations = iterations,
        .ns_per_iter = ns_per_iter,
        .median_ns = timings[timings.len / 2],
        .p95_ns = timings[(timings.len * 95 + 99) / 100 - 1],
        .ns_per_cell = ns_per_iter / cells,
        .cells_per_sec = if (ns_per_iter == 0) 0 else (cells * std.time.ns_per_s) / ns_per_iter,
        .allocated_bytes = 0,
        .cells_changed = stats.cells_changed,
        .runs_emitted = stats.runs_emitted,
        .ansi_bytes = stats.bytes_emitted,
    };
}

fn runWorkspaceCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: ascii.ImageView,
    terminal: ascii.TerminalProfile,
    options: ascii.Options,
    bench_case: BenchCase,
) !BenchResult {
    var prepared: ?ascii.PreparedImage = null;
    defer if (prepared) |*p| p.deinit(allocator);
    if (bench_case.kind == .prepared_workspace_repeat) {
        prepared = try ascii.prepareImage(allocator, image, terminal, .{ .sample_strategy = bench_case.sample_strategy });
    }

    const prepared_integral = if (prepared) |p| p.luma_sat != null else false;
    const sampler_policy = ascii.resolveSamplerPolicy(options, terminal, prepared_integral);

    var counting = BenchCountingAllocator{ .child = allocator };
    const counting_allocator = counting.allocator();

    var workspace: ascii.RenderWorkspace = .empty;
    defer workspace.deinit(counting_allocator);

    if (prepared) |*p| {
        try ascii.renderPreparedIntoWorkspace(&workspace, counting_allocator, p, terminal, options);
    } else {
        try ascii.renderIntoWorkspace(&workspace, counting_allocator, image, terminal, options);
    }
    const first_allocs = counting.alloc_count;
    const first_bytes = counting.bytes_allocated;

    counting.reset();

    var timings: [iterations]u64 = undefined;
    var total_ns: u64 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        if (prepared) |*p| {
            try ascii.renderPreparedIntoWorkspace(&workspace, counting_allocator, p, terminal, options);
        } else {
            try ascii.renderIntoWorkspace(&workspace, counting_allocator, image, terminal, options);
        }
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const elapsed: u64 = @intCast(end - start);
        timings[@intCast(i)] = elapsed;
        total_ns += elapsed;
    }

    insertionSortU64(&timings);

    const ns_per_iter = total_ns / iterations;
    const cells = @as(u64, out_w) * out_h;
    return .{
        .name = bench_case.name,
        .kind = bench_case.kind,
        .synthetic = bench_case.synthetic,
        .mode = bench_case.mode,
        .partition = bench_case.partition,
        .color = bench_case.color,
        .dither = bench_case.dither,
        .sample_strategy = bench_case.sample_strategy,
        .sampler_policy = sampler_policy,
        .input_width = in_w,
        .input_height = in_h,
        .output_columns = out_w,
        .output_rows = out_h,
        .iterations = iterations,
        .ns_per_iter = ns_per_iter,
        .median_ns = timings[timings.len / 2],
        .p95_ns = timings[(timings.len * 95 + 99) / 100 - 1],
        .ns_per_cell = ns_per_iter / cells,
        .cells_per_sec = if (ns_per_iter == 0) 0 else (cells * std.time.ns_per_s) / ns_per_iter,
        .allocated_bytes = first_bytes,
        .allocations_first_render = first_allocs,
        .allocations_steady_state = counting.alloc_count,
        .bytes_allocated_first_render = first_bytes,
        .bytes_allocated_steady_state = counting.bytes_allocated,
        .ansi_bytes = 0,
    };
}

fn runWorkspaceDiffCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: ascii.ImageView,
    terminal: ascii.TerminalProfile,
    options: ascii.Options,
    ansi_buf: []u8,
    bench_case: BenchCase,
) !BenchResult {
    var prepared: ?ascii.PreparedImage = null;
    defer if (prepared) |*p| p.deinit(allocator);
    if (bench_case.kind == .prepared_workspace_render_diff_repeat) {
        prepared = try ascii.prepareImage(allocator, image, terminal, .{ .sample_strategy = bench_case.sample_strategy });
    }

    const prepared_integral = if (prepared) |p| p.luma_sat != null else false;
    const sampler_policy = ascii.resolveSamplerPolicy(options, terminal, prepared_integral);

    var counting = BenchCountingAllocator{ .child = allocator };
    const counting_allocator = counting.allocator();

    var previous_workspace: ascii.RenderWorkspace = .empty;
    defer previous_workspace.deinit(counting_allocator);
    var current_workspace: ascii.RenderWorkspace = .empty;
    defer current_workspace.deinit(counting_allocator);

    if (prepared) |*p| {
        try ascii.renderPreparedIntoWorkspace(&previous_workspace, counting_allocator, p, terminal, options);
        try ascii.renderPreparedIntoWorkspace(&current_workspace, counting_allocator, p, terminal, options);
    } else {
        try ascii.renderIntoWorkspace(&previous_workspace, counting_allocator, image, terminal, options);
        try ascii.renderIntoWorkspace(&current_workspace, counting_allocator, image, terminal, options);
    }
    const first_allocs = counting.alloc_count;
    const first_bytes = counting.bytes_allocated;

    counting.reset();

    var stats = try runFrameDiffOnce(ansi_buf, &previous_workspace.frame, &current_workspace.frame);
    var timings: [iterations]u64 = undefined;
    var total_ns: u64 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        if (prepared) |*p| {
            try ascii.renderPreparedIntoWorkspace(&current_workspace, counting_allocator, p, terminal, options);
        } else {
            try ascii.renderIntoWorkspace(&current_workspace, counting_allocator, image, terminal, options);
        }
        stats = try runFrameDiffOnce(ansi_buf, &previous_workspace.frame, &current_workspace.frame);
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const elapsed: u64 = @intCast(end - start);
        timings[@intCast(i)] = elapsed;
        total_ns += elapsed;
    }

    insertionSortU64(&timings);

    const ns_per_iter = total_ns / iterations;
    const cells = @as(u64, out_w) * out_h;
    return .{
        .name = bench_case.name,
        .kind = bench_case.kind,
        .synthetic = bench_case.synthetic,
        .mode = bench_case.mode,
        .partition = bench_case.partition,
        .color = bench_case.color,
        .dither = bench_case.dither,
        .sample_strategy = bench_case.sample_strategy,
        .sampler_policy = sampler_policy,
        .input_width = in_w,
        .input_height = in_h,
        .output_columns = out_w,
        .output_rows = out_h,
        .iterations = iterations,
        .ns_per_iter = ns_per_iter,
        .median_ns = timings[timings.len / 2],
        .p95_ns = timings[(timings.len * 95 + 99) / 100 - 1],
        .ns_per_cell = ns_per_iter / cells,
        .cells_per_sec = if (ns_per_iter == 0) 0 else (cells * std.time.ns_per_s) / ns_per_iter,
        .allocated_bytes = first_bytes,
        .allocations_first_render = first_allocs,
        .allocations_steady_state = counting.alloc_count,
        .bytes_allocated_first_render = first_bytes,
        .bytes_allocated_steady_state = counting.bytes_allocated,
        .cells_changed = stats.cells_changed,
        .runs_emitted = stats.runs_emitted,
        .ansi_bytes = stats.bytes_emitted,
    };
}

fn runOnce(
    allocator: std.mem.Allocator,
    image: ascii.ImageView,
    terminal: ascii.TerminalProfile,
    options: ascii.Options,
    ansi_buf: []u8,
    kind: BenchKind,
    prepared: ?*const ascii.PreparedImage,
    pre_frame: ?*const ascii.Frame,
) !u64 {
    switch (kind) {
        .render => {
            var frame = try ascii.renderToCells(allocator, image, terminal, options);
            frame.deinit(allocator);
            return 0;
        },
        .render_prepared => {
            var frame = try ascii.renderPreparedToCells(allocator, prepared.?, terminal, options);
            frame.deinit(allocator);
            return 0;
        },
        .render_writer => {
            var fixed: std.Io.Writer = .fixed(ansi_buf);
            try ascii.renderToWriter(&fixed, allocator, image, terminal, options);
            return fixed.end;
        },
        .ansi_encode_only => {
            var fixed: std.Io.Writer = .fixed(ansi_buf);
            try ascii.renderFrameToWriter(&fixed, pre_frame.?.*);
            return fixed.end;
        },
        .quality_compare_only => {
            const score = qualityProxy(pre_frame.?.*);
            std.mem.doNotOptimizeAway(score);
            return 0;
        },
        .workspace_repeat, .prepared_workspace_repeat, .ansi_diff, .workspace_render_diff_repeat, .prepared_workspace_render_diff_repeat => unreachable,
    }
}

fn qualityProxy(frame: ascii.Frame) u64 {
    var hash: u64 = 1469598103934665603;
    for (frame.codepoints) |cp| {
        hash ^= @as(u64, cp);
        hash *%= 1099511628211;
    }
    return hash;
}

fn allocatedBytes(bench_case: BenchCase, columns: u32, rows: u32) u64 {
    return switch (bench_case.kind) {
        .ansi_encode_only, .quality_compare_only, .workspace_repeat, .prepared_workspace_repeat, .ansi_diff, .workspace_render_diff_repeat, .prepared_workspace_render_diff_repeat => 0,
        else => {
            const cells = @as(u64, columns) * rows;
            const codepoint_bytes = cells * @sizeOf(u21);
            const color_bytes = if (bench_case.color == .none) 0 else cells * 2 * @sizeOf(ascii.Rgb8);
            return codepoint_bytes + color_bytes + samplePlanBytes(bench_case, columns, rows);
        },
    };
}

fn samplePlanBytes(bench_case: BenchCase, columns: u32, rows: u32) u64 {
    const terminal = ascii.TerminalProfile{ .columns = columns, .rows = rows, .color = bench_case.color };
    const options = ascii.Options{
        .mode = bench_case.mode,
        .partition = bench_case.partition,
        .sample_strategy = bench_case.sample_strategy,
    };
    const prepared_integral = bench_case.kind == .render_prepared and bench_case.sample_strategy == .integral_luma and bench_case.color == .none;
    if (ascii.resolveSamplerPolicy(options, terminal, prepared_integral) != .span_precompute) return 0;

    const subcells = subcellShape(bench_case);
    const spans = @as(u64, columns) * subcells.x + @as(u64, rows) * subcells.y;
    return spans * @sizeOf(ascii.AxisSpan);
}

fn subcellShape(bench_case: BenchCase) struct { x: u64, y: u64 } {
    return switch (bench_case.mode) {
        .density, .glyph_tone => .{ .x = 1, .y = 1 },
        .glyph_structure => .{ .x = ascii.default_glyph_cell_width, .y = ascii.default_glyph_cell_height },
        .braille => .{ .x = 2, .y = 4 },
        .partition => switch (bench_case.partition) {
            .density_1x1 => .{ .x = 1, .y = 1 },
            .half_1x2 => .{ .x = 1, .y = 2 },
            .quadrant_2x2 => .{ .x = 2, .y = 2 },
            .sextant_2x3 => .{ .x = 2, .y = 3 },
            .octant_2x4 => .{ .x = 2, .y = 4 },
        },
    };
}

fn insertionSortU64(values: []u64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

fn writeCsvRow(writer: *std.Io.Writer, result: BenchResult) !void {
    try writer.print("{s},{s},{d}x{d},{d}x{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
        result.name,
        @tagName(result.sampler_policy),
        result.input_width,
        result.input_height,
        result.output_columns,
        result.output_rows,
        result.iterations,
        result.ns_per_iter,
        result.median_ns,
        result.p95_ns,
        result.ns_per_cell,
        result.cells_per_sec,
        result.allocated_bytes,
        result.allocations_first_render,
        result.allocations_steady_state,
        result.bytes_allocated_first_render,
        result.bytes_allocated_steady_state,
        result.cells_changed,
        result.runs_emitted,
        result.ansi_bytes,
    });
}

fn writeJsonResults(io: std.Io, out_path: []const u8, results: []const BenchResult) !void {
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
        \\  "benchmark": {{
        \\    "sampler": "ansi_diff",
        \\    "input_width": {d},
        \\    "input_height": {d},
        \\    "output_columns": {d},
        \\    "output_rows": {d},
        \\    "iterations": {d}
        \\  }},
        \\  "results": [
        \\
    , .{
        builtin.zig_version_string,
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.cpu.arch),
        in_w,
        in_h,
        out_w,
        out_h,
        iterations,
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

fn writeJsonResult(writer: *std.Io.Writer, result: BenchResult) !void {
    try writer.print(
        \\    {{
        \\      "case": "{s}",
        \\      "kind": "{s}",
        \\      "mode": "{s}",
        \\      "partition": "{s}",
        \\      "color_mode": "{s}",
        \\      "sample_strategy": "{s}",
        \\      "sampler_policy": "{s}",
        \\      "dither": "{s}",
        \\      "synthetic": "{s}",
        \\      "input_width": {d},
        \\      "input_height": {d},
        \\      "output_columns": {d},
        \\      "output_rows": {d},
        \\      "iterations": {d},
        \\      "ns_per_iter": {d},
        \\      "median_ns": {d},
        \\      "p95_ns": {d},
        \\      "ns_per_cell": {d},
        \\      "cells_per_sec": {d},
        \\      "allocated_bytes": {d},
        \\      "allocations_first_render": {d},
        \\      "allocations_steady_state": {d},
        \\      "bytes_allocated_first_render": {d},
        \\      "bytes_allocated_steady_state": {d},
        \\      "cells_changed": {d},
        \\      "runs_emitted": {d},
        \\      "ansi_bytes": {d}
        \\    }}
    , .{
        result.name,
        @tagName(result.kind),
        @tagName(result.mode),
        @tagName(result.partition),
        @tagName(result.color),
        @tagName(result.sample_strategy),
        @tagName(result.sampler_policy),
        @tagName(result.dither),
        @tagName(result.synthetic),
        result.input_width,
        result.input_height,
        result.output_columns,
        result.output_rows,
        result.iterations,
        result.ns_per_iter,
        result.median_ns,
        result.p95_ns,
        result.ns_per_cell,
        result.cells_per_sec,
        result.allocated_bytes,
        result.allocations_first_render,
        result.allocations_steady_state,
        result.bytes_allocated_first_render,
        result.bytes_allocated_steady_state,
        result.cells_changed,
        result.runs_emitted,
        result.ansi_bytes,
    });
}

fn writeRealImageSmokeJson(io: std.Io, allocator: std.mem.Allocator, out_path: []const u8) !void {
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.createDirPath(.cwd(), io, dir);
    }

    var results: [real_image_smoke_cases.len]RealImageSmokeResult = undefined;
    for (real_image_smoke_cases, 0..) |case, idx| {
        results[idx] = try runRealImageSmokeCase(io, allocator, case);
        if (!std.math.isFinite(results[idx].psnr_db) or
            !std.math.isFinite(results[idx].ssim) or
            !std.math.isFinite(results[idx].edge_correlation))
        {
            return error.RealImageSmokeMetricNotFinite;
        }
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
        \\  "adapter": "zigimg",
        \\  "smoke": {{
        \\    "name": "real-image-smoke",
        \\    "cases": {d}
        \\  }},
        \\  "results": [
        \\
    , .{
        builtin.zig_version_string,
        results.len,
    });

    for (results, 0..) |result, idx| {
        if (idx != 0) try writer.writeAll(",\n");
        try writeRealImageSmokeResult(writer, result);
    }

    try writer.writeAll(
        \\
        \\  ]
        \\}
        \\
    );
    try writer.flush();
}

fn runRealImageSmokeCase(io: std.Io, allocator: std.mem.Allocator, case: RealImageSmokeCase) !RealImageSmokeResult {
    var loaded = try image_loader.loadPath(io, allocator, case.path);
    defer loaded.deinit(allocator);
    const image = loaded.imageView();

    const terminal = ascii.TerminalProfile{
        .columns = case.width,
        .rows = case.height,
        .color = case.color,
        .symbols = symbolsForMode(case.mode),
    };
    const options = ascii.Options{
        .mode = case.mode,
        .partition = case.partition,
        .fit = case.fit,
        .dither = case.dither,
    };
    const sampler_policy = ascii.resolveSamplerPolicy(options, terminal, false);

    var frame = try ascii.renderToCells(allocator, image, terminal, options);
    defer frame.deinit(allocator);

    var recon = try reconstruct.reconstructForMode(allocator, frame, case.mode);
    defer recon.deinit(allocator);

    const background = common.Rgb{
        .r = terminal.background.r,
        .g = terminal.background.g,
        .b = terminal.background.b,
    };
    const crop = common.cropRectFor(image, terminal, case.fit);
    var reference = try common.resizeReference(allocator, image, background, crop, recon.width, recon.height);
    defer reference.deinit(allocator);

    const report = try metrics.compare(allocator, reference, recon);
    return .{
        .name = case.name,
        .path = case.path,
        .adapter = loaded.adapter,
        .format = loaded.format,
        .decoded_pixel_format = loaded.pixel_format_name,
        .decoded_width = loaded.width,
        .decoded_height = loaded.height,
        .mode = case.mode,
        .partition = case.partition,
        .color = case.color,
        .sampler_policy = sampler_policy,
        .output_columns = frame.columns,
        .output_rows = frame.rows,
        .psnr_db = report.psnr_db,
        .ssim = report.ssim,
        .edge_correlation = report.edge_correlation,
        .status = "pass",
    };
}

fn writeRealImageSmokeResult(writer: *std.Io.Writer, result: RealImageSmokeResult) !void {
    try writer.print(
        \\    {{
        \\      "fixture": "{s}",
        \\      "input_path": "{s}",
        \\      "adapter": "{s}",
        \\      "format": "{s}",
        \\      "decoded_width": {d},
        \\      "decoded_height": {d},
        \\      "decoded_pixel_format": "{s}",
        \\      "mode": "{s}",
        \\      "partition": "{s}",
        \\      "color_mode": "{s}",
        \\      "sampler_policy": "{s}",
        \\      "output_columns": {d},
        \\      "output_rows": {d},
        \\      "psnr_db": {d:.6},
        \\      "ssim": {d:.6},
        \\      "edge_correlation": {d:.6},
        \\      "status": "{s}"
        \\    }}
    , .{
        result.name,
        result.path,
        @tagName(result.adapter),
        @tagName(result.format),
        result.decoded_width,
        result.decoded_height,
        result.decoded_pixel_format,
        @tagName(result.mode),
        @tagName(result.partition),
        @tagName(result.color),
        @tagName(result.sampler_policy),
        result.output_columns,
        result.output_rows,
        result.psnr_db,
        result.ssim,
        result.edge_correlation,
        result.status,
    });
}

fn symbolsForMode(mode: ascii.RenderMode) ascii.TerminalSymbols {
    return switch (mode) {
        .braille => .braille,
        .glyph_tone, .glyph_structure => .glyphs,
        else => .block_basic,
    };
}

fn runFrameDiffOnce(ansi_buf: []u8, previous: *const ascii.Frame, current: *const ascii.Frame) !ascii.AnsiDiffStats {
    var fixed: std.Io.Writer = .fixed(ansi_buf);
    const stats = try ascii.renderFrameDiffToWriter(&fixed, previous, current, .{});
    std.debug.assert(fixed.end == stats.bytes_emitted);
    return stats;
}

fn cloneFrame(allocator: std.mem.Allocator, source: ascii.Frame) !ascii.Frame {
    var frame: ascii.Frame = .empty;
    errdefer frame.deinit(allocator);
    try frame.ensureCapacity(allocator, source.columns, source.rows, source.color);
    @memcpy(frame.codepoints, source.codepoints);
    @memcpy(frame.fg, source.fg);
    @memcpy(frame.bg, source.bg);
    return frame;
}

fn mutateFrameForDiff(frame: *ascii.Frame, scenario: DiffScenario) void {
    const cells = frame.codepoints.len;
    if (cells == 0) return;

    switch (scenario) {
        .none, .noop => {},
        .single_cell => changeCell(frame, cells / 2),
        .small_run => {
            const row = frame.rows / 2;
            const run_len = @min(@as(u32, 8), frame.columns);
            const start_col = (frame.columns - run_len) / 2;
            var col: u32 = 0;
            while (col < run_len) : (col += 1) {
                changeCell(frame, @as(usize, row) * frame.columns + start_col + col);
            }
        },
        .one_row => {
            const row = frame.rows / 2;
            var col: u32 = 0;
            while (col < frame.columns) : (col += 1) {
                changeCell(frame, @as(usize, row) * frame.columns + col);
            }
        },
        .full => {
            var idx: usize = 0;
            while (idx < cells) : (idx += 1) {
                changeCell(frame, idx);
            }
        },
    }
}

fn changeCell(frame: *ascii.Frame, idx: usize) void {
    frame.codepoints[idx] = if (frame.codepoints[idx] == 'X') 'Y' else 'X';
    if (frame.color != .none) {
        frame.fg[idx] = .{ .r = 255, .g = 255, .b = 255 };
        frame.bg[idx] = .{ .r = 0, .g = 0, .b = 0 };
    }
}

fn makeImage(allocator: std.mem.Allocator, synthetic: Synthetic, width: u32, height: u32) !ascii.ImageView {
    const pixels = try allocator.alloc(ascii.Rgba8, try std.math.mul(usize, width, height));
    errdefer allocator.free(pixels);

    var seed: u32 = 0x1234567;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            pixels[@as(usize, y) * width + x] = switch (synthetic) {
                .gradient => gradientPixel(x, y, width, height),
                .checkerboard => checkerboardPixel(x, y),
                .color_mix => colorMixPixel(&seed),
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

fn colorMixPixel(seed: *u32) ascii.Rgba8 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    const v = seed.*;
    return .{
        .r = @truncate(v >> 16),
        .g = @truncate(v >> 8),
        .b = @truncate(v),
        .a = 255,
    };
}

const BenchCountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    bytes_allocated: usize = 0,

    fn allocator(self: *BenchCountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *BenchCountingAllocator) void {
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
        const self: *BenchCountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr);
        if (ptr != null) {
            self.alloc_count += 1;
            self.bytes_allocated += len;
        }
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *BenchCountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *BenchCountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr);
        if (ptr != null and new_len > memory.len) {
            self.alloc_count += 1;
            self.bytes_allocated += new_len - memory.len;
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *BenchCountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "bench cases include render and lab-only rows" {
    var has_ansi = false;
    var has_quality = false;
    var has_prepared = false;
    var has_workspace = false;
    for (cases) |bench_case| {
        has_ansi = has_ansi or bench_case.kind == .ansi_encode_only;
        has_quality = has_quality or bench_case.kind == .quality_compare_only;
        has_prepared = has_prepared or bench_case.kind == .render_prepared;
        has_workspace = has_workspace or bench_case.kind == .workspace_repeat;
    }
    try std.testing.expect(has_ansi);
    try std.testing.expect(has_quality);
    try std.testing.expect(has_prepared);
    try std.testing.expect(has_workspace);
}
