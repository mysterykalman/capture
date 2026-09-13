#!/usr/bin/env bash
# Removes what scripts/install-native-host.sh installed: the
# CaptureNativeHost binary and the Chrome Native Messaging host manifest,
# for the current user. Safe to run even if install was never run (each
# removal step is a no-op when its target is already absent).
#
# Usage: scripts/uninstall-native-host.sh

set -euo pipefail

NATIVE_MESSAGING_DIR="$HOME/Library/Application Support/Capture/NativeMessaging"
INSTALLED_BINARY="$NATIVE_MESSAGING_DIR/capture-native-host"
CHROME_HOSTS_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$CHROME_HOSTS_DIR/com.capture.bridge.json"

removed_anything=0

if [[ -f "$INSTALLED_BINARY" ]]; then
  rm -f "$INSTALLED_BINARY"
  echo "Removed binary:   $INSTALLED_BINARY"
  removed_anything=1
else
  echo "No binary installed at $INSTALLED_BINARY (nothing to remove)."
fi

# Clean up the now-empty NativeMessaging directory, but never touch the
# rest of ~/Library/Application Support/Capture (project data, other IPC
# state) — only remove this specific directory, and only if it's empty.
if [[ -d "$NATIVE_MESSAGING_DIR" ]] && [[ -z "$(ls -A "$NATIVE_MESSAGING_DIR" 2>/dev/null)" ]]; then
  rmdir "$NATIVE_MESSAGING_DIR"
fi

if [[ -f "$MANIFEST_PATH" ]]; then
  rm -f "$MANIFEST_PATH"
  echo "Removed manifest: $MANIFEST_PATH"
  removed_anything=1
else
  echo "No manifest installed at $MANIFEST_PATH (nothing to remove)."
fi

if [[ "$removed_anything" -eq 1 ]]; then
  echo "Done. Restart Chrome for the removal to take effect."
else
  echo "Nothing was installed; nothing to do."
fi
