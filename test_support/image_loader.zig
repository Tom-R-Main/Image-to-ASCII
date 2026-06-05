const std = @import("std");
const ascii = @import("image_to_ascii");
const ppm = @import("ppm_support");
const zigimg = @import("zigimg");

pub const Adapter = enum {
    ppm_support,
    zigimg,
};

pub const Format = enum {
    ppm,
    pam,
    png,
    jpeg,
};

pub const DecodeError = error{
    UnsupportedFormat,
    UnsupportedPixelFormat,
    ImageTooLarge,
};

pub const LoadedImage = struct {
    pixels: []const ascii.Rgba8,
    width: u32,
    height: u32,
    stride: usize,
    adapter: Adapter,
    format: Format,
    pixel_format_name: []const u8,

    pub fn imageView(self: *const LoadedImage) ascii.ImageView {
        return .{
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
            .pixels = self.pixels,
        };
    }

    pub fn deinit(self: *LoadedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn loadPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedImage {
    const format = extensionFormat(path) orelse return DecodeError.UnsupportedFormat;
    return switch (format) {
        .ppm, .pam => loadPpmLike(io, allocator, path, format),
        .png, .jpeg => loadZigimg(io, allocator, path, format),
    };
}

pub fn extensionFormat(path: []const u8) ?Format {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".ppm")) return .ppm;
    if (std.ascii.eqlIgnoreCase(ext, ".pam")) return .pam;
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
    if (std.ascii.eqlIgnoreCase(ext, ".jpg")) return .jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".jpeg")) return .jpeg;
    return null;
}

fn loadPpmLike(io: std.Io, allocator: std.mem.Allocator, path: []const u8, format: Format) !LoadedImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    const image = try ppm.decode(allocator, bytes);
    return .{
        .pixels = image.pixels,
        .width = image.width,
        .height = image.height,
        .stride = image.stride,
        .adapter = .ppm_support,
        .format = format,
        .pixel_format_name = "rgba8",
    };
}

fn loadZigimg(io: std.Io, allocator: std.mem.Allocator, path: []const u8, format: Format) !LoadedImage {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var image = try zigimg.Image.fromFilePath(allocator, io, path, read_buffer[0..]);
    defer image.deinit(allocator);

    const original_pixel_format = image.pixelFormat();
    try image.convert(allocator, .rgba32);

    const count = try checkedPixelCount(image.width, image.height);
    const pixels = try allocator.alloc(ascii.Rgba8, count);
    errdefer allocator.free(pixels);

    const raw = image.rawBytes();
    if (raw.len != pixels.len * @sizeOf(ascii.Rgba8)) return DecodeError.UnsupportedPixelFormat;
    const decoded = std.mem.bytesAsSlice(ascii.Rgba8, raw);
    @memcpy(pixels, decoded);

    const width = try intCastU32(image.width);
    return .{
        .pixels = pixels,
        .width = width,
        .height = try intCastU32(image.height),
        .stride = width * @sizeOf(ascii.Rgba8),
        .adapter = .zigimg,
        .format = format,
        .pixel_format_name = @tagName(original_pixel_format),
    };
}

fn checkedPixelCount(width: usize, height: usize) !usize {
    if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return DecodeError.ImageTooLarge;
    return std.math.mul(usize, width, height) catch DecodeError.ImageTooLarge;
}

fn intCastU32(value: usize) !u32 {
    if (value > std.math.maxInt(u32)) return DecodeError.ImageTooLarge;
    return @intCast(value);
}

pub fn adapterName(adapter: Adapter) []const u8 {
    return @tagName(adapter);
}

pub fn formatName(format: Format) []const u8 {
    return @tagName(format);
}

test "detects supported extensions case-insensitively" {
    try std.testing.expectEqual(Format.ppm, extensionFormat("a.PPM").?);
    try std.testing.expectEqual(Format.pam, extensionFormat("a.pam").?);
    try std.testing.expectEqual(Format.png, extensionFormat("a.PNG").?);
    try std.testing.expectEqual(Format.jpeg, extensionFormat("a.jpg").?);
    try std.testing.expectEqual(Format.jpeg, extensionFormat("a.JPEG").?);
    try std.testing.expect(extensionFormat("a.webp") == null);
}
