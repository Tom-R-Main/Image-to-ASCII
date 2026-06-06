#!/usr/bin/env bash
# Install the repo git hooks (symlink, so they track the committed versions).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hooks_dir="$repo/.git/hooks"
mkdir -p "$hooks_dir"
ln -sf ../../scripts/hooks/pre-push "$hooks_dir/pre-push"
echo "installed pre-push hook -> scripts/hooks/pre-push"
echo "(bypass once with: SKIP_REVIEW=1 git push)"
