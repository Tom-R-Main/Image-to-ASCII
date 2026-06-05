# Benchmarks

The benchmark command is the performance laboratory for renderer changes. It keeps human-readable CSV on stdout and can
also write a stable machine-readable JSON artifact:

```sh
zig build bench
zig build -Doptimize=ReleaseFast bench -- --out bench/results/baseline.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/span-precompute.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/span-tuned.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/workspace-reuse.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/ansi-diff.json
```

`bench/results/baseline.json` is intentionally tracked as the current local baseline. Generated or large benchmark corpora
should remain untracked under `bench/corpus/`.

## Matrix

The current synthetic matrix separates render kernels, prepared reuse, ANSI encoding, and a small quality-harness proxy:

- density mono and truecolor,
- half-block truecolor,
- quadrant mono and truecolor,
- Braille mono and truecolor,
- glyph-tone mono and truecolor,
- glyph-structure mono and truecolor,
- density integral-luma without prepared reuse,
- prepared density with reused `integral_luma`,
- repeated `RenderWorkspace` rows for density mono/truecolor, half-block
  truecolor, glyph-structure mono/truecolor, and prepared density integral-luma,
- full render-to-writer half-block truecolor,
- ANSI encode only,
- ANSI frame diff rows for noop, single-cell, small-run, one-row, and full-frame changes,
- workspace render-plus-diff repeat rows,
- quality compare only.

The JSON artifact records:

- mode, partition, color mode, sample strategy, resolved sampler policy, dither mode, and synthetic input,
- input size and output cell grid,
- iterations, mean ns/iteration, median, p95, ns/cell, and cells/sec,
- estimated per-render allocation bytes (frame buffers plus render-shape span plans),
- first-render and steady-state allocation counts/bytes for workspace reuse rows,
- changed cell counts and emitted dirty-run counts for ANSI diff rows,
- ANSI bytes emitted,
- Zig version, OS, and CPU architecture.

## Current ReleaseFast Baseline

Measured locally on 2026-06-05 with:

```sh
zig build -Doptimize=ReleaseFast bench -- --out bench/results/baseline.json
```

```text
case,input,output,iters,ns_per_iter,median_ns,p95_ns,ns_per_cell,cells_per_sec,allocated_bytes,ansi_bytes
density-none,400x240,80x30,200,297263,278042,407209,123,8073658,9600,0
density-truecolor,400x240,80x30,200,292342,281708,357000,121,8209562,24000,0
half-truecolor,400x240,80x30,200,339124,330583,395166,141,7077057,24000,0
quadrant-none,400x240,80x30,200,370101,362416,433042,154,6484716,9600,0
quadrant-truecolor,400x240,80x30,200,604216,593792,681416,251,3972089,24000,0
braille-none-dither,400x240,80x30,200,671559,661000,768375,279,3573773,9600,0
braille-truecolor,400x240,80x30,200,862399,844000,979917,359,2782934,24000,0
glyph-tone-none,400x240,80x30,200,293198,284333,345625,122,8185594,9600,0
glyph-tone-truecolor,400x240,80x30,200,331192,319375,393292,137,7246551,24000,0
glyph-structure-none,400x240,80x30,200,6501429,6509125,6672042,2708,369149,9600,0
glyph-structure-truecolor,400x240,80x30,200,11767835,11695167,12137541,4903,203945,24000,0
prepared-density-integral-none,400x240,80x30,200,53911,51875,63334,22,44517816,9600,0
render-writer-half-truecolor,400x240,80x30,200,383749,369666,431375,159,6254087,24000,98539
ansi-encode-only,400x240,80x30,200,33144,30792,36375,13,72411296,0,98539
quality-compare-only,400x240,80x30,200,2435,2416,2916,1,985626283,0,0
```

Initial targets:

- Keep density and truecolor half-block under 5 ms for `400x240 -> 80x30`.
- Keep glyph-structure optimization evidence tied to both benchmark rows and slash-line quality smoke tests.
- Keep decode time separate from core render time.

## Span Precompute Comparison

`bench/results/span-precompute.json` measures the renderer after adding `AxisSpan` / `SamplePlan` precomputation. Compare
it against the committed baseline with:

```sh
jq -r -s '
  (.[0].results | map({key:.case, value:{ns:.ns_per_iter, bytes:.allocated_bytes}}) | from_entries) as $base |
  .[1].results[] |
  . as $span |
  ($base[$span.case] // null) as $b |
  select($b != null) |
  [$span.case, $b.ns, $span.ns_per_iter, (((($span.ns_per_iter - $b.ns) * 10000 / $b.ns) | round) / 100), $b.bytes, $span.allocated_bytes] | @tsv
' bench/results/baseline.json bench/results/span-precompute.json
```

Current local result:

```text
case,baseline_ns,span_ns,delta_pct,baseline_bytes,span_bytes
density-none,297263,209284,-29.60,9600,12240
density-truecolor,292342,269864,-7.69,24000,26640
half-truecolor,339124,355213,4.74,24000,27360
quadrant-none,370101,337675,-8.76,9600,14880
quadrant-truecolor,604216,641786,6.22,24000,29280
braille-none-dither,671559,749392,11.59,9600,16320
braille-truecolor,862399,794985,-7.82,24000,30720
glyph-tone-none,293198,279255,-4.76,9600,12240
glyph-tone-truecolor,331192,306523,-7.45,24000,26640
glyph-structure-none,6501429,5836310,-10.23,9600,36480
glyph-structure-truecolor,11767835,10343606,-12.10,24000,50880
prepared-density-integral-none,53911,70615,30.98,9600,12240
render-writer-half-truecolor,383749,381552,-0.57,24000,27360
ansi-encode-only,33144,31706,-4.34,0,0
quality-compare-only,2435,2343,-3.78,0,0
```

The parity tests compare span sampling to the reference direct sampler with an absolute epsilon of `0.0001` for linear RGB
and luma.

## Tuned Auto Policy

`bench/results/span-tuned.json` records the tuned policy after the forced-span pass exposed regressions. The decision rule
is:

- `direct_box` stays the explicit reference path.
- `integral_luma` and `prepared_integral_luma` do not build span arrays.
- `auto` uses `span_precompute` for density, glyph-tone, glyph-structure, quadrant mono, and Braille truecolor.
- `auto` uses `direct_box` for half-block, quadrant truecolor, and Braille mono.

Compare tuned results against both earlier artifacts with:

```sh
jq -r -s '
  (.[0].results | map({key:.case, value:.ns_per_iter}) | from_entries) as $base |
  .[2].results[] | . as $tuned |
  ($base[$tuned.case] // null) as $b |
  select($b != null) |
  [$tuned.case, $tuned.sampler_policy, $b, $tuned.ns_per_iter, (((($tuned.ns_per_iter - $b) * 10000 / $b) | round) / 100)] | @tsv
' bench/results/baseline.json bench/results/span-precompute.json bench/results/span-tuned.json
```

Current tuned vs baseline:

```text
case,policy,baseline_ns,tuned_ns,delta_pct
density-none,span_precompute,297263,288062,-3.10
density-truecolor,span_precompute,292342,227821,-22.07
half-truecolor,direct_box,339124,336331,-0.82
quadrant-none,span_precompute,370101,317875,-14.11
quadrant-truecolor,direct_box,604216,617919,2.27
braille-none-dither,direct_box,671559,657593,-2.08
braille-truecolor,span_precompute,862399,760757,-11.79
glyph-tone-none,span_precompute,293198,269319,-8.14
glyph-tone-truecolor,span_precompute,331192,287611,-13.16
glyph-structure-none,span_precompute,6501429,5457337,-16.06
glyph-structure-truecolor,span_precompute,11767835,9922710,-15.68
prepared-density-integral-none,prepared_integral_luma,53911,58213,7.98
render-writer-half-truecolor,direct_box,383749,366602,-4.47
ansi-encode-only,direct_box,33144,30555,-7.81
quality-compare-only,span_precompute,2435,2690,10.47
```

Prepared integral-luma now has the same estimated allocation as the original baseline (`9600` bytes) instead of paying for
span arrays, and it improves by `17.56%` versus the forced-span artifact; the remaining delta against the older baseline
is benchmark variance and the current helper structure rather than forced span construction.

## RenderWorkspace Reuse

`bench/results/workspace-reuse.json` records repeated-render rows for the reusable workspace API. The ownership rule is:

- `PreparedImage` owns source-derived precompute such as integral-luma tables.
- `RenderWorkspace` owns output and render-shape scratch such as `Frame` buffers and `SamplePlan` spans.
- `Frame` is still the rendered cell result and remains movable out of a workspace by the ergonomic wrapper APIs.

Compare workspace rows against the committed baseline with:

```sh
jq -r -s '
  (.[0].results | map({key:.case, value:{ns:.ns_per_iter, bytes:.allocated_bytes}}) | from_entries) as $base |
  .[1].results[] |
  . as $workspace |
  ($workspace.case
    | sub("^workspace-"; "")
    | sub("-repeat$"; "")
    | sub("^prepared-workspace-density-integral$"; "prepared-density-integral-none")) as $base_key |
  ($base[$base_key] // null) as $b |
  select($b != null and ($workspace.case | contains("workspace"))) |
  [
    $workspace.case,
    $workspace.sampler_policy,
    $b.ns,
    $workspace.ns_per_iter,
    (((($workspace.ns_per_iter - $b.ns) * 10000 / $b.ns) | round) / 100),
    $workspace.allocations_first_render,
    $workspace.allocations_steady_state,
    $workspace.bytes_allocated_first_render,
    $workspace.bytes_allocated_steady_state
  ] | @tsv
' bench/results/baseline.json bench/results/workspace-reuse.json
```

Current workspace vs baseline:

```text
case,policy,baseline_ns,workspace_ns,delta_pct,allocs_first,allocs_steady,bytes_first,bytes_steady
workspace-density-none-repeat,span_precompute,297263,186093,-37.40,3,0,12240,0
workspace-density-truecolor-repeat,span_precompute,292342,209312,-28.40,5,0,26640,0
workspace-half-truecolor-repeat,direct_box,339124,327416,-3.45,3,0,24000,0
workspace-glyph-structure-none-repeat,span_precompute,6501429,5391356,-17.07,3,0,36480,0
workspace-glyph-structure-truecolor-repeat,span_precompute,11767835,9822904,-16.53,5,0,50880,0
prepared-workspace-density-integral-repeat,prepared_integral_luma,53911,54598,1.27,1,0,9600,0
```

The important invariant is the steady-state allocation count: repeated same-shape renders reuse frame buffers and, when
the selected sampler policy uses spans, reuse the `SamplePlan` arrays as render-shape scratch. Prepared integral-luma
reuse performs only the first `Frame` allocation and does not construct span arrays.

## ANSI Diff Writer

`bench/results/ansi-diff.json` records frame-to-frame diff rows. The diff compares `Frame` cell arrays directly and emits
row-contiguous dirty runs:

- noop frames emit no dirty cells and 0 bytes,
- glyph or fg/bg color changes rewrite the cell,
- spaces are still emitted when their background color is active,
- shape or color-mode mismatches error by default, with an explicit full-frame fallback option.

Inspect diff rows with:

```sh
jq -r '
  .results[] |
  select(.case | startswith("ansi-diff") or contains("render-plus-diff")) |
  [
    .case,
    .ns_per_iter,
    .median_ns,
    .ansi_bytes,
    .cells_changed,
    .runs_emitted,
    .allocations_first_render,
    .allocations_steady_state,
    .bytes_allocated_first_render,
    .bytes_allocated_steady_state
  ] | @tsv
' bench/results/ansi-diff.json
```

Current local result:

```text
case,ns_per_iter,median_ns,ansi_bytes,cells_changed,runs_emitted,allocs_first,allocs_steady,bytes_first,bytes_steady
ansi-diff-noop,4802,4750,0,0,0,0,0,0,0
ansi-diff-single-cell-change,4783,4792,44,1,1,0,0,0,0
ansi-diff-small-run-change,4804,4792,52,8,1,0,0,0,0
ansi-diff-one-row-change,5539,4959,123,80,1,0,0,0,0
ansi-diff-full-change,8039,7667,2637,2400,30,0,0,0,0
workspace-render-plus-diff-repeat,221730,217375,0,0,0,10,0,53280,0
prepared-workspace-render-plus-diff-repeat,60457,58000,0,0,0,2,0,19200,0
```

Compare the render-plus-diff rows against the workspace-only artifact with:

```sh
jq -r -s '
  (.[0].results | map({key:.case, value:{ns:.ns_per_iter}}) | from_entries) as $workspace |
  .[1].results[] |
  select(.case == "workspace-render-plus-diff-repeat" or .case == "prepared-workspace-render-plus-diff-repeat") |
  . as $diff |
  (if .case == "workspace-render-plus-diff-repeat" then "workspace-density-truecolor-repeat" else "prepared-workspace-density-integral-repeat" end) as $base_key |
  ($workspace[$base_key]) as $b |
  [$diff.case, $base_key, $b.ns, $diff.ns_per_iter, (((($diff.ns_per_iter - $b.ns) * 10000 / $b.ns) | round) / 100), $diff.allocations_steady_state, $diff.bytes_allocated_steady_state, $diff.ansi_bytes] | @tsv
' bench/results/workspace-reuse.json bench/results/ansi-diff.json
```

Current render-plus-diff vs workspace-only:

```text
case,workspace_case,workspace_ns,diff_ns,delta_pct,allocs_steady,bytes_steady,ansi_bytes
workspace-render-plus-diff-repeat,workspace-density-truecolor-repeat,209312,221730,5.93,0,0,0
prepared-workspace-render-plus-diff-repeat,prepared-workspace-density-integral-repeat,54598,60457,10.73,0,0,0
```
