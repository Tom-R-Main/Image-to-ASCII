# Benchmarks

The benchmark command is the performance laboratory for renderer changes. It keeps human-readable CSV on stdout and can
also write a stable machine-readable JSON artifact:

```sh
zig build bench
zig build -Doptimize=ReleaseFast bench -- --out bench/results/baseline.json
zig build -Doptimize=ReleaseFast bench -- --out bench/results/span-precompute.json
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
- prepared density with reused `integral_luma`,
- full render-to-writer half-block truecolor,
- ANSI encode only,
- quality compare only.

The JSON artifact records:

- mode, partition, color mode, sample strategy, dither mode, and synthetic input,
- input size and output cell grid,
- iterations, mean ns/iteration, median, p95, ns/cell, and cells/sec,
- estimated per-render allocation bytes (frame buffers plus render-shape span plans),
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
