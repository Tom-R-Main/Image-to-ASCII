//! Summed-area table (integral image) for luminance, used by monochrome render
//! modes when sampling is the bottleneck.
//!
//! The direct sampler (sample.areaSample) costs O(region) per cell. An integral
//! image makes each cell query O(1). For a single one-shot render this is a wash
//! (building the table is itself an O(image) pass), so the real win is REUSE:
//! build once, then re-query across many output sizes — exactly what a live TUI
//! resize loop does.
//!
//! Two planes are stored as prefix sums over (w+1) x (h+1):
//!   sl[y][x] = sum of (linear_luminance(src) * alpha) over [0,x) x [0,y)
//!    a[y][x] = sum of alpha                          over [0,x) x [0,y)
//!
//! Because luminance is linear and alpha compositing is affine, the average
//! composited linear luminance over a region is:
//!   avg = I_sl/N + bg_luma * (1 - I_a/N)
//! which is exactly what areaSample computes. Querying at fractional coordinates
//! via bilinear interpolation of the prefix planes yields the exact
//! fractional-area integral of the piecewise-constant pixels, so results match
//! the direct sampler to floating-point rounding.

const std = @import("std");

const core = @import("core.zig");
const luma = @import("luma.zig");

pub const IntegralLuma = struct {
    width: usize,
    height: usize,
    stride: usize, // width + 1
    sl: []f64,
    a: []f64,
    bg_luma: f32,

    pub fn build(allocator: std.mem.Allocator, image: core.ImageView, background: core.Rgba8) !IntegralLuma {
        const w: usize = image.width;
        const h: usize = image.height;
        const stride = w + 1;
        const plane_len = try std.math.mul(usize, stride, h + 1);

        const sl = try allocator.alloc(f64, plane_len);
        errdefer allocator.free(sl);
        const a = try allocator.alloc(f64, plane_len);
        errdefer allocator.free(a);

        @memset(sl[0..stride], 0);
        @memset(a[0..stride], 0);

        const row_pixels = image.stride / @sizeOf(core.Rgba8);

        var y: usize = 0;
        while (y < h) : (y += 1) {
            const above = y * stride;
            const here = (y + 1) * stride;
            sl[here] = 0;
            a[here] = 0;
            var run_sl: f64 = 0;
            var run_a: f64 = 0;
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const px = image.pixels[y * row_pixels + x];
                const alpha = @as(f64, @floatFromInt(px.a)) / 255.0;
                const src_luma = luma.luminanceLinear(
                    luma.srgbToLinear(px.r),
                    luma.srgbToLinear(px.g),
                    luma.srgbToLinear(px.b),
                );
                run_sl += @as(f64, src_luma) * alpha;
                run_a += alpha;
                sl[here + x + 1] = sl[above + x + 1] + run_sl;
                a[here + x + 1] = a[above + x + 1] + run_a;
            }
        }

        const bg_luma = luma.luminanceLinear(
            luma.srgbToLinear(background.r),
            luma.srgbToLinear(background.g),
            luma.srgbToLinear(background.b),
        );

        return .{ .width = w, .height = h, .stride = stride, .sl = sl, .a = a, .bg_luma = bg_luma };
    }

    pub fn deinit(self: *IntegralLuma, allocator: std.mem.Allocator) void {
        allocator.free(self.sl);
        allocator.free(self.a);
        self.* = undefined;
    }

    /// Average perceptual luma over the (fractional) source region, matching
    /// sample.areaSample(...).luma.
    pub fn regionLuma(self: *const IntegralLuma, x0: f32, y0: f32, x1: f32, y1: f32) f32 {
        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);
        const cx0 = std.math.clamp(x0, 0.0, fw);
        const cy0 = std.math.clamp(y0, 0.0, fh);
        const cx1 = std.math.clamp(x1, cx0, fw);
        const cy1 = std.math.clamp(y1, cy0, fh);

        const area = (cx1 - cx0) * (cy1 - cy0);
        if (area <= 0.0) return 0.0;

        const i_sl = boxIntegral(self.sl, self.stride, cx0, cy0, cx1, cy1);
        const i_a = boxIntegral(self.a, self.stride, cx0, cy0, cx1, cy1);
        const n: f64 = @floatCast(area);

        const avg_src = i_sl / n;
        const avg_alpha = i_a / n;
        const avg_linear = avg_src + @as(f64, self.bg_luma) * (1.0 - avg_alpha);
        return luma.perceptualGamma(@floatCast(avg_linear));
    }
};

fn boxIntegral(plane: []const f64, stride: usize, x0: f32, y0: f32, x1: f32, y1: f32) f64 {
    return bilinear(plane, stride, x1, y1) - bilinear(plane, stride, x1, y0) -
        bilinear(plane, stride, x0, y1) + bilinear(plane, stride, x0, y0);
}

/// Bilinearly interpolate a prefix-sum plane at fractional coordinates. For the
/// piecewise-constant pixel function this is the exact area integral over
/// [0,fx) x [0,fy), not an approximation.
fn bilinear(plane: []const f64, stride: usize, fx: f32, fy: f32) f64 {
    const max_x = stride - 1; // == width
    const max_y = (plane.len / stride) - 1; // == height

    var ix: usize = @intFromFloat(@floor(fx));
    var iy: usize = @intFromFloat(@floor(fy));
    var tx: f64 = @floatCast(fx - @floor(fx));
    var ty: f64 = @floatCast(fy - @floor(fy));
    if (ix >= max_x) {
        ix = max_x - 1;
        tx = 1.0;
    }
    if (iy >= max_y) {
        iy = max_y - 1;
        ty = 1.0;
    }

    const p00 = plane[iy * stride + ix];
    const p10 = plane[iy * stride + ix + 1];
    const p01 = plane[(iy + 1) * stride + ix];
    const p11 = plane[(iy + 1) * stride + ix + 1];

    const top = p00 + (p10 - p00) * tx;
    const bot = p01 + (p11 - p01) * tx;
    return top + (bot - top) * ty;
}

test "integral luma matches the direct sampler" {
    const sample = @import("sample.zig");
    const allocator = std.testing.allocator;

    // A small non-trivial image with varied colors and one translucent pixel.
    const pixels = [_]core.Rgba8{
        .{ .r = 10, .g = 200, .b = 30, .a = 255 },
        .{ .r = 240, .g = 20, .b = 60, .a = 255 },
        .{ .r = 5, .g = 5, .b = 250, .a = 128 },
        .{ .r = 128, .g = 128, .b = 128, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    const image = core.ImageView{ .width = 3, .height = 2, .stride = 3 * @sizeOf(core.Rgba8), .pixels = &pixels };
    const terminal = core.TerminalProfile{ .columns = 1, .rows = 1, .background = .{ .r = 40, .g = 60, .b = 80, .a = 255 } };

    var integral = try IntegralLuma.build(allocator, image, terminal.background);
    defer integral.deinit(allocator);

    const regions = [_][4]f32{
        .{ 0.0, 0.0, 3.0, 2.0 },
        .{ 0.0, 0.0, 1.5, 1.0 },
        .{ 0.7, 0.3, 2.4, 1.8 },
        .{ 1.0, 0.0, 3.0, 2.0 },
    };
    for (regions) |r| {
        const direct = sample.areaSample(image, terminal, r[0], r[1], r[2], r[3]).luma;
        const fast = integral.regionLuma(r[0], r[1], r[2], r[3]);
        try std.testing.expectApproxEqAbs(direct, fast, 1e-4);
    }
}
