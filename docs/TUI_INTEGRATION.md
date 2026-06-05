# TUI Integration

This library is meant to be embedded in a terminal app, not to own the terminal
app. The TUI should keep responsibility for image loading, terminal probing,
layout, input, stdout/stderr lifecycle, cursor policy, and redraw cadence. The
renderer should receive raw pixels plus an explicit terminal profile and return
terminal cells or ANSI bytes.

## Ownership Model

| State | Owner | Lifetime | Notes |
| --- | --- | --- | --- |
| Decoded source pixels | TUI / app / CLI adapter | Until the source image changes | Pass as `ImageView`; core never owns or decodes the file. |
| `PreparedImage` | Renderer caller | Reuse while source pixels and source-derived options are stable | Source-derived precompute, currently integral luma. Not render-shape scratch. |
| `RenderWorkspace` | Renderer caller | Reuse while rendering in a loop | Output and render-shape scratch: `Frame` buffers plus `SamplePlan` spans. Not source-owned state. |
| `Frame` | Renderer caller | One rendered terminal-cell state | Store previous/current frames for full render or diff emission. |
| ANSI output | TUI / app writer | Per redraw | `renderFrameToWriter` emits a full frame; `renderFrameDiffToWriter` emits dirty row-contiguous runs. |

Keep these boundaries strict:

```text
PreparedImage = reusable source analysis
RenderWorkspace = reusable render/output memory
Frame = rendered cell result
ANSI diff = terminal update emission
```

## Siftable Boundary

For Siftable or another live TUI consumer, the split should look like this:

```text
Siftable owns:
- image/file/message attachment decoding,
- terminal size and color capability detection,
- layout and viewport placement,
- input, focus, scroll, and resize events,
- stdout/stderr lifecycle and cursor policy.

image-to-ascii owns:
- raw ImageView -> terminal-cell Frame rendering,
- source-derived optional precompute via PreparedImage,
- output/render-shape scratch reuse via RenderWorkspace,
- full-frame ANSI emission or frame-to-frame ANSI diff emission.
```

Do not put decoder types, terminal handles, or app layout state into
`PreparedImage`, `RenderWorkspace`, or `Frame`.

## Mode Defaults

Start with conservative mode selection:

| Content | Recommended options | Why |
| --- | --- | --- |
| Screenshots, memes, photos | `mode = .partition`, `partition = .quadrant_2x2`, `color = .truecolor` | Best current real-image fidelity. |
| Small live previews | `mode = .partition`, `partition = .half_1x2`, `color = .truecolor` | Cheaper and still legible. |
| Monochrome logs or low-color terminals | `mode = .glyph_tone` or `.density`, `color = .none` | Predictable text-only fallback. |
| Line art after quality proof | `mode = .glyph_structure`, `color = .none` | Use only when corpus/fixture evidence says it improves edges. |

The Hank demo in the README is the current evidence for screenshot-like content:
quadrant truecolor wins on PSNR, SSIM, and edge correlation.

## Single Render

For one-off rendering, keep the ergonomic API:

```zig
const ascii = @import("image_to_ascii");

const image: ascii.ImageView = .{
    .width = width,
    .height = height,
    .stride = width * @sizeOf(ascii.Rgba8),
    .pixels = pixels,
};

const terminal = ascii.TerminalProfile{
    .columns = viewport_columns,
    .rows = viewport_rows,
    .color = .truecolor,
    .symbols = .block_basic,
};

const options = ascii.Options{
    .mode = .partition,
    .partition = .quadrant_2x2,
    .fit = .contain,
};

var frame = try ascii.renderToCells(allocator, image, terminal, options);
defer frame.deinit(allocator);

try ascii.renderFrameToWriter(writer, frame);
```

This path is simple and correct, but it allocates a fresh `Frame` for each
render. Use a workspace for live preview, animation, scroll, or resize loops.

## Repeated Render Loop

Use `RenderWorkspace` when the source image or viewport may be rendered
repeatedly:

```zig
var workspace: ascii.RenderWorkspace = .empty;
defer workspace.deinit(allocator);

while (running) {
    const terminal = ascii.TerminalProfile{
        .columns = viewport_columns,
        .rows = viewport_rows,
        .color = .truecolor,
        .symbols = .block_basic,
    };

    try ascii.renderIntoWorkspace(
        &workspace,
        allocator,
        image,
        terminal,
        .{
            .mode = .partition,
            .partition = .quadrant_2x2,
            .fit = .contain,
        },
    );

    try ascii.renderFrameToWriter(writer, workspace.frame);
}
```

The workspace will reuse frame buffers and sample spans for same-shape renders.
It may reallocate when columns, rows, color mode, render mode, partition, or the
virtual subcell grid changes.

## Prepared Source Loop

Use `PreparedImage` when the source is stable and the chosen sampling strategy
can reuse source-derived analysis. Today this is primarily useful for monochrome
integral-luma paths:

```zig
var prepared = try ascii.prepareImage(
    allocator,
    image,
    .{ .columns = viewport_columns, .rows = viewport_rows, .color = .none },
    .{ .sample_strategy = .integral_luma },
);
defer prepared.deinit(allocator);

var workspace: ascii.RenderWorkspace = .empty;
defer workspace.deinit(allocator);

while (running) {
    const terminal = ascii.TerminalProfile{
        .columns = viewport_columns,
        .rows = viewport_rows,
        .color = .none,
        .symbols = .glyphs,
    };

    try ascii.renderPreparedIntoWorkspace(
        &workspace,
        allocator,
        &prepared,
        terminal,
        .{
            .mode = .glyph_tone,
            .fit = .contain,
            .sample_strategy = .integral_luma,
        },
    );

    try ascii.renderFrameToWriter(writer, workspace.frame);
}
```

Rebuild `PreparedImage` only when the source pixels or source-derived prepare
options change. Do not rebuild it merely because the terminal resized.

## Frame Diff Loop

For a live TUI, keep a previous frame and diff against the workspace frame:

```zig
var previous: ascii.Frame = .empty;
defer previous.deinit(allocator);

var workspace: ascii.RenderWorkspace = .empty;
defer workspace.deinit(allocator);

while (running) {
    try ascii.renderIntoWorkspace(&workspace, allocator, image, terminal, options);

    if (previous.codepoints.len == 0) {
        try ascii.renderFrameToWriter(writer, workspace.frame);
    } else {
        _ = try ascii.renderFrameDiffToWriter(
            writer,
            &previous,
            &workspace.frame,
            .{ .origin_row = viewport_row, .origin_col = viewport_col },
        );
    }

    previous.deinit(allocator);
    previous = workspace.frame;
    workspace.frame = .empty;
}
```

The move at the end transfers the rendered frame out of the workspace so it can
become the next `previous` frame. Setting `workspace.frame = .empty` prevents the
workspace deinit from freeing the moved frame. The next render will allocate or
reuse a new frame as needed.

If the viewport origin changes but the rendered cell content is otherwise the
same, either full-render at the new origin or clear/redraw the old region in the
owning TUI. The diff writer only compares cell contents and writes relative to
the origin it is given.

## Resize Rules

Use this decision table in a resize or preview loop:

| Change | Keep `PreparedImage`? | Keep `RenderWorkspace`? | Keep previous `Frame`? |
| --- | --- | --- | --- |
| Same source, same mode, same shape | Yes | Yes | Yes |
| Same source, new columns/rows | Yes | Yes, it will reallocate if needed | Usually no; full-render or reset diff baseline |
| Same source, color mode changes | Yes if prepare options still match | Yes, but frame buffers may reallocate | No |
| Same source, partition/glyph grid changes | Yes if prepare options still match | Yes, but sample spans may rebuild | No |
| New source image | No | Yes | No |
| Terminal origin changes only | Yes | Yes | Maybe, but clear/redraw policy belongs to the TUI |

When in doubt, reset the previous frame and emit a full render. Correctness is
more important than preserving a diff baseline across layout changes.

## Common Mistakes

- Do not put decoded-image ownership inside `PreparedImage`.
- Do not put integral-luma or other source-derived analysis inside
  `RenderWorkspace`.
- Do not use `renderFrameDiffToWriter` across frames with different shape or
  color layout unless you explicitly accept a full-render fallback.
- Do not let the renderer probe the terminal. Pass a complete `TerminalProfile`
  from the TUI.
- Do not assume glyph-structure is the best quality mode for photos or
  screenshots. Use the quality harness before changing defaults.
