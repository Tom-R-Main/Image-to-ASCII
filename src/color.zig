const std = @import("std");

const luma = @import("luma.zig");
const pixel = @import("pixel.zig");

pub const LinearRgb = struct {
    r: f32,
    g: f32,
    b: f32,
};

/// Policy for collapsing a set of subcell samples into one representative color
/// for a two-color symbol family (half-block, quadrant, sextant, octant, glyph).
///
/// Per RESEARCH.md "Color Strategy": prefer `median` for line art and
/// hard-edged content, and `trimmed_mean` as the cheaper default for
/// photographic content. Plain `mean` is offered for completeness but bleeds
/// edge colors into fills, so it is not the default.
pub const ColorStat = enum {
    mean,
    trimmed_mean,
    median,
};

/// Upper bound on the number of subcell samples handled without falling back to
/// the mean. The largest binary partition family (2x4 braille/octant) has 8
/// subcells, so this covers every current and planned table-driven family.
const max_set = 8;

/// Collapse a set of linear-light samples into a single representative color
/// using the requested statistic. Operates entirely on the stack; never
/// allocates. Sets larger than `max_set` fall back to the mean.
pub fn representative(samples: []const LinearRgb, stat: ColorStat) LinearRgb {
    if (samples.len == 0) return .{ .r = 0.0, .g = 0.0, .b = 0.0 };
    if (samples.len == 1) return samples[0];
    return switch (stat) {
        .mean => meanColor(samples),
        .trimmed_mean => trimmedMeanColor(samples),
        .median => medianColor(samples),
    };
}

fn meanColor(samples: []const LinearRgb) LinearRgb {
    var acc = LinearRgb{ .r = 0.0, .g = 0.0, .b = 0.0 };
    for (samples) |s| {
        acc.r += s.r;
        acc.g += s.g;
        acc.b += s.b;
    }
    const denom = @as(f32, @floatFromInt(samples.len));
    return .{ .r = acc.r / denom, .g = acc.g / denom, .b = acc.b / denom };
}

/// Per-channel median. Robust against a single outlier subcell (e.g. an edge
/// pixel) dominating an otherwise flat fill.
fn medianColor(samples: []const LinearRgb) LinearRgb {
    const n = samples.len;
    if (n > max_set) return meanColor(samples);

    var rs: [max_set]f32 = undefined;
    var gs: [max_set]f32 = undefined;
    var bs: [max_set]f32 = undefined;
    for (samples, 0..) |s, i| {
        rs[i] = s.r;
        gs[i] = s.g;
        bs[i] = s.b;
    }
    return .{
        .r = median1(rs[0..n]),
        .g = median1(gs[0..n]),
        .b = median1(bs[0..n]),
    };
}

fn median1(xs: []f32) f32 {
    std.mem.sort(f32, xs, {}, std.sort.asc(f32));
    const mid = xs.len / 2;
    if (xs.len % 2 == 1) return xs[mid];
    return (xs[mid - 1] + xs[mid]) / 2.0;
}

/// Drop the darkest and brightest sample (by linear luminance) and average the
/// rest. Cheaper than a full sort-of-vectors median while still rejecting the
/// extreme that would otherwise bleed into the fill.
fn trimmedMeanColor(samples: []const LinearRgb) LinearRgb {
    const n = samples.len;
    if (n <= 2 or n > max_set) return meanColor(samples);

    const Keyed = struct { lum: f32, c: LinearRgb };
    var buf: [max_set]Keyed = undefined;
    for (samples, 0..) |s, i| {
        buf[i] = .{ .lum = luma.luminanceLinear(s.r, s.g, s.b), .c = s };
    }
    std.mem.sort(Keyed, buf[0..n], {}, struct {
        fn lessThan(_: void, a: Keyed, b: Keyed) bool {
            return a.lum < b.lum;
        }
    }.lessThan);

    var acc = LinearRgb{ .r = 0.0, .g = 0.0, .b = 0.0 };
    var i: usize = 1;
    while (i < n - 1) : (i += 1) {
        acc.r += buf[i].c.r;
        acc.g += buf[i].c.g;
        acc.b += buf[i].c.b;
    }
    const denom = @as(f32, @floatFromInt(n - 2));
    return .{ .r = acc.r / denom, .g = acc.g / denom, .b = acc.b / denom };
}

pub fn compositeOver(src: pixel.Rgba8, background: pixel.Rgba8) LinearRgb {
    const alpha = @as(f32, @floatFromInt(src.a)) / 255.0;
    const inv_alpha = 1.0 - alpha;

    return .{
        .r = luma.srgbToLinear(src.r) * alpha + luma.srgbToLinear(background.r) * inv_alpha,
        .g = luma.srgbToLinear(src.g) * alpha + luma.srgbToLinear(background.g) * inv_alpha,
        .b = luma.srgbToLinear(src.b) * alpha + luma.srgbToLinear(background.b) * inv_alpha,
    };
}

pub fn encodeSrgb(rgb: LinearRgb) pixel.Rgb8 {
    return .{
        .r = luma.linearToSrgb(rgb.r),
        .g = luma.linearToSrgb(rgb.g),
        .b = luma.linearToSrgb(rgb.b),
    };
}

pub fn rgbFromRgba(src: pixel.Rgba8, background: pixel.Rgba8) pixel.Rgb8 {
    return encodeSrgb(compositeOver(src, background));
}

test "opaque composite preserves source" {
    const out = rgbFromRgba(
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 255, .a = 255 },
    );
    try @import("std").testing.expectEqual(@as(u8, 255), out.r);
    try @import("std").testing.expectEqual(@as(u8, 0), out.b);
}

test "trimmed mean and median reject an outlier the plain mean does not" {
    // Three near-black fill samples plus one bright outlier (an edge pixel).
    const samples = [_]LinearRgb{
        .{ .r = 0.10, .g = 0.10, .b = 0.10 },
        .{ .r = 0.12, .g = 0.12, .b = 0.12 },
        .{ .r = 0.11, .g = 0.11, .b = 0.11 },
        .{ .r = 1.00, .g = 1.00, .b = 1.00 },
    };

    const mean = representative(&samples, .mean);
    const trimmed = representative(&samples, .trimmed_mean);
    const median = representative(&samples, .median);

    // The plain mean is dragged up toward the outlier...
    try std.testing.expect(mean.r > 0.25);
    // ...while the robust statistics stay near the fill color.
    try std.testing.expect(trimmed.r < 0.15);
    try std.testing.expect(median.r < 0.15);
}

test "representative handles trivial sets" {
    const one = [_]LinearRgb{.{ .r = 0.4, .g = 0.5, .b = 0.6 }};
    const r = representative(&one, .trimmed_mean);
    try std.testing.expectEqual(@as(f32, 0.4), r.r);

    const empty: []const LinearRgb = &.{};
    const z = representative(empty, .median);
    try std.testing.expectEqual(@as(f32, 0.0), z.r);
}
