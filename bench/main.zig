const std = @import("std");
const ascii = @import("image_to_ascii");

const BenchCase = struct {
    name: []const u8,
    mode: ascii.RenderMode,
    partition: ascii.PartitionKind,
    color: ascii.ColorMode,
};

const cases = [_]BenchCase{
    .{ .name = "density-none", .mode = .density, .partition = .density_1x1, .color = .none },
    .{ .name = "half-truecolor", .mode = .partition, .partition = .half_1x2, .color = .truecolor },
    .{ .name = "quadrant-truecolor", .mode = .partition, .partition = .quadrant_2x2, .color = .truecolor },
    .{ .name = "braille-none", .mode = .braille, .partition = .octant_2x4, .color = .none },
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const image = try makeGradient(allocator, 400, 240);
    defer allocator.free(image.pixels);

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("case,input,output,iterations,total_ns,ns_per_iter,cells_per_sec\n");
    for (cases) |case| {
        try runCase(stdout, init.io, allocator, image, case);
    }
    try stdout.flush();
}

fn runCase(writer: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator, image: ascii.ImageView, case: BenchCase) !void {
    const terminal = ascii.TerminalProfile{
        .columns = 80,
        .rows = 30,
        .color = case.color,
        .symbols = if (case.mode == .braille) .braille else .block_basic,
    };
    const options = ascii.Options{
        .mode = case.mode,
        .partition = case.partition,
        .fit = .stretch,
    };

    var warmup = try ascii.renderToCells(allocator, image, terminal, options);
    warmup.deinit(allocator);

    const iterations: u64 = 200;
    const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var frame = try ascii.renderToCells(allocator, image, terminal, options);
        frame.deinit(allocator);
    }
    const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    const total_ns: u64 = @intCast(end - start);
    const ns_per_iter = total_ns / iterations;
    const cells = @as(u64, terminal.columns) * terminal.rows;
    const cells_per_sec = if (ns_per_iter == 0) 0 else (cells * std.time.ns_per_s) / ns_per_iter;

    try writer.print("{s},400x240,80x30,{},{},{},{}\n", .{
        case.name,
        iterations,
        total_ns,
        ns_per_iter,
        cells_per_sec,
    });
}

fn makeGradient(allocator: std.mem.Allocator, width: u32, height: u32) !ascii.ImageView {
    const pixels = try allocator.alloc(ascii.Rgba8, try std.math.mul(usize, width, height));
    errdefer allocator.free(pixels);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const r: u8 = @intFromFloat((@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1))) * 255.0);
            const g: u8 = @intFromFloat((@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height - 1))) * 255.0);
            pixels[@as(usize, y) * width + x] = .{ .r = r, .g = g, .b = 180, .a = 255 };
        }
    }

    return .{
        .width = width,
        .height = height,
        .stride = @as(usize, width) * @sizeOf(ascii.Rgba8),
        .pixels = pixels,
    };
}

test "bench cases are defined" {
    try std.testing.expect(cases.len >= 2);
}
