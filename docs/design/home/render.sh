#!/bin/sh
# Renders a mockup to PNG with headless Chromium at 2x.
# Usage: render.sh <mockup.html> <query, e.g. theme=vaporwave> <out.png>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
chrome="${CHROME:-$HOME/Library/Caches/ms-playwright/chromium_headless_shell-1254/chrome-headless-shell-mac-arm64/chrome-headless-shell}"
if [ ! -x "$chrome" ]; then
  echo "render.sh: no headless Chrome at $chrome; set CHROME to one" >&2
  exit 1
fi
profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT
"$chrome" --headless --disable-gpu --hide-scrollbars --no-first-run \
  --user-data-dir="$profile" --allow-file-access-from-files \
  --force-device-scale-factor=2 --window-size=1324,844 --virtual-time-budget=3000 \
  --screenshot="$3" "file://$here/mockups/$1?$2" >/dev/null 2>&1
echo "$3"
