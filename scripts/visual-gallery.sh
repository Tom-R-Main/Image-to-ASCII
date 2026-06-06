#!/usr/bin/env bash
# visual-gallery.sh — render the diagram fixtures and image corpus through real
# glyphs (glyphshot) into PNG contact sheets, so a quality pass produces something
# you can actually look at. Headless: no display or screen-recording permission.
#
# Fonts are not committed. Provide them via args or env:
#   GLYPHSHOT_FONT      BMP-covering font (diagrams, quadrant)         [required]
#   GLYPHSHOT_FONT_SMP  Unicode-16 SMP font (octant/sextant glyphs)    [optional]
# e.g. GNU Unifont:  unifont-*.otf (BMP)  +  unifont_upper-*.otf (SMP).
#
# Usage:
#   scripts/visual-gallery.sh [BMP_FONT] [SMP_FONT]
#   GLYPHSHOT_FONT=unifont.otf GLYPHSHOT_FONT_SMP=unifont_upper.otf scripts/visual-gallery.sh
#
# Output: tools/out/gallery/*.png (gitignored), plus montage contact sheets.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

font="${1:-${GLYPHSHOT_FONT:-}}"
font_smp="${2:-${GLYPHSHOT_FONT_SMP:-}}"
[ -n "$font" ] || { echo "need a BMP font: arg1 or \$GLYPHSHOT_FONT (see header)" >&2; exit 1; }
[ -f "$font" ] || { echo "font not found: $font" >&2; exit 1; }
command -v magick >/dev/null || { echo "ImageMagick (magick) required" >&2; exit 1; }

out="tools/out/gallery"
mkdir -p "$out"
zig build >/dev/null

shot() { # <args...> -o handled by caller via $1=outname then glyphshot args
  local name="$1"; shift
  zig build glyphshot -- "$@" -o "$out/$name.ppm" >/dev/null 2>&1 || { echo "  ! $name failed"; return 0; }
  magick "$out/$name.ppm" "$out/$name.png" 2>/dev/null
  rm -f "$out/$name.ppm"
  echo "  $name.png"
}

echo "== diagrams (real glyphs) =="
diag_pngs=()
while IFS= read -r mmd; do
  name="diagram-$(echo "${mmd#testdata/mermaid/}" | tr '/.' '--' | sed 's/-mmd$//')"
  shot "$name" --mermaid "$mmd" --color truecolor --font "$font" --cell-w 10 --cell-h 20
  [ -f "$out/$name.png" ] && diag_pngs+=("$out/$name.png")
done < <(find testdata/mermaid -name '*.mmd' | sort)
[ ${#diag_pngs[@]} -gt 0 ] && magick montage "${diag_pngs[@]}" -tile 3x -geometry +8+8 -background '#444' -title 'Cell Render — diagrams' "$out/_diagrams.png" 2>/dev/null && echo "  -> _diagrams.png"

echo "== images (quadrant vs octant) =="
img_pngs=()
for img in testdata/real/photo-small.jpg testdata/real/line-art.png testdata/real/gradient.png; do
  [ -f "$img" ] || continue
  base="image-$(basename "$img" | tr '.' '-')"
  shot "$base-quadrant" --input "$img" --mode partition --partition quadrant --color truecolor --width 60 --height 28 --font "$font" --cell-w 8 --cell-h 16
  [ -f "$out/$base-quadrant.png" ] && img_pngs+=("$out/$base-quadrant.png")
  if [ -n "$font_smp" ] && [ -f "$font_smp" ]; then
    shot "$base-octant" --input "$img" --mode partition --partition octant --color truecolor --width 60 --height 28 --font "$font_smp" --fallback-font "$font" --cell-w 8 --cell-h 16
    [ -f "$out/$base-octant.png" ] && img_pngs+=("$out/$base-octant.png")
  fi
done
[ ${#img_pngs[@]} -gt 0 ] && magick montage "${img_pngs[@]}" -tile 2x -geometry +8+8 -background '#444' -label '%f' -title 'Cell Render — images' "$out/_images.png" 2>/dev/null && echo "  -> _images.png"
[ -n "$font_smp" ] || echo "  (octant skipped: no SMP font — set \$GLYPHSHOT_FONT_SMP)"

echo
echo "gallery: $out/  (open _diagrams.png / _images.png)"
