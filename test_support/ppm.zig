const std = @import("std");
const ascii = @import("image_to_ascii");

pub const DecodeError = error{
    UnsupportedFormat,
    InvalidHeader,
    InvalidDimensions,
    InvalidMaxValue,
    InvalidRaster,
};

const Tokenizer = struct {
    data: []const u8,
    index: usize = 0,

    fn next(self: *Tokenizer) ?[]const u8 {
        self.skipSpaceAndComments();
        if (self.index >= self.data.len) return null;

        const start = self.index;
        while (self.index < self.data.len and !isWhitespace(self.data[self.index])) {
            self.index += 1;
        }
        return self.data[start..self.index];
    }

    fn consumeRasterSeparator(self: *Tokenizer) DecodeError!void {
        if (self.index >= self.data.len or !isWhitespace(self.data[self.index])) {
            return DecodeError.InvalidRaster;
        }
        self.index += 1;
    }

    fn skipSpaceAndComments(self: *Tokenizer) void {
        while (self.index < self.data.len) {
            while (self.index < self.data.len and isWhitespace(self.data[self.index])) {
                self.index += 1;
            }
            if (self.index < self.data.len and self.data[self.index] == '#') {
                while (self.index < self.data.len and self.data[self.index] != '\n') {
                    self.index += 1;
                }
                continue;
            }
            break;
        }
    }
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !ascii.ImageView {
    var tokenizer = Tokenizer{ .data = data };
    const magic = tokenizer.next() orelse return DecodeError.InvalidHeader;

    if (std.mem.eql(u8, magic, "P3")) return decodeP3(allocator, &tokenizer);
    if (std.mem.eql(u8, magic, "P6")) return decodeP6(allocator, &tokenizer);
    if (std.mem.eql(u8, magic, "P7")) return decodePam(allocator, data);

    return DecodeError.UnsupportedFormat;
}

fn decodeP3(allocator: std.mem.Allocator, tokenizer: *Tokenizer) !ascii.ImageView {
    const width = try parseDimension(tokenizer.next() orelse return DecodeError.InvalidHeader);
    const height = try parseDimension(tokenizer.next() orelse return DecodeError.InvalidHeader);
    const max_value = try parseMaxValue(tokenizer.next() orelse return DecodeError.InvalidHeader);
    _ = max_value;

    const pixels = try allocator.alloc(ascii.Rgba8, try std.math.mul(usize, width, height));
    errdefer allocator.free(pixels);

    for (pixels) |*pixel| {
        pixel.* = .{
            .r = try parseChannel(tokenizer.next() orelse return DecodeError.InvalidRaster),
            .g = try parseChannel(tokenizer.next() orelse return DecodeError.InvalidRaster),
            .b = try parseChannel(tokenizer.next() orelse return DecodeError.InvalidRaster),
            .a = 255,
        };
    }

    return imageFromPixels(width, height, pixels);
}

fn decodeP6(allocator: std.mem.Allocator, tokenizer: *Tokenizer) !ascii.ImageView {
    const width = try parseDimension(tokenizer.next() orelse return DecodeError.InvalidHeader);
    const height = try parseDimension(tokenizer.next() orelse return DecodeError.InvalidHeader);
    _ = try parseMaxValue(tokenizer.next() orelse return DecodeError.InvalidHeader);
    try tokenizer.consumeRasterSeparator();

    const count = try std.math.mul(usize, width, height);
    const raster_len = try std.math.mul(usize, count, 3);
    if (tokenizer.index + raster_len > tokenizer.data.len) return DecodeError.InvalidRaster;

    const pixels = try allocator.alloc(ascii.Rgba8, count);
    errdefer allocator.free(pixels);

    const raster = tokenizer.data[tokenizer.index .. tokenizer.index + raster_len];
    for (pixels, 0..) |*pixel, i| {
        const offset = i * 3;
        pixel.* = .{
            .r = raster[offset],
            .g = raster[offset + 1],
            .b = raster[offset + 2],
            .a = 255,
        };
    }

    return imageFromPixels(width, height, pixels);
}

fn decodePam(allocator: std.mem.Allocator, data: []const u8) !ascii.ImageView {
    var width: ?u32 = null;
    var height: ?u32 = null;
    var depth: ?u32 = null;
    var max_value: ?u32 = null;
    var raster_start: ?usize = null;

    var line_start: usize = 0;
    while (line_start < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, line_start, '\n') orelse data.len;
        const raw_line = data[line_start..line_end];
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        line_start = if (line_end < data.len) line_end + 1 else data.len;

        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "P7")) continue;
        if (std.mem.eql(u8, line, "ENDHDR")) {
            raster_start = line_start;
            break;
        }

        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const key = parts.next() orelse return DecodeError.InvalidHeader;
        const value = parts.next() orelse return DecodeError.InvalidHeader;

        if (std.mem.eql(u8, key, "WIDTH")) {
            width = try parseDimension(value);
        } else if (std.mem.eql(u8, key, "HEIGHT")) {
            height = try parseDimension(value);
        } else if (std.mem.eql(u8, key, "DEPTH")) {
            depth = try parseDimension(value);
        } else if (std.mem.eql(u8, key, "MAXVAL")) {
            max_value = try parseMaxValue(value);
        }
    }

    const w = width orelse return DecodeError.InvalidHeader;
    const h = height orelse return DecodeError.InvalidHeader;
    const d = depth orelse return DecodeError.InvalidHeader;
    _ = max_value orelse return DecodeError.InvalidHeader;
    const start = raster_start orelse return DecodeError.InvalidHeader;
    if (d != 3 and d != 4) return DecodeError.InvalidHeader;

    const count = try std.math.mul(usize, w, h);
    const raster_len = try std.math.mul(usize, count, d);
    if (start + raster_len > data.len) return DecodeError.InvalidRaster;

    const pixels = try allocator.alloc(ascii.Rgba8, count);
    errdefer allocator.free(pixels);

    const raster = data[start .. start + raster_len];
    for (pixels, 0..) |*pixel, i| {
        const offset = i * d;
        pixel.* = .{
            .r = raster[offset],
            .g = raster[offset + 1],
            .b = raster[offset + 2],
            .a = if (d == 4) raster[offset + 3] else 255,
        };
    }

    return imageFromPixels(w, h, pixels);
}

fn imageFromPixels(width: u32, height: u32, pixels: []const ascii.Rgba8) ascii.ImageView {
    return .{
        .width = width,
        .height = height,
        .stride = @as(usize, width) * @sizeOf(ascii.Rgba8),
        .pixels = pixels,
    };
}

fn parseDimension(token: []const u8) DecodeError!u32 {
    const value = std.fmt.parseInt(u32, token, 10) catch return DecodeError.InvalidDimensions;
    if (value == 0) return DecodeError.InvalidDimensions;
    return value;
}

fn parseMaxValue(token: []const u8) DecodeError!u32 {
    const value = std.fmt.parseInt(u32, token, 10) catch return DecodeError.InvalidMaxValue;
    if (value != 255) return DecodeError.InvalidMaxValue;
    return value;
}

fn parseChannel(token: []const u8) DecodeError!u8 {
    const value = std.fmt.parseInt(u16, token, 10) catch return DecodeError.InvalidRaster;
    if (value > 255) return DecodeError.InvalidRaster;
    return @intCast(value);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

test "decodes ascii PPM" {
    const data =
        \\P3
        \\2 1
        \\255
        \\255 0 0 0 0 255
        \\
    ;

    const allocator = std.testing.allocator;
    const image = try decode(allocator, data);
    defer allocator.free(image.pixels);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqual(@as(u8, 255), image.pixels[0].r);
    try std.testing.expectEqual(@as(u8, 255), image.pixels[1].b);
}

test "rejects unsupported magic" {
    try std.testing.expectError(DecodeError.UnsupportedFormat, decode(std.testing.allocator, "P9\n"));
}
