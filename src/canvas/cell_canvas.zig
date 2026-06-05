const std = @import("std");

const core = @import("../core.zig");
const glyph = @import("glyph_set.zig");
const joins = @import("line_join.zig");

pub const GlyphSet = glyph.GlyphSet;
pub const Stroke = joins.Stroke;

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const TextOptions = struct {
    fg: core.Rgb8 = white,
    bg: core.Rgb8 = black,
};

pub const BoxOptions = struct {
    glyph_set: GlyphSet = .unicode_box,
    stroke: Stroke = .light,
    fg: core.Rgb8 = white,
    bg: core.Rgb8 = black,
};

pub const LineOptions = struct {
    glyph_set: GlyphSet = .unicode_box,
    stroke: Stroke = .light,
    fg: core.Rgb8 = white,
    bg: core.Rgb8 = black,
};

pub const ArrowOptions = struct {
    glyph_set: GlyphSet = .unicode_box,
    stroke: Stroke = .light,
    fg: core.Rgb8 = white,
    bg: core.Rgb8 = black,
};

const white: core.Rgb8 = .{ .r = 255, .g = 255, .b = 255 };
const black: core.Rgb8 = .{ .r = 0, .g = 0, .b = 0 };

pub const CellCanvas = struct {
    columns: u32 = 0,
    rows: u32 = 0,
    color: core.ColorMode = .truecolor,
    codepoints: []u21 = @constCast(&[_]u21{}),
    fg: []core.Rgb8 = @constCast(&[_]core.Rgb8{}),
    bg: []core.Rgb8 = @constCast(&[_]core.Rgb8{}),
    line_masks: []u4 = @constCast(&[_]u4{}),

    pub const empty = CellCanvas{};

    pub fn init(allocator: std.mem.Allocator, columns: u32, rows: u32, color: core.ColorMode) !CellCanvas {
        var canvas: CellCanvas = .empty;
        errdefer canvas.deinit(allocator);
        try canvas.ensureCapacity(allocator, columns, rows, color);
        canvas.clear();
        return canvas;
    }

    pub fn ensureCapacity(self: *CellCanvas, allocator: std.mem.Allocator, columns: u32, rows: u32, color: core.ColorMode) !void {
        const len = try std.math.mul(usize, columns, rows);
        const color_len = if (color == .none) 0 else len;

        if (self.codepoints.len != len) {
            self.codepoints = try allocator.realloc(self.codepoints, len);
        }
        if (self.fg.len != color_len) {
            self.fg = try allocator.realloc(self.fg, color_len);
        }
        if (self.bg.len != color_len) {
            self.bg = try allocator.realloc(self.bg, color_len);
        }
        if (self.line_masks.len != len) {
            self.line_masks = try allocator.realloc(self.line_masks, len);
        }

        self.columns = columns;
        self.rows = rows;
        self.color = color;
    }

    pub fn deinit(self: *CellCanvas, allocator: std.mem.Allocator) void {
        allocator.free(self.codepoints);
        allocator.free(self.fg);
        allocator.free(self.bg);
        allocator.free(self.line_masks);
        self.* = .empty;
    }

    pub fn clear(self: *CellCanvas) void {
        @memset(self.codepoints, ' ');
        @memset(self.line_masks, 0);
        if (self.color != .none) {
            @memset(self.fg, white);
            @memset(self.bg, black);
        }
    }

    pub fn drawText(self: *CellCanvas, x: i32, y: i32, text: []const u8, opts: TextOptions) !void {
        if (y < 0 or y >= @as(i32, @intCast(self.rows))) return;

        var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
        var it = view.iterator();
        var col = x;
        while (it.nextCodepoint()) |cp| : (col += 1) {
            if (col < 0) continue;
            if (col >= @as(i32, @intCast(self.columns))) break;
            self.putCodepoint(col, y, cp, opts.fg, opts.bg);
        }
    }

    pub fn drawBox(self: *CellCanvas, rect: Rect, opts: BoxOptions) !void {
        if (rect.width == 0 or rect.height == 0) return;

        const right = rect.x + @as(i32, @intCast(rect.width)) - 1;
        const bottom = rect.y + @as(i32, @intCast(rect.height)) - 1;

        const line_opts: LineOptions = .{
            .glyph_set = opts.glyph_set,
            .stroke = opts.stroke,
            .fg = opts.fg,
            .bg = opts.bg,
        };

        if (rect.width == 1 and rect.height == 1) {
            self.addLineMask(rect.x, rect.y, joins.east | joins.south | joins.west | joins.north, opts.glyph_set, opts.stroke, opts.fg, opts.bg);
            return;
        }

        if (rect.width == 1) {
            try self.drawLine(.{ .x = rect.x, .y = rect.y }, .{ .x = rect.x, .y = bottom }, line_opts);
            return;
        }

        if (rect.height == 1) {
            try self.drawLine(.{ .x = rect.x, .y = rect.y }, .{ .x = right, .y = rect.y }, line_opts);
            return;
        }

        try self.drawLine(.{ .x = rect.x, .y = rect.y }, .{ .x = right, .y = rect.y }, line_opts);
        try self.drawLine(.{ .x = right, .y = rect.y }, .{ .x = right, .y = bottom }, line_opts);
        try self.drawLine(.{ .x = right, .y = bottom }, .{ .x = rect.x, .y = bottom }, line_opts);
        try self.drawLine(.{ .x = rect.x, .y = bottom }, .{ .x = rect.x, .y = rect.y }, line_opts);
    }

    pub fn drawLine(self: *CellCanvas, from: Point, to: Point, opts: LineOptions) !void {
        if (from.x == to.x) {
            const step: i32 = if (to.y >= from.y) 1 else -1;
            const min_y = @min(from.y, to.y);
            const max_y = @max(from.y, to.y);
            var y = from.y;
            while (true) : (y += step) {
                var mask: u4 = 0;
                if (y > min_y) mask |= joins.north;
                if (y < max_y) mask |= joins.south;
                self.addLineMask(from.x, y, mask, opts.glyph_set, opts.stroke, opts.fg, opts.bg);
                if (y == to.y) break;
            }
            return;
        }

        if (from.y == to.y) {
            const step: i32 = if (to.x >= from.x) 1 else -1;
            const min_x = @min(from.x, to.x);
            const max_x = @max(from.x, to.x);
            var x = from.x;
            while (true) : (x += step) {
                var mask: u4 = 0;
                if (x > min_x) mask |= joins.west;
                if (x < max_x) mask |= joins.east;
                self.addLineMask(x, from.y, mask, opts.glyph_set, opts.stroke, opts.fg, opts.bg);
                if (x == to.x) break;
            }
            return;
        }

        return error.NonOrthogonalLine;
    }

    pub fn drawPolyline(self: *CellCanvas, points: []const Point, opts: LineOptions) !void {
        if (points.len < 2) return;
        var i: usize = 1;
        while (i < points.len) : (i += 1) {
            try self.drawLine(points[i - 1], points[i], opts);
        }
    }

    pub fn drawArrow(self: *CellCanvas, from: Point, to: Point, opts: ArrowOptions) !void {
        try self.drawLine(from, to, .{
            .glyph_set = opts.glyph_set,
            .stroke = opts.stroke,
            .fg = opts.fg,
            .bg = opts.bg,
        });

        const dx = to.x - from.x;
        const dy = to.y - from.y;
        self.putCodepoint(to.x, to.y, glyph.arrowHead(opts.glyph_set, dx, dy), opts.fg, opts.bg);
    }

    pub fn toFrame(self: *const CellCanvas, allocator: std.mem.Allocator) !core.Frame {
        var frame: core.Frame = .empty;
        errdefer frame.deinit(allocator);
        try frame.ensureCapacity(allocator, self.columns, self.rows, self.color);
        @memcpy(frame.codepoints, self.codepoints);
        if (self.color != .none) {
            @memcpy(frame.fg, self.fg);
            @memcpy(frame.bg, self.bg);
        }
        return frame;
    }

    /// Whether the cell holds a space. Out-of-bounds cells report not-blank so
    /// callers treat them as unavailable for placement.
    pub fn isBlank(self: *const CellCanvas, x: i32, y: i32) bool {
        const idx = self.indexOf(x, y) orelse return false;
        return self.codepoints[idx] == ' ';
    }

    fn putCodepoint(self: *CellCanvas, x: i32, y: i32, codepoint: u21, fg: core.Rgb8, bg: core.Rgb8) void {
        const idx = self.indexOf(x, y) orelse return;
        self.codepoints[idx] = codepoint;
        self.line_masks[idx] = 0;
        self.setColor(idx, fg, bg);
    }

    fn addLineMask(self: *CellCanvas, x: i32, y: i32, mask: u4, glyph_set: GlyphSet, stroke: Stroke, fg: core.Rgb8, bg: core.Rgb8) void {
        const idx = self.indexOf(x, y) orelse return;
        self.line_masks[idx] |= mask;
        self.codepoints[idx] = joins.resolve(self.line_masks[idx], glyph_set, stroke);
        self.setColor(idx, fg, bg);
    }

    fn setColor(self: *CellCanvas, idx: usize, fg: core.Rgb8, bg: core.Rgb8) void {
        if (self.color == .none) return;
        self.fg[idx] = fg;
        self.bg[idx] = bg;
    }

    fn indexOf(self: *const CellCanvas, x: i32, y: i32) ?usize {
        if (x < 0 or y < 0) return null;
        if (x >= @as(i32, @intCast(self.columns)) or y >= @as(i32, @intCast(self.rows))) return null;
        return @as(usize, @intCast(y)) * self.columns + @as(usize, @intCast(x));
    }
};

fn expectCanvasRows(canvas: *const CellCanvas, expected: []const []const u21) !void {
    try std.testing.expectEqual(expected.len, canvas.rows);
    for (expected, 0..) |row, y| {
        try std.testing.expectEqual(@as(usize, canvas.columns), row.len);
        const start = y * canvas.columns;
        try std.testing.expectEqualSlices(u21, row, canvas.codepoints[start .. start + canvas.columns]);
    }
}

test "cell canvas draws a unicode rectangle box" {
    const allocator = std.testing.allocator;
    var canvas = try CellCanvas.init(allocator, 6, 4, .none);
    defer canvas.deinit(allocator);

    try canvas.drawBox(.{ .x = 1, .y = 1, .width = 4, .height = 2 }, .{});

    try expectCanvasRows(&canvas, &.{
        &.{ ' ', ' ', ' ', ' ', ' ', ' ' },
        &.{ ' ', 0x250c, 0x2500, 0x2500, 0x2510, ' ' },
        &.{ ' ', 0x2514, 0x2500, 0x2500, 0x2518, ' ' },
        &.{ ' ', ' ', ' ', ' ', ' ', ' ' },
    });
}

test "cell canvas draws an ascii rectangle box" {
    const allocator = std.testing.allocator;
    var canvas = try CellCanvas.init(allocator, 6, 4, .none);
    defer canvas.deinit(allocator);

    try canvas.drawBox(.{ .x = 1, .y = 1, .width = 4, .height = 2 }, .{ .glyph_set = .ascii });

    try expectCanvasRows(&canvas, &.{
        &.{ ' ', ' ', ' ', ' ', ' ', ' ' },
        &.{ ' ', '+', '-', '-', '+', ' ' },
        &.{ ' ', '+', '-', '-', '+', ' ' },
        &.{ ' ', ' ', ' ', ' ', ' ', ' ' },
    });
}

test "cell canvas draws horizontal and vertical lines" {
    const allocator = std.testing.allocator;
    var canvas = try CellCanvas.init(allocator, 5, 5, .none);
    defer canvas.deinit(allocator);

    try canvas.drawLine(.{ .x = 1, .y = 1 }, .{ .x = 3, .y = 1 }, .{});
    try canvas.drawLine(.{ .x = 2, .y = 2 }, .{ .x = 2, .y = 4 }, .{});

    try expectCanvasRows(&canvas, &.{
        &.{ ' ', ' ', ' ', ' ', ' ' },
        &.{ ' ', 0x2500, 0x2500, 0x2500, ' ' },
        &.{ ' ', ' ', 0x2502, ' ', ' ' },
        &.{ ' ', ' ', 0x2502, ' ', ' ' },
        &.{ ' ', ' ', 0x2502, ' ', ' ' },
    });
}

test "cell canvas resolves line intersections" {
    const allocator = std.testing.allocator;
    var canvas = try CellCanvas.init(allocator, 5, 5, .none);
    defer canvas.deinit(allocator);

    try canvas.drawLine(.{ .x = 0, .y = 2 }, .{ .x = 4, .y = 2 }, .{});
    try canvas.drawLine(.{ .x = 2, .y = 0 }, .{ .x = 2, .y = 4 }, .{});

    try std.testing.expectEqual(@as(u21, 0x253c), canvas.codepoints[2 * canvas.columns + 2]);
}

test "cell canvas draws left-to-right and top-down arrows" {
    const allocator = std.testing.allocator;
    var canvas = try CellCanvas.init(allocator, 5, 5, .none);
    defer canvas.deinit(allocator);

    try canvas.drawArrow(.{ .x = 0, .y = 1 }, .{ .x = 4, .y = 1 }, .{});
    try canvas.drawArrow(.{ .x = 2, .y = 2 }, .{ .x = 2, .y = 4 }, .{ .glyph_set = .ascii });

    try std.testing.expectEqual(@as(u21, 0x25ba), canvas.codepoints[1 * canvas.columns + 4]);
    try std.testing.expectEqual(@as(u21, 'v'), canvas.codepoints[4 * canvas.columns + 2]);
}

test "cell canvas draws text inside a box" {
    const allocator = std.testing.allocator;
    var canvas = try CellCanvas.init(allocator, 8, 3, .none);
    defer canvas.deinit(allocator);

    try canvas.drawBox(.{ .x = 0, .y = 0, .width = 8, .height = 3 }, .{});
    try canvas.drawText(2, 1, "OK", .{});

    try std.testing.expectEqual(@as(u21, 'O'), canvas.codepoints[1 * canvas.columns + 2]);
    try std.testing.expectEqual(@as(u21, 'K'), canvas.codepoints[1 * canvas.columns + 3]);
}

test "cell canvas exports to Frame" {
    const allocator = std.testing.allocator;
    var canvas = try CellCanvas.init(allocator, 3, 1, .truecolor);
    defer canvas.deinit(allocator);

    try canvas.drawText(0, 0, "abc", .{});

    var frame = try canvas.toFrame(allocator);
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), frame.columns);
    try std.testing.expectEqual(@as(u32, 1), frame.rows);
    try std.testing.expectEqual(core.ColorMode.truecolor, frame.color);
    try std.testing.expectEqualSlices(u21, &.{ 'a', 'b', 'c' }, frame.codepoints);
    try std.testing.expectEqual(@as(usize, 3), frame.fg.len);
    try std.testing.expectEqual(@as(usize, 3), frame.bg.len);
}
