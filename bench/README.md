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
