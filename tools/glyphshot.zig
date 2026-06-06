//! glyphshot: render an image or Mermaid diagram to cells, then rasterize each
//! cell's glyph through a real TrueType font (via stb_truetype) compositing its
//! foreground over its background, and write the result as a PPM. This is the
//! headless equivalent of "take a screenshot of the terminal" — it shows the
//! actual glyph shapes a terminal would draw (font-dependent), with no display,
//! window server, or screen-recording permission required.
//!
//! Usage:
//!   zig build glyphshot -- --input photo.jpg --mode partition --partition octant \
//!       --color truecolor --width 80 --height 40 --font /path/to/font.ttf -o out.ppm
//!   zig build glyphshot -- --mermaid diagram.mmd --font font.ttf -o out.ppm
//!
//! Convert/view with: magick out.ppm out.png
//!
//! It reports how many distinct code points the font is missing (rendered as
//! .notdef), so an absent octant/sextant repertoire is obvious rather than silent.

const std = @import("std");
const ascii = @import("image_to_ascii");
const image_loader = @import("image_loader");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

const default_font = "/System/Library/Fonts/Menlo.ttc";

const Options = struct {
    input_path: ?[]const u8 = null,
    mermaid_path: ?[]const u8 = null,
    font_path: []const u8 = default_font,
    fallback_font_path: ?[]const u8 = null,
    out_path: []const u8 = "glyphshot.ppm",
    cell_w: u32 = 12,
    cell_h: u32 = 24,
    width: u32 = 80,
    height: u32 = 40,
    mode: ascii.RenderMode = .partition,
    partition: ascii.PartitionKind = .octant_2x4,
    color: ascii.ColorMode = .truecolor,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const stdout = &out_writer.interface;

    const options = parseArgs(args) catch |err| {
        try stdout.print("error: {s}\nsee header for usage\n", .{@errorName(err)});
        try stdout.flush();
        return err;
    };

    try run(stdout, init.io, arena, options);
    try stdout.flush();
}

fn run(writer: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    // 1. Build the cell frame from an image or a Mermaid diagram.
    var frame = try buildFrame(io, allocator, options);
    defer frame.deinit(allocator);

    const cw = options.cell_w;
    const ch = options.cell_h;

    // 2. Load + init the primary font and the optional fallback (terminals do
    //    font fallback too; here the octant SMP glyphs and BMP quadrants/space
    //    can live in separate files).
    var fonts: std.ArrayListUnmanaged(LoadedFont) = .empty;
    try fonts.append(allocator, try loadFont(io, allocator, options.font_path, ch));
    if (options.fallback_font_path) |fp| try fonts.append(allocator, try loadFont(io, allocator, fp, ch));

    // 3. Composite each cell glyph (fg over bg by coverage) into an RGB image.
    const img_w = frame.columns * cw;
    const img_h = frame.rows * ch;
    const out = try allocator.alloc(u8, @as(usize, img_w) * img_h * 3);

    const cover = try allocator.alloc(u8, @as(usize, cw) * ch);
    var missing = std.AutoHashMapUnmanaged(u21, void){};
    var glyph_cells: usize = 0;

    var row: u32 = 0;
    while (row < frame.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < frame.columns) : (col += 1) {
            const idx = @as(usize, row) * frame.columns + col;
            const cp = frame.codepoints[idx];
            const fg = cellColor(frame, idx, true);
            const bg = cellColor(frame, idx, false);

            if (pickFont(fonts.items, cp)) |f| {
                rasterCell(&f.info, f.scale, f.baseline, @intCast(cp), cw, ch, cover);
            } else {
                @memset(cover, 0);
                if (cp != ' ') try missing.put(allocator, cp, {});
            }
            glyph_cells += 1;

            // Blit the cell: background everywhere, glyph ink blended toward fg.
            var y: u32 = 0;
            while (y < ch) : (y += 1) {
                var x: u32 = 0;
                while (x < cw) : (x += 1) {
                    const a: u32 = cover[y * cw + x]; // 0..255 coverage
                    const px = (@as(usize, row * ch + y) * img_w + (col * cw + x)) * 3;
                    out[px + 0] = mix(bg.r, fg.r, a);
                    out[px + 1] = mix(bg.g, fg.g, a);
                    out[px + 2] = mix(bg.b, fg.b, a);
                }
            }
        }
    }

    try writePpm(io, options.out_path, img_w, img_h, out);

    try writer.print(
        \\glyphshot     : {s}
        \\font          : {s}
        \\cells         : {d}x{d}  cell px {d}x{d}  -> image {d}x{d}
        \\missing glyphs: {d} distinct code point(s) not in font (rendered as .notdef)
        \\wrote         : {s}
        \\
    , .{
        if (options.input_path) |p| p else options.mermaid_path orelse "?",
        options.font_path,
        frame.columns,
        frame.rows,
        cw,
        ch,
        img_w,
        img_h,
        missing.count(),
        options.out_path,
    });
}

fn buildFrame(io: std.Io, allocator: std.mem.Allocator, options: Options) !ascii.Frame {
    if (options.mermaid_path) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(src);
        var diag: ?ascii.MermaidError = null;
        return ascii.renderMermaid(allocator, src, .{ .color = options.color }, &diag);
    }
    const path = options.input_path orelse return error.NoInput;
    var loaded = try image_loader.loadPath(io, allocator, path);
    defer loaded.deinit(allocator);
    const terminal = ascii.TerminalProfile{
        .columns = options.width,
        .rows = options.height,
        .color = options.color,
        .symbols = symbolTier(options.mode, options.partition),
    };
    return ascii.renderToCells(allocator, loaded.imageView(), terminal, .{
        .mode = options.mode,
        .partition = options.partition,
        .fit = .contain,
    });
}

fn symbolTier(mode: ascii.RenderMode, partition: ascii.PartitionKind) ascii.TerminalSymbols {
    return switch (mode) {
        .braille => .braille,
        .glyph_tone, .glyph_structure => .glyphs,
        .partition => switch (partition) {
            .sextant_2x3, .octant_2x4 => .block_legacy,
            else => .block_basic,
        },
        .density => .block_basic,
    };
}

fn cellColor(frame: ascii.Frame, idx: usize, fg: bool) ascii.Rgb8 {
    if (frame.color == .none) return if (fg) .{ .r = 235, .g = 235, .b = 235 } else .{ .r = 12, .g = 12, .b = 16 };
    // Preview the actually-displayed color: identity for truecolor, the nearest
    // palette entry for ansi256/ansi16 — so the PNG shows what the terminal emits.
    const raw = if (fg) frame.fg[idx] else frame.bg[idx];
    return ascii.displayColor(raw, frame.color);
}

fn mix(bg: u8, fg: u8, a: u32) u8 {
    // bg*(255-a) + fg*a, rounded.
    const v = (@as(u32, bg) * (255 - a) + @as(u32, fg) * a + 127) / 255;
    return @intCast(@min(v, 255));
}

const LoadedFont = struct {
    info: c.stbtt_fontinfo,
    scale: f32,
    baseline: i32,
};

fn loadFont(io: std.Io, allocator: std.mem.Allocator, path: []const u8, cell_h: u32) !LoadedFont {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.FontNotFound,
        else => return err,
    };
    var info: c.stbtt_fontinfo = undefined;
    const offset = c.stbtt_GetFontOffsetForIndex(bytes.ptr, 0);
    if (c.stbtt_InitFont(&info, bytes.ptr, offset) == 0) return error.InvalidFont;
    const scale = c.stbtt_ScaleForPixelHeight(&info, @floatFromInt(cell_h));
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    c.stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);
    return .{ .info = info, .scale = scale, .baseline = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale) };
}

/// First loaded font that actually contains a glyph for `cp` (the fallback chain).
fn pickFont(fonts: []LoadedFont, cp: u21) ?*LoadedFont {
    for (fonts) |*f| {
        if (c.stbtt_FindGlyphIndex(&f.info, @intCast(cp)) != 0) return f;
    }
    return null;
}

fn rasterCell(font: *c.stbtt_fontinfo, scale: f32, baseline: i32, cp: c_int, cw: u32, ch: u32, cell: []u8) void {
    @memset(cell, 0);
    var gw: c_int = 0;
    var gh: c_int = 0;
    var xoff: c_int = 0;
    var yoff: c_int = 0;
    const bmp = c.stbtt_GetCodepointBitmap(font, scale, scale, cp, &gw, &gh, &xoff, &yoff);
    if (bmp == null) return;
    defer c.stbtt_FreeBitmap(bmp, null);

    // Center the glyph's advance box horizontally for block fidelity.
    var advance: c_int = 0;
    var lsb: c_int = 0;
    c.stbtt_GetCodepointHMetrics(font, cp, &advance, &lsb);
    const adv_px: i32 = @intFromFloat(@as(f32, @floatFromInt(advance)) * scale);
    const tx: i32 = @divTrunc(@as(i32, @intCast(cw)) - adv_px, 2) + xoff;
    const ty: i32 = baseline + yoff;

    var y: i32 = 0;
    while (y < gh) : (y += 1) {
        const cy = ty + y;
        if (cy < 0 or cy >= @as(i32, @intCast(ch))) continue;
        var x: i32 = 0;
        while (x < gw) : (x += 1) {
            const cx = tx + x;
            if (cx < 0 or cx >= @as(i32, @intCast(cw))) continue;
            cell[@intCast(cy * @as(i32, @intCast(cw)) + cx)] = bmp[@intCast(y * gw + x)];
        }
    }
}

fn writePpm(io: std.Io, path: []const u8, w: u32, h: u32, rgb: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h });
    const data = try std.heap.page_allocator.alloc(u8, header.len + rgb.len);
    defer std.heap.page_allocator.free(data);
    @memcpy(data[0..header.len], header);
    @memcpy(data[header.len..], rgb);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            options.input_path = try next(args, &i);
        } else if (std.mem.eql(u8, arg, "--mermaid")) {
            options.mermaid_path = try next(args, &i);
        } else if (std.mem.eql(u8, arg, "--font")) {
            options.font_path = try next(args, &i);
        } else if (std.mem.eql(u8, arg, "--fallback-font")) {
            options.fallback_font_path = try next(args, &i);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            options.out_path = try next(args, &i);
        } else if (std.mem.eql(u8, arg, "--cell-w")) {
            options.cell_w = try std.fmt.parseInt(u32, try next(args, &i), 10);
        } else if (std.mem.eql(u8, arg, "--cell-h")) {
            options.cell_h = try std.fmt.parseInt(u32, try next(args, &i), 10);
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try std.fmt.parseInt(u32, try next(args, &i), 10);
        } else if (std.mem.eql(u8, arg, "--height")) {
            options.height = try std.fmt.parseInt(u32, try next(args, &i), 10);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            options.mode = parseMode(try next(args, &i)) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, arg, "--partition")) {
            options.partition = parsePartition(try next(args, &i)) orelse return error.InvalidPartition;
        } else if (std.mem.eql(u8, arg, "--color")) {
            options.color = parseColor(try next(args, &i)) orelse return error.InvalidColor;
        } else return error.UnknownArgument;
    }
    return options;
}

fn next(args: []const []const u8, i: *usize) ![]const u8 {
    if (i.* + 1 >= args.len) return error.MissingValue;
    i.* += 1;
    return args[i.*];
}

fn parseMode(v: []const u8) ?ascii.RenderMode {
    if (std.mem.eql(u8, v, "density")) return .density;
    if (std.mem.eql(u8, v, "partition")) return .partition;
    if (std.mem.eql(u8, v, "braille")) return .braille;
    if (std.mem.eql(u8, v, "glyph-tone")) return .glyph_tone;
    if (std.mem.eql(u8, v, "glyph-structure")) return .glyph_structure;
    return null;
}

fn parsePartition(v: []const u8) ?ascii.PartitionKind {
    if (std.mem.eql(u8, v, "density")) return .density_1x1;
    if (std.mem.eql(u8, v, "half")) return .half_1x2;
    if (std.mem.eql(u8, v, "quadrant")) return .quadrant_2x2;
    if (std.mem.eql(u8, v, "sextant")) return .sextant_2x3;
    if (std.mem.eql(u8, v, "octant")) return .octant_2x4;
    return null;
}

fn parseColor(v: []const u8) ?ascii.ColorMode {
    if (std.mem.eql(u8, v, "none")) return .none;
    if (std.mem.eql(u8, v, "16")) return .ansi16;
    if (std.mem.eql(u8, v, "256")) return .ansi256;
    if (std.mem.eql(u8, v, "truecolor")) return .truecolor;
    return null;
}
