const std = @import("std");

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

pub fn luminanceLinear(r: f32, g: f32, b: f32) f32 {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

pub fn perceptualLuminance(r: f32, g: f32, b: f32) f32 {
    const y = luminanceLinear(r, g, b);
    return std.math.pow(f32, std.math.clamp(y, 0.0, 1.0), 1.0 / 2.2);
}

pub fn applyAdjustments(value: f32, contrast: f32, brightness: f32, invert: bool) f32 {
    var adjusted = (value - 0.5) * contrast + 0.5 + brightness;
    adjusted = std.math.clamp(adjusted, 0.0, 1.0);
    return if (invert) 1.0 - adjusted else adjusted;
}

test "sRGB endpoints round trip" {
    try std.testing.expectEqual(@as(u8, 0), linearToSrgb(srgbToLinear(0)));
    try std.testing.expectEqual(@as(u8, 255), linearToSrgb(srgbToLinear(255)));
}

test "luminance endpoints" {
    try std.testing.expectEqual(@as(f32, 0.0), luminanceLinear(0.0, 0.0, 0.0));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), luminanceLinear(1.0, 1.0, 1.0), 0.0001);
}
