# Capture — Build, Run, and Install

This whole document assumes a real Mac (macOS 15+, Xcode 16+ / Swift
5.10+ command line tools). **None of the `mac/`/`native-host/` steps below
have been run in this repository's build sandbox** — see
`docs/IMPLEMENTATION_STATUS.md`.

## 1. Native macOS app

```bash
cd mac
swift build                  # debug build, or:
swift build -c release       # release build

swift test                   # run CaptureCoreTests, CaptureCaptureTests,
                              # CaptureEditorTests, CaptureHistoryTests,
                              # CaptureBrowserBridgeTests, CaptureInspectionTests
```

To get a double-clickable `Capture.app` (with icon, `Info.plist`, and an
ad-hoc code signature so Gatekeeper doesn't refuse to launch it locally):

```bash
scripts/generate-icons.sh    # rasterizes design/icon/icon-source.svg -> build/Capture.icns
scripts/package-app.sh       # builds (release) + assembles + ad-hoc signs build/Capture.app
open build/Capture.app
```

Pass `--sign "Developer ID Application: Your Name (TEAMID)"` to
`scripts/package-app.sh` once you have a real signing identity; the default
is ad-hoc (`-`), which is unnotarized — right-click → Open past Gatekeeper's
warning on first launch, or `xattr -dr com.apple.quarantine build/Capture.app`.

### Opening in Xcode instead of the command line

Xcode 16+ can open `mac/Package.swift` directly (File → Open, pick the
`Package.swift` file) and treats it as a project for building, running, and
debugging — no `.xcodeproj` is needed. See
`docs/decisions/0001-spm-instead-of-xcodeproj.md` for why there isn't one.

## 2. Native Messaging host

The host is a separate small binary, built from its own package:

```bash
cd native-host
swift build -c release
swift test
```

Installing it (after building both `Capture.app` and the host, and loading
the unpacked extension below to get its extension ID):

```bash
scripts/install-native-host.sh <chrome-extension-id>
# or: CAPTURE_EXTENSION_ID=<id> scripts/install-native-host.sh

# to remove it later:
scripts/uninstall-native-host.sh
```

This copies the built `CaptureNativeHost` binary to
`~/Library/Application Support/Capture/NativeMessaging/capture-native-host`
and writes `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.capture.bridge.json`
with `allowed_origins` scoped to exactly that extension ID (never a
wildcard — see `docs/IPC_PROTOCOL.md`).

## 3. Chromium extension

This part **has** been built and tested in this repository's sandbox
(Node.js is available there, unlike Swift):

```bash
cd extensions/chromium
npm install
npm run typecheck
npm run build      # bundles into extensions/chromium/dist/
npm test           # vitest
```

### Loading the unpacked extension in Chrome

1. Run the build above so `extensions/chromium/dist/` exists.
2. Open `chrome://extensions`.
3. Enable **Developer mode** (top right).
4. Click **Load unpacked** and select `extensions/chromium/dist/`.
5. Copy the extension ID Chrome assigns (shown on the extension's card) —
   this is the `<chrome-extension-id>` step 2 above needs.
6. Open `chrome://extensions/shortcuts` to see/rebind the Inspect command
   (Chrome manages extension command shortcuts itself; the extension can't
   rebind them programmatically — see `docs/PERMISSIONS.md`).

### End-to-end check

With `Capture.app` running, the native host installed with the real
extension ID, and the unpacked extension loaded:

1. Open any webpage in Chrome.
2. Trigger the Inspect command (from the extension popup, or its keyboard
   shortcut once bound at `chrome://extensions/shortcuts`).
3. Hover an element — a highlight overlay and a compact info card should
   appear.
4. Click to pin it — this sends `element.pin` through the native host to
   `Capture.app`.

This is the Phase 3 acceptance scenario from the spec (Part I §39, "First
browser milestone"). Whether it actually works end-to-end **has not been
verified** — there is no way to run macOS/Chrome together in this sandbox.
`docs/IMPLEMENTATION_STATUS.md` states this plainly rather than claiming
success.

## 4. Running the test suites

| Suite | Command | Run in this sandbox? |
|---|---|---|
| `CaptureCoreTests`, `CaptureCaptureTests`, `CaptureEditorTests`, `CaptureHistoryTests`, `CaptureBrowserBridgeTests`, `CaptureInspectionTests` | `cd mac && swift test` | No — no Swift toolchain available |
| `CaptureNativeHostTests` | `cd native-host && swift test` | No — no Swift toolchain available |
| Chromium extension (vitest) | `cd extensions/chromium && npm test` | **Yes** — see `docs/IMPLEMENTATION_STATUS.md` for the actual results |

## 5. macOS permissions you'll be asked for

See `docs/PERMISSIONS.md` for exactly when and why. In short: Screen
Recording the first time you capture something, Accessibility only if/when
the bookmarks-bar detector needs it and the extension-based Tier 2 signal
isn't available, Microphone/Camera only once recording (Phase 5) exists.
