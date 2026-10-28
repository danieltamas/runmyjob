#!/usr/bin/env bash
# Renders Brand/*.svg into Support/ (AppIcon.icns, MenuBarIcon.pdf, the template glyph).
# The output is committed, so a build copies fixed bytes and never depends on the renderer's
# version. Run it after changing an SVG, and commit the result. Two runs give the same bytes.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing: brew install librsvg" >&2; exit 2; }
out=${1:-Support}
mkdir -p "$out"
# cairo stamps a PDF's creation date from this, so re-rendering an unchanged SVG changes nothing.
export SOURCE_DATE_EPOCH=315532800

rsvg-convert -f pdf Brand/icon-menubar.svg -o "$out/MenuBarIcon.pdf"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" Brand/icon-app.svg -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" Brand/icon-app.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$out/AppIcon.icns"
ls "$out"
