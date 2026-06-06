#!/usr/bin/env bash
# terminal-shot.sh — capture a REAL screenshot of cell-render output in Terminal.app.
#
# This is the "literal screenshot" path. Prefer `zig build glyphshot` for headless,
# unattended, permission-free visual checks; use this only when you specifically
# want to see how YOUR terminal + font render the output (antialiasing, font
# fallback, cell aspect).
#
# Requirements (one-time, GUI — this script cannot grant them):
#   • System Settings > Privacy & Security > Screen Recording: enable your terminal.
#   • The Mac must be AWAKE and UNLOCKED (a locked/asleep display captures nothing).
#   • A Unicode-16 monospace font for octants/sextants (e.g. install GNU Unifont,
#     Cascadia Code, or Iosevka) and set Terminal's profile font to it.
#
# Usage:
#   scripts/terminal-shot.sh 'OUT.png' 'CMD…'
#   scripts/terminal-shot.sh /tmp/shot.png \
#     './zig-out/bin/cell-render --input testdata/real/photo-small.jpg \
#        --width 80 --height 40 --mode partition --partition octant'
set -euo pipefail

out="${1:?usage: terminal-shot.sh OUT.png CMD}"; shift
cmd="$*"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v screencapture >/dev/null || { echo "screencapture not found (macOS only)" >&2; exit 1; }

# Refuse to run against a locked screen — screencapture would grab nothing useful.
front="$(osascript -e 'tell application "System Events" to return name of first process whose frontmost is true' 2>/dev/null || true)"
if [ "$front" = "loginwindow" ]; then
  echo "screen is locked (loginwindow frontmost) — unlock the Mac and retry." >&2
  exit 2
fi

# Open a dedicated Terminal window, size it, run the command, and read back its
# on-screen bounds so we capture exactly that rectangle (no full-desktop grab).
read -r x1 y1 x2 y2 < <(osascript <<OSA
tell application "Terminal"
  activate
  set w to do script "clear; cd $(printf %q "$repo"); $cmd"
  set bounds of front window to {120, 120, 1100, 760}
  delay 1.2
  set b to bounds of front window
  return (item 1 of b as text) & " " & (item 2 of b as text) & " " & (item 3 of b as text) & " " & (item 4 of b as text)
end tell
OSA
)

# screencapture -R takes x,y,width,height.
screencapture -x -R"${x1},${y1},$((x2 - x1)),$((y2 - y1))" "$out"
echo "wrote $out ($((x2 - x1))x$((y2 - y1)) px)"
