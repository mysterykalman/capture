#!/usr/bin/env bash
# Builds the Chromium extension into extensions/chromium/dist/, ready to
# load unpacked via chrome://extensions (see docs/BUILD_AND_RUN.md).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="$ROOT_DIR/extensions/chromium"

if [[ ! -d "$EXT_DIR/node_modules" ]]; then
  echo "==> node_modules missing, running npm install first..."
  (cd "$EXT_DIR" && npm install)
fi

echo "==> Type checking..."
(cd "$EXT_DIR" && npm run typecheck)

echo "==> Building..."
(cd "$EXT_DIR" && npm run build)

echo "Done: $EXT_DIR/dist"
