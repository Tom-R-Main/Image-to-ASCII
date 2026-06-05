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
density-none,400x240,80x30,200,557812542,2789062,860504
half-truecolor,400x240,80x30,200,556970959,2784854,861804
quadrant-truecolor,400x240,80x30,200,736490709,3682453,651739
braille-none,400x240,80x30,200,809097334,4045486,593253
```
