const std = @import("std");
const ascii = @import("image_to_ascii");

const Synthetic = enum { gradient, checkerboard, color_mix };

const BenchCase = struct {
    name: []const u8,
    synthetic: Synthetic = .gradient,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind,
    color: ascii.ColorMode,
    dither: ascii.DitherMode = .none,
    /// When true, time the full render + ANSI encode path and report bytes.
    writer: bool = false,
};

const cases = [_]BenchCase{
    .{ .name = "density-none", .mode = .density, .partition = .density_1x1, .color = .none },
    .{ .name = "density-truecolor", .mode = .density, .partition = .density_1x1, .color = .truecolor },
    .{ .name = "half-truecolor", .mode = .partition, .partition = .half_1x2, .color = .truecolor },
    .{ .name = "quadrant-none", .mode = .partition, .partition = .quadrant_2x2, .color = .none },
    .{ .name = "quadrant-truecolor", .synthetic = .color_mix, .mode = .partition, .partition = .quadrant_2x2, .color = .truecolor },
    .{ .name = "braille-none-dither", .synthetic = .checkerboard, .mode = .braille, .partition = .octant_2x4, .color = .none, .dither = .ordered_4x4 },
    .{ .name = "braille-truecolor", .synthetic = .color_mix, .mode = .braille, .partition = .octant_2x4, .color = .truecolor },
    .{ .name = "ansi-half-truecolor", .synthetic = .color_mix, .mode = .partition, .partition = .half_1x2, .color = .truecolor, .writer = true },
};

const in_w = 400;
const in_h = 240;
const out_w = 80;
const out_h = 30;
const iterations: u64 = 200;

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const gradient = try makeImage(allocator, .gradient, in_w, in_h);
    defer allocator.free(gradient.pixels);
    const checkerboard = try makeImage(allocator, .checkerboard, in_w, in_h);
    defer allocator.free(checkerboard.pixels);
    const color_mix = try makeImage(allocator, .color_mix, in_w, in_h);
    defer allocator.free(color_mix.pixels);

    // A reusable buffer for the ANSI writer path.
    const ansi_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(ansi_buf);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("case,input,output,iters,ns_per_iter,ns_per_cell,cells_per_sec,bytes\n");
    for (cases) |case| {
        const image = switch (case.synthetic) {
            .gradient => gradient,
            .checkerboard => checkerboard,
            .color_mix => color_mix,
        };
        try runCase(stdout, init.io, allocator, image, ansi_buf, case);
    }
    try stdout.flush();
}

fn runCase(
    writer: *std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    image: ascii.ImageView,
    ansi_buf: []u8,
    case: BenchCase,
) !void {
    const terminal = ascii.TerminalProfile{
        .columns = out_w,
        .rows = out_h,
        .color = case.color,
        .symbols = if (case.mode == .braille) .braille else .block_basic,
    };
    const options = ascii.Options{
        .mode = case.mode,
        .partition = case.partition,
        .fit = .stretch,
        .dither = case.dither,
    };

    var bytes: u64 = 0;

    // Warmup.
    {
        var frame = try ascii.renderToCells(allocator, image, terminal, options);
        frame.deinit(allocator);
    }

    const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        if (case.writer) {
            var fixed: std.Io.Writer = .fixed(ansi_buf);
            try ascii.renderToWriter(&fixed, allocator, image, terminal, options);
            bytes = fixed.end;
        } else {
            var frame = try ascii.renderToCells(allocator, image, terminal, options);
            frame.deinit(allocator);
        }
    }
    const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();

    const total_ns: u64 = @intCast(end - start);
    const ns_per_iter = total_ns / iterations;
    const cells = @as(u64, out_w) * out_h;
    const ns_per_cell = ns_per_iter / cells;
    const cells_per_sec = if (ns_per_iter == 0) 0 else (cells * std.time.ns_per_s) / ns_per_iter;

    try writer.print("{s},{d}x{d},{d}x{d},{d},{d},{d},{d},{d}\n", .{
        case.name, in_w, in_h, out_w, out_h, iterations, ns_per_iter, ns_per_cell, cells_per_sec, bytes,
    });
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

// Deterministic noise so cell subsamples mix colors (stresses the color solve).
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

test "bench cases are defined" {
    try std.testing.expect(cases.len >= 2);
}
