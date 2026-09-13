#!/usr/bin/env bash
# Assembles Capture.app from the SwiftPM release build. macOS-only.
# Usage: scripts/package-app.sh [--sign "Developer ID Application: ..."]
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: this script must run on a Mac (needs swift build + codesign)." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Capture.app"
SIGN_IDENTITY="-"   # ad-hoc by default; pass --sign "Developer ID Application: Your Name (TEAMID)" to override

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

echo "==> Building CaptureApp (release)..."
(cd "$MAC_DIR" && swift build -c release --product Capture)

BIN_PATH="$MAC_DIR/.build/release/Capture"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "error: expected built binary at $BIN_PATH — check 'swift build' output above." >&2
  exit 1
fi

echo "==> Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Capture"
cp "$MAC_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -f "$BUILD_DIR/Capture.icns" ]]; then
  cp "$BUILD_DIR/Capture.icns" "$APP_DIR/Contents/Resources/Capture.icns"
else
  echo "warning: $BUILD_DIR/Capture.icns not found — run scripts/generate-icons.sh first for a real app icon." >&2
fi

# SwiftPM's `resources: [.process(...)]` rule for Assets.xcassets copies the
# compiled asset catalog into the build product's bundle/resource output —
# check .build/release for a Capture_CaptureApp.bundle (SwiftPM's resource
# bundle naming) and copy it in if present.
RESOURCE_BUNDLE=$(find "$MAC_DIR/.build/release" -maxdepth 1 -name "*.bundle" -print -quit 2>/dev/null || true)
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

echo "==> Code signing (identity: $SIGN_IDENTITY)..."
codesign --force --deep --options runtime \
  --entitlements "$MAC_DIR/Resources/Capture.entitlements" \
  --sign "$SIGN_IDENTITY" \
  "$APP_DIR"

echo "==> Verifying signature..."
codesign --verify --verbose "$APP_DIR"

echo "Done: $APP_DIR"
echo "Run it with: open \"$APP_DIR\""
echo "(An ad-hoc-signed build is unnotarized — macOS Gatekeeper will warn on first launch;"
echo " right-click > Open, or 'xattr -dr com.apple.quarantine' the .app, to bypass for local testing.)"
