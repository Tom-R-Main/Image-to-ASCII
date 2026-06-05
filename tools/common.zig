//! Shared helpers for the quality-harness tools.
//!
//! These tools live OUTSIDE the core library on purpose: they may allocate
//! freely, do colorspace math redundantly, read/write files, and (eventually)
//! depend on a font rasterizer. None of this belongs in `src/`. See
//! RESEARCH.md "Testing And Benchmarks" and "Quality Harness".

const std = @import("std");
const ascii = @import("image_to_ascii");

pub const Rgb = ascii.Rgb8;
pub const Rgba = ascii.Rgba8;

/// A simple owned sRGB image buffer used for reconstruction and references.
pub const ImageBuf = struct {
    width: u32,
    height: u32,
    pixels: []Rgb,

    pub fn alloc(allocator: std.mem.Allocator, width: u32, height: u32) !ImageBuf {
        const len = try std.math.mul(usize, width, height);
        return .{ .width = width, .height = height, .pixels = try allocator.alloc(Rgb, len) };
    }

    pub fn deinit(self: *ImageBuf, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn at(self: ImageBuf, x: u32, y: u32) Rgb {
        return self.pixels[@as(usize, y) * self.width + x];
    }

    pub fn set(self: ImageBuf, x: u32, y: u32, value: Rgb) void {
        self.pixels[@as(usize, y) * self.width + x] = value;
    }
};

// --- Colorspace (mirrors src/luma.zig; kept local so tools stay decoupled) ---

pub fn srgbToLinear(channel: u8) f32 {
    const c = @as(f32, @floatFromInt(channel)) / 255.0;
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(channel: f32) u8 {
    const c = std.math.clamp(channel, 0.0, 1.0);
    const srgb = if (c <= 0.0031308)
        c * 12.92
    else
        1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(srgb * 255.0, 0.0, 255.0)));
}

/// sRGB-domain perceptual gray in [0, 1], used by the structural metrics.
pub fn gray(c: Rgb) f32 {
    const r = @as(f32, @floatFromInt(c.r));
    const g = @as(f32, @floatFromInt(c.g));
    const b = @as(f32, @floatFromInt(c.b));
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
}

/// Source crop rectangle (in source pixel coordinates) for a fit mode. This
/// intentionally mirrors `sample.fitMapping` so the reference image is sampled
/// from the same region the renderer saw.
pub const CropRect = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

pub fn cropRectFor(
    image: ascii.ImageView,
    terminal: ascii.TerminalProfile,
    fit: ascii.FitMode,
) CropRect {
    const w = @as(f32, @floatFromInt(image.width));
    const h = @as(f32, @floatFromInt(image.height));
    const full = CropRect{ .x0 = 0.0, .y0 = 0.0, .x1 = w, .y1 = h };
    if (fit != .cover) return full;

    const source_aspect = w / h;
    const terminal_aspect = (@as(f32, @floatFromInt(terminal.columns)) /
        @as(f32, @floatFromInt(terminal.rows))) * terminal.cell_aspect;

    var rect = full;
    if (source_aspect > terminal_aspect) {
        const crop_w = h * terminal_aspect;
        rect.x0 = (w - crop_w) / 2.0;
        rect.x1 = rect.x0 + crop_w;
    } else {
        const crop_h = w / terminal_aspect;
        rect.y0 = (h - crop_h) / 2.0;
        rect.y1 = rect.y0 + crop_h;
    }
    return rect;
}

/// Area-average a (possibly cropped) source image into an `out_w` x `out_h`
/// reference buffer, compositing alpha over `background` and averaging in linear
/// light — matching the renderer's sampling so PSNR is not penalised by a
/// colorspace mismatch.
pub fn resizeReference(
    allocator: std.mem.Allocator,
    image: ascii.ImageView,
    background: Rgb,
    crop: CropRect,
    out_w: u32,
    out_h: u32,
) !ImageBuf {
    var out = try ImageBuf.alloc(allocator, out_w, out_h);
    errdefer out.deinit(allocator);

    const span_x = crop.x1 - crop.x0;
    const span_y = crop.y1 - crop.y0;

    var oy: u32 = 0;
    while (oy < out_h) : (oy += 1) {
        const cy0 = crop.y0 + (@as(f32, @floatFromInt(oy)) * span_y) / @as(f32, @floatFromInt(out_h));
        const cy1 = crop.y0 + (@as(f32, @floatFromInt(oy + 1)) * span_y) / @as(f32, @floatFromInt(out_h));
        var ox: u32 = 0;
        while (ox < out_w) : (ox += 1) {
            const cx0 = crop.x0 + (@as(f32, @floatFromInt(ox)) * span_x) / @as(f32, @floatFromInt(out_w));
            const cx1 = crop.x0 + (@as(f32, @floatFromInt(ox + 1)) * span_x) / @as(f32, @floatFromInt(out_w));
            out.set(ox, oy, areaAverage(image, background, cx0, cy0, cx1, cy1));
        }
    }
    return out;
}

fn areaAverage(image: ascii.ImageView, background: Rgb, x0: f32, y0: f32, x1: f32, y1: f32) Rgb {
    const fw = @as(f32, @floatFromInt(image.width));
    const fh = @as(f32, @floatFromInt(image.height));
    const cx0 = std.math.clamp(x0, 0.0, fw);
    const cy0 = std.math.clamp(y0, 0.0, fh);
    const cx1 = std.math.clamp(x1, cx0, fw);
    const cy1 = std.math.clamp(y1, cy0, fh);

    const sx: u32 = @intFromFloat(@floor(cx0));
    const sy: u32 = @intFromFloat(@floor(cy0));
    const ex: u32 = @max(sx + 1, @as(u32, @intFromFloat(@ceil(cx1))));
    const ey: u32 = @max(sy + 1, @as(u32, @intFromFloat(@ceil(cy1))));

    const row_pixels = image.stride / @sizeOf(Rgba);
    var ar: f32 = 0.0;
    var ag: f32 = 0.0;
    var ab: f32 = 0.0;
    var wsum: f32 = 0.0;

    var y = sy;
    while (y < @min(ey, image.height)) : (y += 1) {
        const py0 = @as(f32, @floatFromInt(y));
        const yo = @max(0.0, @min(py0 + 1.0, cy1) - @max(py0, cy0));
        var x = sx;
        while (x < @min(ex, image.width)) : (x += 1) {
            const px0 = @as(f32, @floatFromInt(x));
            const xo = @max(0.0, @min(px0 + 1.0, cx1) - @max(px0, cx0));
            const weight = xo * yo;
            if (weight == 0.0) continue;
            const src = image.pixels[@as(usize, y) * row_pixels + x];
            const lin = compositeLinear(src, background);
            ar += lin[0] * weight;
            ag += lin[1] * weight;
            ab += lin[2] * weight;
            wsum += weight;
        }
    }

    if (wsum > 0.0) {
        ar /= wsum;
        ag /= wsum;
        ab /= wsum;
    }
    return .{ .r = linearToSrgb(ar), .g = linearToSrgb(ag), .b = linearToSrgb(ab) };
}

pub fn compositeLinear(src: Rgba, background: Rgb) [3]f32 {
    const alpha = @as(f32, @floatFromInt(src.a)) / 255.0;
    const inv = 1.0 - alpha;
    return .{
        srgbToLinear(src.r) * alpha + srgbToLinear(background.r) * inv,
        srgbToLinear(src.g) * alpha + srgbToLinear(background.g) * inv,
        srgbToLinear(src.b) * alpha + srgbToLinear(background.b) * inv,
    };
}

/// Serialise an `ImageBuf` as a binary (P6) PPM into a caller-owned byte slice.
pub fn encodePpm(allocator: std.mem.Allocator, img: ImageBuf) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ img.width, img.height });
    defer allocator.free(header);
    try list.appendSlice(allocator, header);
    for (img.pixels) |p| {
        try list.appendSlice(allocator, &.{ p.r, p.g, p.b });
    }
    return list.toOwnedSlice(allocator);
}

pub fn writePpm(io: std.Io, allocator: std.mem.Allocator, path: []const u8, img: ImageBuf) !void {
    const bytes = try encodePpm(allocator, img);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

test "colorspace round trips at endpoints" {
    try std.testing.expectEqual(@as(u8, 0), linearToSrgb(srgbToLinear(0)));
    try std.testing.expectEqual(@as(u8, 255), linearToSrgb(srgbToLinear(255)));
}

test "encodePpm writes a valid P6 header" {
    const allocator = std.testing.allocator;
    var img = try ImageBuf.alloc(allocator, 1, 1);
    defer img.deinit(allocator);
    img.set(0, 0, .{ .r = 10, .g = 20, .b = 30 });
    const bytes = try encodePpm(allocator, img);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "P6\n1 1\n255\n"));
    try std.testing.expectEqual(@as(u8, 10), bytes[bytes.len - 3]);
}
