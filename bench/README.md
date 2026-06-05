# Benchmarks

Benchmark code will live here once the density and half-block renderers are implemented.
Run the current synthetic benchmark with:

```sh
zig build bench
```

Current benchmark cases:

- density without color,
- half-block truecolor,
- quadrant truecolor,
- Braille monochrome.

Initial targets:

- `400x240 -> 80x30` density under 5 ms.
- `400x240 -> 80x30` truecolor half-block under 5 ms.
- ANSI encoding measured separately from sampling and rendering.

Generated or large benchmark corpora should remain untracked under `bench/corpus/`.

## Current ReleaseFast Baseline

Measured locally on 2026-06-05 with:

```sh
zig build -Doptimize=ReleaseFast bench
```

```text
case,input,output,iterations,total_ns,ns_per_iter,cells_per_sec
density-none,400x240,80x30,200,562937125,2814685,852670
half-truecolor,400x240,80x30,200,572936000,2864680,837789
quadrant-truecolor,400x240,80x30,200,904700708,4523503,530562
braille-none,400x240,80x30,200,867408334,4337041,553372
```
