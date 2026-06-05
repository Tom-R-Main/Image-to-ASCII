# Benchmarks

Benchmark code will live here once the density and half-block renderers are implemented.
Run the current synthetic benchmark with:

```sh
zig build bench
```

Current benchmark cases:

- density without color,
- glyph-tone without color,
- glyph-structure without color,
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
case,input,output,iters,ns_per_iter,ns_per_cell,cells_per_sec,bytes
density-none,400x240,80x30,200,297814,124,8058721,0
density-truecolor,400x240,80x30,200,286417,119,8379390,0
glyph-tone-none,400x240,80x30,200,297920,124,8055853,0
glyph-structure-none,400x240,80x30,200,18991305,7913,126373,0
half-truecolor,400x240,80x30,200,341897,142,7019657,0
quadrant-none,400x240,80x30,200,378800,157,6335797,0
quadrant-truecolor,400x240,80x30,200,592652,246,4049594,0
braille-none-dither,400x240,80x30,200,688453,286,3486076,0
braille-truecolor,400x240,80x30,200,885243,368,2711119,0
ansi-half-truecolor,400x240,80x30,200,379425,158,6325360,98539
```
