//! calibrate_font: generate a per-font GlyphAtlas for the glyph render modes.
//!
//! Rasterization is provided by stb_truetype (public domain), vendored under
//! tools/stb/ and linked only into this tool — per RESEARCH.md, the font
//! rasterizer must never reach the dependency-free core.
//!
//! For each requested codepoint this:
//!   1. rasterizes the glyph into a cell-sized coverage bitmap,
//!   2. computes coverage, ink centroid/spread, and a dominant edge orientation,
//!   3. packs a 1-bit mask,
//!   4. buckets glyphs by coverage for fast glyph-tone lookup.
//!
//! Usage:
//!   zig build calibrate -- --font /System/Library/Fonts/Monaco.ttf \
//!       --cell 8x16 --out src/generated_atlas.zig
//!
//! The emitted Zig file is a self-contained atlas literal that src/glyph.zig can
//! @import once the glyph render modes land.

const std = @import("std");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

const default_font = "/System/Library/Fonts/Monaco.ttf";

/// A precomputed, font-specific glyph atlas. Mirrors RESEARCH.md so the
/// serialized format and the core consumer share one contract.
pub const GlyphAtlas = struct {
    cell_width: u8,
    cell_height: u8,
    glyphs: []const GlyphFeature,
    buckets: []const GlyphBucket,
    /// Packed 1-bit masks (cell_width*cell_height bits per glyph, LSB-first,
    /// row-major), referenced by GlyphFeature.mask_offset / mask_len.
    masks: []const u8,
};

pub const GlyphFeature = struct {
    codepoint: u21,
    coverage: f32,
    dominant_orientation: u8,
    centroid_x: f32,
    centroid_y: f32,
    spread_x: f32,
    spread_y: f32,
    mask_offset: u32,
    mask_len: u16,
};

pub const GlyphBucket = struct {
    coverage_min: f32,
    coverage_max: f32,
    first: u32,
    count: u32,
};

const Options = struct {
    font_path: []const u8 = default_font,
    cell_w: u32 = 8,
    cell_h: u32 = 16,
    first_cp: u21 = 0x20,
    last_cp: u21 = 0x7e,
    out_path: ?[]const u8 = null,
    bucket_count: u32 = 8,
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

const Built = struct {
    glyphs: []GlyphFeature,
    masks: []u8,
};

fn run(writer: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    const font_bytes = std.Io.Dir.cwd().readFileAlloc(io, options.font_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.FontNotFound,
        else => return err,
    };

    var font: c.stbtt_fontinfo = undefined;
    const offset = c.stbtt_GetFontOffsetForIndex(font_bytes.ptr, 0);
    if (c.stbtt_InitFont(&font, font_bytes.ptr, offset) == 0) return error.InvalidFont;

    const built = try buildAtlas(allocator, &font, options);
    const buckets = try buildBuckets(allocator, built.glyphs, options.bucket_count);

    try writer.print(
        \\font          : {s}
        \\cell          : {d}x{d}
        \\codepoints    : U+{X:0>4}..U+{X:0>4} ({d} glyphs)
        \\mask bytes    : {d}
        \\
        \\coverage-sorted glyphs:
        \\
    , .{
        options.font_path,          options.cell_w,            options.cell_h,
        @as(u32, options.first_cp), @as(u32, options.last_cp), built.glyphs.len,
        built.masks.len,
    });

    for (built.glyphs) |g| {
        const ch: u8 = if (g.codepoint >= 0x20 and g.codepoint < 0x7f) @intCast(g.codepoint) else '?';
        try writer.print(
            "  '{c}' U+{X:0>4}  cov={d:.3}  orient={d}  centroid=({d:.2},{d:.2})\n",
            .{ ch, @as(u32, g.codepoint), g.coverage, g.dominant_orientation, g.centroid_x, g.centroid_y },
        );
    }

    try writer.print("\nbuckets ({d}):\n", .{buckets.len});
    for (buckets, 0..) |b, i| {
        try writer.print("  [{d}] cov {d:.3}..{d:.3}  count={d}\n", .{ i, b.coverage_min, b.coverage_max, b.count });
    }

    if (options.out_path) |path| {
        const atlas = GlyphAtlas{
            .cell_width = @intCast(options.cell_w),
            .cell_height = @intCast(options.cell_h),
            .glyphs = built.glyphs,
            .buckets = buckets,
            .masks = built.masks,
        };
        try emitAtlasZig(io, allocator, path, options, atlas);
        try writer.print("\nwrote atlas -> {s}\n", .{path});
    }
}

fn buildAtlas(allocator: std.mem.Allocator, font: *c.stbtt_fontinfo, options: Options) !Built {
    const cw = options.cell_w;
    const ch = options.cell_h;
    const cell = try allocator.alloc(u8, cw * ch);
    defer allocator.free(cell);

    const scale = c.stbtt_ScaleForPixelHeight(font, @floatFromInt(ch));
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    c.stbtt_GetFontVMetrics(font, &ascent, &descent, &line_gap);
    const baseline: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(ascent)) * scale));

    var glyphs: std.ArrayList(GlyphFeature) = .empty;
    errdefer glyphs.deinit(allocator);
    var masks: std.ArrayList(u8) = .empty;
    errdefer masks.deinit(allocator);

    var cp: u21 = options.first_cp;
    while (cp <= options.last_cp) : (cp += 1) {
        rasterCell(font, scale, baseline, @intCast(cp), cw, ch, cell);

        const feat = features(cell, cw, ch);
        const mask_offset: u32 = @intCast(masks.items.len);
        const mask_len = try packMask(allocator, &masks, cell, cw, ch);

        try glyphs.append(allocator, .{
            .codepoint = cp,
            .coverage = feat.coverage,
            .dominant_orientation = feat.orientation,
            .centroid_x = feat.cx,
            .centroid_y = feat.cy,
            .spread_x = feat.sx,
            .spread_y = feat.sy,
            .mask_offset = mask_offset,
            .mask_len = mask_len,
        });
    }

    const owned_glyphs = try glyphs.toOwnedSlice(allocator);
    std.mem.sort(GlyphFeature, owned_glyphs, {}, struct {
        fn lt(_: void, a: GlyphFeature, b: GlyphFeature) bool {
            return a.coverage < b.coverage;
        }
    }.lt);

    return .{ .glyphs = owned_glyphs, .masks = try masks.toOwnedSlice(allocator) };
}

/// Rasterize one codepoint into a zeroed cell buffer, baseline-aligned and
/// clipped to the cell.
fn rasterCell(font: *c.stbtt_fontinfo, scale: f32, baseline: i32, cp: c_int, cw: u32, ch: u32, cell: []u8) void {
    @memset(cell, 0);

    var gw: c_int = 0;
    var gh: c_int = 0;
    var xoff: c_int = 0;
    var yoff: c_int = 0;
    const bmp = c.stbtt_GetCodepointBitmap(font, scale, scale, cp, &gw, &gh, &xoff, &yoff);
    if (bmp == null) return;
    defer c.stbtt_FreeBitmap(bmp, null);

    const tx: i32 = @max(0, xoff);
    const ty: i32 = baseline + yoff;

    var y: i32 = 0;
    while (y < gh) : (y += 1) {
        const cy = ty + y;
        if (cy < 0 or cy >= @as(i32, @intCast(ch))) continue;
        var x: i32 = 0;
        while (x < gw) : (x += 1) {
            const cx = tx + x;
            if (cx < 0 or cx >= @as(i32, @intCast(cw))) continue;
            const src = bmp[@intCast(y * gw + x)];
            cell[@intCast(cy * @as(i32, @intCast(cw)) + cx)] = src;
        }
    }
}

const Features = struct {
    coverage: f32,
    cx: f32,
    cy: f32,
    sx: f32,
    sy: f32,
    orientation: u8,
};

fn features(cell: []const u8, cw: u32, ch: u32) Features {
    var sum: f64 = 0.0;
    var sum_x: f64 = 0.0;
    var sum_y: f64 = 0.0;
    for (0..ch) |yy| {
        for (0..cw) |xx| {
            const v = @as(f64, @floatFromInt(cell[yy * cw + xx]));
            sum += v;
            sum_x += v * @as(f64, @floatFromInt(xx));
            sum_y += v * @as(f64, @floatFromInt(yy));
        }
    }

    const px = @as(f64, @floatFromInt(cw * ch)) * 255.0;
    const coverage: f32 = if (px == 0.0) 0.0 else @floatCast(sum / px);

    var cx: f64 = 0.5;
    var cy: f64 = 0.5;
    if (sum > 0.0) {
        cx = (sum_x / sum) / @as(f64, @floatFromInt(@max(1, cw - 1)));
        cy = (sum_y / sum) / @as(f64, @floatFromInt(@max(1, ch - 1)));
    }

    var var_x: f64 = 0.0;
    var var_y: f64 = 0.0;
    if (sum > 0.0) {
        const mx = sum_x / sum;
        const my = sum_y / sum;
        for (0..ch) |yy| {
            for (0..cw) |xx| {
                const v = @as(f64, @floatFromInt(cell[yy * cw + xx]));
                const dx = @as(f64, @floatFromInt(xx)) - mx;
                const dy = @as(f64, @floatFromInt(yy)) - my;
                var_x += v * dx * dx;
                var_y += v * dy * dy;
            }
        }
        var_x = @sqrt(var_x / sum) / @as(f64, @floatFromInt(@max(1, cw)));
        var_y = @sqrt(var_y / sum) / @as(f64, @floatFromInt(@max(1, ch)));
    }

    return .{
        .coverage = coverage,
        .cx = @floatCast(cx),
        .cy = @floatCast(cy),
        .sx = @floatCast(var_x),
        .sy = @floatCast(var_y),
        .orientation = dominantOrientation(cell, cw, ch),
    };
}

/// Dominant edge orientation as a quantized gradient angle in [0, pi), split
/// into 4 bins, magnitude-weighted. The gradient is perpendicular to the stroke,
/// so e.g. a vertical stroke ('|') yields a horizontal gradient in bin 0 and a
/// horizontal stroke ('-') yields a vertical gradient in bin 2. The exact
/// labels do not matter to the consumer; only that orientations are stable and
/// comparable for structure prefiltering.
fn dominantOrientation(cell: []const u8, cw: u32, ch: u32) u8 {
    if (cw < 3 or ch < 3) return 0;
    var bins = [_]f64{ 0.0, 0.0, 0.0, 0.0 };
    var y: u32 = 1;
    while (y < ch - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < cw - 1) : (x += 1) {
            const gx = @as(f64, @floatFromInt(cell[y * cw + x + 1])) - @as(f64, @floatFromInt(cell[y * cw + x - 1]));
            const gy = @as(f64, @floatFromInt(cell[(y + 1) * cw + x])) - @as(f64, @floatFromInt(cell[(y - 1) * cw + x]));
            const mag = @sqrt(gx * gx + gy * gy);
            if (mag < 1.0) continue;
            var angle = std.math.atan2(gy, gx); // -pi..pi
            if (angle < 0.0) angle += std.math.pi; // fold to 0..pi
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

fn packMask(allocator: std.mem.Allocator, masks: *std.ArrayList(u8), cell: []const u8, cw: u32, ch: u32) !u16 {
    const bits = cw * ch;
    const bytes = (bits + 7) / 8;
    const start = masks.items.len;
    try masks.appendNTimes(allocator, 0, bytes);
    for (0..bits) |i| {
        if (cell[i] >= 128) {
            masks.items[start + i / 8] |= @as(u8, 1) << @intCast(i % 8);
        }
    }
    return @intCast(bytes);
}

fn buildBuckets(allocator: std.mem.Allocator, glyphs: []const GlyphFeature, bucket_count: u32) ![]GlyphBucket {
    var buckets = try allocator.alloc(GlyphBucket, bucket_count);
    for (buckets, 0..) |*b, i| {
        const lo = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bucket_count));
        const hi = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(bucket_count));
        b.* = .{ .coverage_min = lo, .coverage_max = hi, .first = 0, .count = 0 };
    }
    // glyphs are coverage-sorted, so assign contiguous ranges.
    var gi: u32 = 0;
    for (buckets) |*b| {
        b.first = gi;
        while (gi < glyphs.len and glyphs[gi].coverage <= b.coverage_max) : (gi += 1) {
            b.count += 1;
        }
    }
    if (gi < glyphs.len) buckets[buckets.len - 1].count += @intCast(glyphs.len - gi);
    return buckets;
}

fn emitAtlasZig(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: Options, atlas: GlyphAtlas) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.print(allocator,
        \\//! Generated by tools/calibrate_font.zig. Do not edit by hand.
        \\//! font: {s}  cell: {d}x{d}
        \\
        \\pub const cell_width: u8 = {d};
        \\pub const cell_height: u8 = {d};
        \\
        \\pub const Glyph = struct {{
        \\    codepoint: u21,
        \\    coverage: f32,
        \\    dominant_orientation: u8,
        \\    centroid_x: f32,
        \\    centroid_y: f32,
        \\    spread_x: f32,
        \\    spread_y: f32,
        \\    mask_offset: u32,
        \\    mask_len: u16,
        \\}};
        \\
        \\pub const glyphs = [_]Glyph{{
        \\
    , .{ options.font_path, options.cell_w, options.cell_h, options.cell_w, options.cell_h });

    for (atlas.glyphs) |g| {
        try out.print(
            allocator,
            "    .{{ .codepoint = {d}, .coverage = {d}, .dominant_orientation = {d}, .centroid_x = {d}, .centroid_y = {d}, .spread_x = {d}, .spread_y = {d}, .mask_offset = {d}, .mask_len = {d} }},\n",
            .{ @as(u32, g.codepoint), g.coverage, g.dominant_orientation, g.centroid_x, g.centroid_y, g.spread_x, g.spread_y, g.mask_offset, g.mask_len },
        );
    }
    try out.appendSlice(allocator, "};\n\npub const masks = [_]u8{");
    for (atlas.masks, 0..) |byte, i| {
        if (i % 16 == 0) try out.appendSlice(allocator, "\n    ");
        try out.print(allocator, "0x{X:0>2}, ", .{byte});
    }
    try out.appendSlice(allocator, "\n};\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--font")) {
            options.font_path = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--cell")) {
            const v = try value(args, &i);
            const x = std.mem.indexOfScalar(u8, v, 'x') orelse return error.InvalidCell;
            options.cell_w = try std.fmt.parseInt(u32, v[0..x], 10);
            options.cell_h = try std.fmt.parseInt(u32, v[x + 1 ..], 10);
            if (options.cell_w == 0 or options.cell_h == 0) return error.InvalidCell;
        } else if (std.mem.eql(u8, arg, "--out")) {
            options.out_path = try value(args, &i);
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

fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage: calibrate_font [options]
        \\
        \\options:
        \\  --font path.ttf   font to calibrate (default: a system monospace)
        \\  --cell WxH        cell pixel size (default 8x16)
        \\  --out path.zig    emit a Zig atlas literal
        \\  --help
        \\
    );
}

test "features measure a fully inked cell as full coverage" {
    const cw = 4;
    const ch = 4;
    var cell = [_]u8{255} ** (cw * ch);
    const f = features(&cell, cw, ch);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f.coverage, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f.cx, 0.0001);

    @memset(&cell, 0);
    const empty = features(&cell, cw, ch);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), empty.coverage, 0.0001);
}

test "packMask sets bits for inked pixels" {
    const allocator = std.testing.allocator;
    var masks: std.ArrayList(u8) = .empty;
    defer masks.deinit(allocator);
    const cell = [_]u8{ 255, 0, 200, 0, 0, 0, 0, 0 };
    const len = try packMask(allocator, &masks, &cell, 8, 1);
    try std.testing.expectEqual(@as(u16, 1), len);
    // bits 0 and 2 set -> 0b0000_0101 = 0x05
    try std.testing.expectEqual(@as(u8, 0x05), masks.items[0]);
}
