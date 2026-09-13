#!/usr/bin/env bash
# Installs the CaptureNativeHost binary and its Chrome Native Messaging
# host manifest for the current user. See docs/IPC_PROTOCOL.md
# ("Native Messaging host manifest") for the manifest shape and install
# location this mirrors.
#
# Usage:
#   scripts/install-native-host.sh <chrome-extension-id>
#
# The extension id can also be supplied via the CAPTURE_EXTENSION_ID
# environment variable instead of the positional argument (useful for
# CI/packaging scripts); the positional argument wins if both are given.
# There is no default and no wildcard fallback — allowed_origins in the
# manifest must always be the real, packaged extension's id
# (docs/IPC_PROTOCOL.md: "allowed_origins is never a wildcard").
#
# Prerequisite: build the release binary first —
#   swift build -c release --package-path native-host
#
# What this does:
#   1. Copies native-host/.build/release/CaptureNativeHost to
#      ~/Library/Application Support/Capture/NativeMessaging/capture-native-host
#   2. Writes the Chrome Native Messaging host manifest to
#      ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.capture.bridge.json
#      pointing at that binary, with allowed_origins scoped to the given
#      extension id.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/install-native-host.sh <chrome-extension-id>

  <chrome-extension-id>  The installed/packaged Chrome extension's id
                          (32 lowercase letters a-p, e.g. as shown on
                          chrome://extensions with Developer mode on).
                          May also be supplied via the CAPTURE_EXTENSION_ID
                          environment variable.

This never installs a wildcard allowed_origins manifest — an extension id
is required.
EOF
}

EXTENSION_ID="${1:-${CAPTURE_EXTENSION_ID:-}}"

if [[ -z "$EXTENSION_ID" ]]; then
  echo "error: no Chrome extension id given (arg 1 or \$CAPTURE_EXTENSION_ID)." >&2
  usage
  exit 1
fi

# Chrome extension ids are exactly 32 lowercase letters from the range a-p
# (base16 over that alphabet). Reject anything else loudly rather than
# writing a manifest that's silently wrong.
if [[ ! "$EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
  echo "error: '$EXTENSION_ID' doesn't look like a Chrome extension id (expected 32 lowercase letters a-p)." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_BINARY="$ROOT_DIR/native-host/.build/release/CaptureNativeHost"

if [[ ! -f "$BUILT_BINARY" ]]; then
  echo "error: built binary not found at $BUILT_BINARY" >&2
  echo "       build it first: swift build -c release --package-path native-host" >&2
  exit 1
fi

NATIVE_MESSAGING_DIR="$HOME/Library/Application Support/Capture/NativeMessaging"
INSTALLED_BINARY="$NATIVE_MESSAGING_DIR/capture-native-host"
CHROME_HOSTS_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$CHROME_HOSTS_DIR/com.capture.bridge.json"

echo "Installing CaptureNativeHost for extension id: $EXTENSION_ID"

mkdir -p "$NATIVE_MESSAGING_DIR"
chmod 700 "$NATIVE_MESSAGING_DIR"
cp -f "$BUILT_BINARY" "$INSTALLED_BINARY"
chmod 755 "$INSTALLED_BINARY"
echo "  Installed binary:   $INSTALLED_BINARY"

mkdir -p "$CHROME_HOSTS_DIR"

# Minimal JSON string escaping (backslash and double-quote) for the
# binary path, which could in principle contain characters that need
# escaping (spaces are fine unescaped in JSON strings; backslash/quote
# are not). The extension id has already been validated against
# ^[a-p]{32}$ above, so it never needs escaping.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

ESCAPED_BINARY_PATH="$(json_escape "$INSTALLED_BINARY")"

cat > "$MANIFEST_PATH" <<EOF
{
  "name": "com.capture.bridge",
  "description": "Capture browser bridge",
  "path": "$ESCAPED_BINARY_PATH",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
EOF

echo "  Wrote manifest:     $MANIFEST_PATH"
echo "Done. Restart Chrome for it to pick up the new native messaging host."
