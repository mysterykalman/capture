#!/usr/bin/env bash
# One-time setup for a fresh checkout. Installs the Chromium extension's
# Node dependencies (works anywhere Node is available) and, on macOS,
# reports whether the Swift toolchain needed for mac/ and native-host/ is
# present.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Installing extensions/chromium dependencies..."
(cd "$ROOT_DIR/extensions/chromium" && npm install)

if [[ "$(uname)" == "Darwin" ]]; then
  if command -v swift >/dev/null 2>&1; then
    echo "==> Swift toolchain found: $(swift --version | head -1)"
  else
    echo "==> WARNING: no 'swift' on PATH. Install Xcode 16+ (or the Xcode" >&2
    echo "    Command Line Tools: xcode-select --install) to build mac/ and" >&2
    echo "    native-host/. See docs/BUILD_AND_RUN.md." >&2
  fi
else
  echo "==> Not on macOS ($(uname)) — mac/ and native-host/ cannot be built" >&2
  echo "    or run here. See docs/BUILD_AND_RUN.md and the environment note" >&2
  echo "    at the top of docs/IMPLEMENTATION_STATUS.md." >&2
fi

echo "==> Bootstrap complete."
