#!/usr/bin/env bash
# Generates Capture.app's full .iconset and .icns from the vector source at
# design/icon/icon-source.svg. macOS-only (uses qlmanage/sips/iconutil, all
# bundled with macOS — no Homebrew dependency required). See
# design/icon/README.md for the design rationale.
#
# Usage: scripts/generate-icons.sh
# Output: mac/Resources/Assets.xcassets/AppIcon.appiconset/*.png (for SwiftUI/
#         SwiftPM asset-catalog builds) and build/Capture.icns (for direct
#         Info.plist CFBundleIconFile use, e.g. from scripts/package-app.sh).

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: this script uses macOS-only tools (qlmanage, sips, iconutil) and must run on a Mac." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SVG="$ROOT_DIR/design/icon/icon-source.svg"
WORK_DIR="$(mktemp -d)"
ICONSET_DIR="$ROOT_DIR/mac/Resources/Assets.xcassets/AppIcon.appiconset"
BUILD_DIR="$ROOT_DIR/build"

trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -f "$SOURCE_SVG" ]]; then
  echo "error: $SOURCE_SVG not found" >&2
  exit 1
fi

echo "Rasterizing $SOURCE_SVG at 1024x1024 via Quick Look..."
qlmanage -t -s 1024 -o "$WORK_DIR" "$SOURCE_SVG" >/dev/null
MASTER_PNG="$WORK_DIR/icon-source.svg.png"
if [[ ! -f "$MASTER_PNG" ]]; then
  echo "error: qlmanage did not produce a thumbnail. Is Quick Look's SVG support available on this Mac?" >&2
  echo "       Fallback: open design/icon/icon-source.svg in Safari/Preview and export a 1024x1024 PNG" >&2
  echo "       to $WORK_DIR/icon-source.svg.png, then re-run this script." >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR" "$BUILD_DIR"
ICONSET_TMP="$WORK_DIR/Capture.iconset"
mkdir -p "$ICONSET_TMP"

# (filename, pixel size) pairs required by iconutil for a complete .icns.
declare -a SIZES=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for entry in "${SIZES[@]}"; do
  name="${entry%%:*}"
  size="${entry##*:}"
  sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_TMP/$name" >/dev/null
  # Also drop a copy into the asset catalog's iconset folder using the
  # Xcode asset-catalog naming convention (same PNGs; Contents.json below
  # references these by filename).
  cp "$ICONSET_TMP/$name" "$ICONSET_DIR/$name"
done

echo "Building Capture.icns..."
iconutil -c icns "$ICONSET_TMP" -o "$BUILD_DIR/Capture.icns"

echo "Done."
echo "  Asset catalog PNGs: $ICONSET_DIR"
echo "  Capture.icns:        $BUILD_DIR/Capture.icns"
