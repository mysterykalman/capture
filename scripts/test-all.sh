#!/usr/bin/env bash
# Runs every test suite in the repo that can run on the current machine.
# On a Mac with Xcode installed this is everything; elsewhere (as in the
# sandbox this repo was originally built in) it's just the extension —
# the script detects this and says so rather than failing silently.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

echo "==================================================="
echo " Chromium extension (extensions/chromium)"
echo "==================================================="
if [[ ! -d "$ROOT_DIR/extensions/chromium/node_modules" ]]; then
  (cd "$ROOT_DIR/extensions/chromium" && npm install)
fi
if ! (cd "$ROOT_DIR/extensions/chromium" && npm run typecheck && npm run build && npm test); then
  echo "!! extension tests FAILED" >&2
  FAILED=1
fi

echo
echo "==================================================="
echo " Native macOS app (mac/)"
echo "==================================================="
if command -v swift >/dev/null 2>&1; then
  if ! (cd "$ROOT_DIR/mac" && swift test); then
    echo "!! mac/ Swift tests FAILED" >&2
    FAILED=1
  fi
else
  echo "SKIPPED: no Swift toolchain on this machine." >&2
  echo "         See docs/IMPLEMENTATION_STATUS.md — this was true of the" >&2
  echo "         sandbox this repo was originally built in; run this on a" >&2
  echo "         real Mac with Xcode 16+ to actually execute these tests." >&2
fi

echo
echo "==================================================="
echo " Native Messaging host (native-host/)"
echo "==================================================="
if command -v swift >/dev/null 2>&1; then
  if ! (cd "$ROOT_DIR/native-host" && swift test); then
    echo "!! native-host/ Swift tests FAILED" >&2
    FAILED=1
  fi
else
  echo "SKIPPED: no Swift toolchain on this machine." >&2
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "All runnable suites passed."
else
  echo "One or more suites FAILED — see output above." >&2
fi
exit "$FAILED"
