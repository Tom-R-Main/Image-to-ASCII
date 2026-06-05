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
| ANSI output | TUI / app writer | Per redraw | `renderFrameToWriter` emits a full frame; `renderFrameDiffToWriter` emits dirty row-contiguous runs when the TUI owns raw terminal output. |

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

For a live TUI that writes ANSI itself, keep two reusable workspaces and diff
the previous frame against the current frame:

```zig
var previous_workspace: ascii.RenderWorkspace = .empty;
defer previous_workspace.deinit(allocator);

var current_workspace: ascii.RenderWorkspace = .empty;
defer current_workspace.deinit(allocator);

var has_previous = false;

while (running) {
    try ascii.renderIntoWorkspace(
        &current_workspace,
        allocator,
        image,
        terminal,
        options,
    );

    if (!has_previous) {
        try ascii.renderFrameToWriter(writer, current_workspace.frame);
        has_previous = true;
    } else {
        _ = try ascii.renderFrameDiffToWriter(
            writer,
            &previous_workspace.frame,
            &current_workspace.frame,
            .{ .origin_row = viewport_row, .origin_col = viewport_col },
        );
    }

    std.mem.swap(
        ascii.RenderWorkspace,
        &previous_workspace,
        &current_workspace,
    );
}
```

The swap keeps both `Frame` allocations and both `SamplePlan` allocations alive.
After the first two same-shape renders, steady-state redraws should reuse the
existing buffers. This is the preferred pattern for animation, live preview, and
resize-heavy UI surfaces.

If the viewport origin changes but the rendered cell content is otherwise the
same, either full-render at the new origin or clear/redraw the old region in the
owning TUI. The diff writer only compares cell contents and writes relative to
the origin it is given.

When the shape changes, reset the diff baseline:

```zig
has_previous = false;
previous_workspace.deinit(allocator);
```

Keeping `current_workspace` is still useful; it will reallocate only the parts
whose shape no longer matches.

## OpenTUI Bridge

When embedding in OpenTUI, prefer a custom renderable over writing ANSI into a
text widget. OpenTUI already owns the root renderer, layout pass, clipping,
frame pacing, stdout mode, and dirty scheduling. The image bridge should use the
renderable's measured cell rectangle as `TerminalProfile.columns` / `rows`,
render into a reusable workspace, and copy cells into OpenTUI's
`OptimizedBuffer`.

The practical bridge shape is:

```text
OpenTUI Renderable
- owns decoded image pixels or a reference to app-owned pixels
- owns one image-to-ascii RenderWorkspace for the current rendered cells
- optionally owns PreparedImage for stable monochrome/integral paths
- maps renderable width/height -> TerminalProfile
- copies Frame cells into OptimizedBuffer in renderSelf
```

At the TypeScript/OpenTUI layer, the renderable should look conceptually like
this:

```typescript
class ImageCellRenderable extends Renderable {
  protected renderSelf(buffer: OptimizedBuffer): void {
    const columns = this.width
    const rows = this.height
    if (columns <= 0 || rows <= 0) return

    nativeImageToAscii.renderIntoWorkspace({
      workspace: this.currentWorkspace,
      image: this.imageHandle,
      terminal: { columns, rows, color: "truecolor" },
      options: { mode: "partition", partition: "quadrant_2x2", fit: "contain" },
    })

    nativeImageToAscii.copyFrameToOpenTuiBuffer({
      frame: this.currentWorkspace.frame,
      buffer,
      x: 0,
      y: 0,
    })
  }
}
```

For a first Siftable/OpenTUI integration, this can be an app-local FFI bridge.
Do not make `image-to-ascii` depend on OpenTUI. The stable boundary is still the
raw `ImageView` input and `Frame` output; OpenTUI-specific code should live in
the consuming app or a separate adapter package.

Recommended OpenTUI policy:

| Concern | Recommendation |
| --- | --- |
| Layout | Use the renderable's measured `width` / `height` as the target cell grid. |
| Redraw | Call OpenTUI `requestRender()` when source pixels, options, or container size change. |
| Output | Copy `Frame.codepoints`, `Frame.fg`, and `Frame.bg` into `OptimizedBuffer`; avoid ANSI strings inside text renderables. |
| Clipping | Let OpenTUI scissor/clipping handle the renderable bounds. Do not pre-crop unless the app wants image pan/zoom. |
| Diffing | Usually skip `renderFrameDiffToWriter`; OpenTUI has its own frame diff/output pipeline. Keep our diff writer for direct-terminal consumers. |
| Reuse | Keep one workspace for animation or repeated preview; keep a workspace pair only when bypassing OpenTUI and using `renderFrameDiffToWriter`. |

This keeps the fast path as:

```text
decoded pixels -> image-to-ascii Frame -> OpenTUI OptimizedBuffer -> OpenTUI renderer
```

not:

```text
decoded pixels -> image-to-ascii ANSI -> OpenTUI text parse/render -> terminal
```

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
- Do not move `workspace.frame` out of a single workspace every frame in a live
  loop; use two workspaces and swap them so both frame buffers remain reusable.
- Do not feed ANSI output into OpenTUI text renderables for live image previews;
  copy rendered cells into an OpenTUI buffer or use a small app-local native
  bridge.
- Do not let the renderer probe the terminal. Pass a complete `TerminalProfile`
  from the TUI.
- Do not assume glyph-structure is the best quality mode for photos or
  screenshots. Use the quality harness before changing defaults.
