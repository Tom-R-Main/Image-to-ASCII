//! Image-quality metrics for the render-compare harness.
//!
//! These are coarse, dependency-free metrics intended to make scorer and mode
//! changes measurable (RESEARCH.md "Quality harness"): PSNR for raw fidelity,
//! a windowed SSIM for structural similarity, and a Sobel-gradient correlation
//! as an edge-preservation proxy for line art and UI screenshots.

const std = @import("std");
const common = @import("common.zig");

const ImageBuf = common.ImageBuf;

pub const Report = struct {
    width: u32,
    height: u32,
    mse: f64,
    psnr_db: f64,
    ssim: f64,
    edge_correlation: f64,
};

pub fn compare(allocator: std.mem.Allocator, reference: ImageBuf, actual: ImageBuf) !Report {
    std.debug.assert(reference.width == actual.width and reference.height == actual.height);
    return .{
        .width = reference.width,
        .height = reference.height,
        .mse = meanSquaredError(reference, actual),
        .psnr_db = psnr(meanSquaredError(reference, actual)),
        .ssim = try ssim(allocator, reference, actual),
        .edge_correlation = try edgeCorrelation(allocator, reference, actual),
    };
}

pub fn meanSquaredError(a: ImageBuf, b: ImageBuf) f64 {
    var sum: f64 = 0.0;
    for (a.pixels, b.pixels) |pa, pb| {
        const dr = @as(f64, @floatFromInt(@as(i32, pa.r) - @as(i32, pb.r)));
        const dg = @as(f64, @floatFromInt(@as(i32, pa.g) - @as(i32, pb.g)));
        const db = @as(f64, @floatFromInt(@as(i32, pa.b) - @as(i32, pb.b)));
        sum += dr * dr + dg * dg + db * db;
    }
    const n = @as(f64, @floatFromInt(a.pixels.len * 3));
    return if (n == 0.0) 0.0 else sum / n;
}

pub fn psnr(mse: f64) f64 {
    if (mse <= 0.0) return std.math.inf(f64);
    return 10.0 * std.math.log10(255.0 * 255.0 / mse);
}

/// Mean SSIM over 8x8 windows (or a single window for tiny images). Operates on
/// perceptual gray in [0, 1].
pub fn ssim(allocator: std.mem.Allocator, a: ImageBuf, b: ImageBuf) !f64 {
    const ga = try grayPlane(allocator, a);
    defer allocator.free(ga);
    const gb = try grayPlane(allocator, b);
    defer allocator.free(gb);

    const c1 = 0.01 * 0.01;
    const c2 = 0.03 * 0.03;
    const win = 8;

    var acc: f64 = 0.0;
    var windows: usize = 0;

    var wy: u32 = 0;
    while (wy < a.height) : (wy += win) {
        var wx: u32 = 0;
        while (wx < a.width) : (wx += win) {
            const ey = @min(wy + win, a.height);
            const ex = @min(wx + win, a.width);

            var mean_a: f64 = 0.0;
            var mean_b: f64 = 0.0;
            var count: f64 = 0.0;
            var y = wy;
            while (y < ey) : (y += 1) {
                var x = wx;
                while (x < ex) : (x += 1) {
                    mean_a += ga[@as(usize, y) * a.width + x];
                    mean_b += gb[@as(usize, y) * a.width + x];
                    count += 1.0;
                }
            }
            if (count == 0.0) continue;
            mean_a /= count;
            mean_b /= count;

            var var_a: f64 = 0.0;
            var var_b: f64 = 0.0;
            var cov: f64 = 0.0;
            y = wy;
            while (y < ey) : (y += 1) {
                var x = wx;
                while (x < ex) : (x += 1) {
                    const da = ga[@as(usize, y) * a.width + x] - mean_a;
                    const db = gb[@as(usize, y) * a.width + x] - mean_b;
                    var_a += da * da;
                    var_b += db * db;
                    cov += da * db;
                }
            }
            var_a /= count;
            var_b /= count;
            cov /= count;

            const numerator = (2.0 * mean_a * mean_b + c1) * (2.0 * cov + c2);
            const denominator = (mean_a * mean_a + mean_b * mean_b + c1) * (var_a + var_b + c2);
            acc += numerator / denominator;
            windows += 1;
        }
    }

    return if (windows == 0) 1.0 else acc / @as(f64, @floatFromInt(windows));
}

/// Pearson correlation of Sobel gradient magnitudes — a cheap edge-preservation
/// score. 1.0 means edges line up; ~0 means structure was lost.
pub fn edgeCorrelation(allocator: std.mem.Allocator, a: ImageBuf, b: ImageBuf) !f64 {
    if (a.width < 3 or a.height < 3) return 1.0;

    const ga = try grayPlane(allocator, a);
    defer allocator.free(ga);
    const gb = try grayPlane(allocator, b);
    defer allocator.free(gb);

    const inner = @as(usize, a.width - 2) * @as(usize, a.height - 2);
    const ma = try allocator.alloc(f64, inner);
    defer allocator.free(ma);
    const mb = try allocator.alloc(f64, inner);
    defer allocator.free(mb);

    sobelMagnitude(ga, a.width, a.height, ma);
    sobelMagnitude(gb, a.width, a.height, mb);

    return pearson(ma, mb);
}

fn grayPlane(allocator: std.mem.Allocator, img: ImageBuf) ![]f64 {
    const plane = try allocator.alloc(f64, img.pixels.len);
    for (img.pixels, 0..) |p, i| plane[i] = common.gray(p);
    return plane;
}

fn sobelMagnitude(g: []const f64, width: u32, height: u32, out: []f64) void {
    var oi: usize = 0;
    var y: u32 = 1;
    while (y < height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < width - 1) : (x += 1) {
            const p = struct {
                fn at(plane: []const f64, w: u32, xx: u32, yy: u32) f64 {
                    return plane[@as(usize, yy) * w + xx];
                }
            };
            const tl = p.at(g, width, x - 1, y - 1);
            const tm = p.at(g, width, x, y - 1);
            const tr = p.at(g, width, x + 1, y - 1);
            const ml = p.at(g, width, x - 1, y);
            const mr = p.at(g, width, x + 1, y);
            const bl = p.at(g, width, x - 1, y + 1);
            const bm = p.at(g, width, x, y + 1);
            const br = p.at(g, width, x + 1, y + 1);

            const gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
            const gy = (bl + 2.0 * bm + br) - (tl + 2.0 * tm + tr);
            out[oi] = @sqrt(gx * gx + gy * gy);
            oi += 1;
        }
    }
}

fn pearson(a: []const f64, b: []const f64) f64 {
    const n = @as(f64, @floatFromInt(a.len));
    if (n == 0.0) return 1.0;

    var mean_a: f64 = 0.0;
    var mean_b: f64 = 0.0;
    for (a, b) |va, vb| {
        mean_a += va;
        mean_b += vb;
    }
    mean_a /= n;
    mean_b /= n;

    var cov: f64 = 0.0;
    var var_a: f64 = 0.0;
    var var_b: f64 = 0.0;
    for (a, b) |va, vb| {
        const da = va - mean_a;
        const db = vb - mean_b;
        cov += da * db;
        var_a += da * da;
        var_b += db * db;
    }
    const denom = @sqrt(var_a * var_b);
    if (denom == 0.0) return 1.0; // both flat -> perfectly correlated
    return cov / denom;
}

test "identical images score perfectly" {
    const allocator = std.testing.allocator;
    var img = try ImageBuf.alloc(allocator, 16, 16);
    defer img.deinit(allocator);
    for (img.pixels, 0..) |*p, i| {
        const v: u8 = @intCast(i % 256);
        p.* = .{ .r = v, .g = v, .b = v };
    }

    const report = try compare(allocator, img, img);
    try std.testing.expectEqual(@as(f64, 0.0), report.mse);
    try std.testing.expect(std.math.isInf(report.psnr_db));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), report.ssim, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), report.edge_correlation, 0.0001);
}

test "different images score worse than identical" {
    const allocator = std.testing.allocator;
    var ref = try ImageBuf.alloc(allocator, 16, 16);
    defer ref.deinit(allocator);
    var act = try ImageBuf.alloc(allocator, 16, 16);
    defer act.deinit(allocator);
    for (ref.pixels, act.pixels, 0..) |*r, *a, i| {
        const v: u8 = @intCast(i % 256);
        r.* = .{ .r = v, .g = v, .b = v };
        a.* = .{ .r = 255 - v, .g = v, .b = v };
    }

    const report = try compare(allocator, ref, act);
    try std.testing.expect(report.mse > 0.0);
    try std.testing.expect(report.psnr_db < 100.0);
    try std.testing.expect(report.ssim < 1.0);
}
