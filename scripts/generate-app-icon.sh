#!/bin/bash
# Derive macOS icon resources without cropping or changing the supplied artwork.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source="$root/assets/AppIcon-original.png"
catalog="$root/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$source" ]]; then
    printf 'Missing icon source: %s\n' "$source" >&2
    exit 1
fi

metadata="$(sips -g pixelWidth -g pixelHeight "$source")"
width="$(printf '%s\n' "$metadata" | awk '/pixelWidth:/ { print $2 }')"
height="$(printf '%s\n' "$metadata" | awk '/pixelHeight:/ { print $2 }')"
if [[ -z "$width" || -z "$height" || "$width" != "$height" ]] || (( width < 1024 )); then
    printf 'The icon source must be square and at least 1024 × 1024 pixels.\n' >&2
    exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/nevermore-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT
iconset="$work/Nevermore.iconset"
mkdir -p "$iconset"

for points in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((points * scale))
        suffix=""
        if (( scale == 2 )); then suffix="@2x"; fi
        filename="icon_${points}x${points}${suffix}.png"
        sips --resampleHeightWidth "$pixels" "$pixels" "$source" \
            --out "$iconset/$filename" >/dev/null
    done
done

iconutil --convert icns --output "$work/Nevermore.icns" "$iconset"
mkdir -p "$catalog"
cp "$iconset/"*.png "$catalog/"
cp "$work/Nevermore.icns" "$root/Resources/Nevermore.icns"
printf 'Generated macOS AppIcon images (16–1024 px) and Resources/Nevermore.icns.\n'
