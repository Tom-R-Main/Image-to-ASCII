# Test Data

Keep this directory small and deterministic.

Allowed:

- tiny raw RGBA fixtures,
- tiny PPM/PAM fixtures for CLI/test-support decoding,
- hand-authored golden outputs.

Current fixtures:

- `diagonal.ppm`: 2x2 white/black diagonal for quadrant and Braille checks.
- `color-bars.ppm`: 4x1 RGB/white bars for color and density checks.
- `slash-line.ppm`: 8x16 monochrome line-art cell for glyph-structure checks.

Avoid:

- large real-image corpora,
- generated benchmark outputs,
- third-party images without clear license metadata.
