const luma = @import("luma.zig");
const pixel = @import("pixel.zig");

pub const LinearRgb = struct {
    r: f32,
    g: f32,
    b: f32,
};

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
