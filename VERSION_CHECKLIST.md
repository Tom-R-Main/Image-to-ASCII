# v0.1.0 Tag Checklist

Use this before cutting the first public tag.

## Required Checks

```sh
zig fmt build.zig bench/main.zig src/*.zig test_support/*.zig
zig build test
zig build
zig build -Doptimize=ReleaseFast bench
zig build run -- --synthetic gradient --width 16 --height 4 --mode density --color none
zig build run -- --input testdata/diagonal.ppm --width 1 --height 1 --mode partition --partition quadrant --color none
```

## Release Notes

- Raw RGBA core API.
- Density, half-block, quadrant, and Braille output.
- Ordered dithering.
- Streaming ANSI writer.
- Synthetic CLI inputs.
- PPM/PAM fixture input outside core.
- Synthetic benchmark command.

## Pre-Tag Review

- Confirm `build.zig.zon` version.
- Confirm `CHANGELOG.md` has the intended v0.1.0 section.
- Confirm no decoder is exported from `src/root.zig`.
- Confirm benchmark numbers are refreshed or explicitly marked as historical.
- Confirm GitHub remote is correct.

## Tag Commands

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin main
git push origin v0.1.0
```
