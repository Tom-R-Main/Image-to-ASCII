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
density-none,400x240,80x30,200,226513,94,10595418,0
density-truecolor,400x240,80x30,200,301942,125,7948546,0
glyph-tone-none,400x240,80x30,200,296653,123,8090260,0
glyph-structure-none,400x240,80x30,200,6582312,2742,364613,0
half-truecolor,400x240,80x30,200,344267,143,6971333,0
quadrant-none,400x240,80x30,200,369767,154,6490573,0
quadrant-truecolor,400x240,80x30,200,618050,257,3883180,0
braille-none-dither,400x240,80x30,200,690467,287,3475908,0
braille-truecolor,400x240,80x30,200,871073,362,2755222,0
ansi-half-truecolor,400x240,80x30,200,373897,155,6418880,98539
```
