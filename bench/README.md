# Benchmarks

The benchmark command is the performance laboratory for renderer changes. It keeps human-readable CSV on stdout and can
also write a stable machine-readable JSON artifact:

```sh
zig build bench
zig build -Doptimize=ReleaseFast bench -- --out bench/results/baseline.json
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
- estimated per-render frame allocation bytes,
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
