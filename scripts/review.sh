#!/usr/bin/env bash
# review.sh — one command for the full develop→verify loop, dropping viewable
# PNGs so the visual check isn't a separate manual step:
#
#   1. gates       fmt + build + test  (must pass)
#   2. corpus      PSNR/SSIM/edge regression gates  (must pass)
#   3. gallery     glyphshot real-glyph PNGs of every diagram + image  (best effort)
#
# Exits non-zero if gates or corpus fail; the gallery is best-effort (needs a font
# + ImageMagick) and never fails the review. Run before committing/shipping, or
# install it as a pre-push hook with scripts/install-hooks.sh.
#
# Usage: scripts/review.sh [BMP_FONT] [SMP_FONT]   (fonts also via env, auto-discovered)
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
here="$(dirname "${BASH_SOURCE[0]}")"

echo "== gates (fmt + build + test) =="
if [ -x ~/.claude/skills/zig/scripts/zig-gates.sh ]; then
  ~/.claude/skills/zig/scripts/zig-gates.sh || { echo "review: gates FAILED" >&2; exit 1; }
else
  zig fmt --check $(git ls-files '*.zig') || { echo "review: fmt FAILED" >&2; exit 1; }
  zig build test || { echo "review: tests FAILED" >&2; exit 1; }
  zig build || { echo "review: build FAILED" >&2; exit 1; }
fi

echo "== corpus (quality gates) =="
zig build compare -- --corpus testdata/corpus || { echo "review: corpus FAILED" >&2; exit 1; }

echo "== gallery (real-glyph PNGs) =="
if "$here/visual-gallery.sh" "$@"; then
  echo "review: gallery at tools/out/gallery/ (open _diagrams.png / _images.png)"
else
  echo "review: gallery skipped (need a font + ImageMagick; set \$GLYPHSHOT_FONT) — gates/corpus still passed"
fi

echo "review: OK"
