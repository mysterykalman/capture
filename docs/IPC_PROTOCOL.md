# Capture — Browser Bridge IPC Protocol

Implements Part I §5.4–5.6. Full JSON Schemas: `schemas/ipc/envelope.schema.json`,
`schemas/ipc/messages.schema.json`. Swift types:
`mac/Sources/CaptureCore/Models/IPCMessage.swift` and
`native-host/Sources/CaptureNativeHost/IPCMessage.swift`. TypeScript types:
`extensions/chromium/src/shared/ipc.ts`.

## Transport chain

```text
content script --(chrome.runtime.sendMessage)--> service worker
service worker --(chrome.runtime.connectNative)--> CaptureNativeHost (stdin/stdout)
CaptureNativeHost --(Unix domain socket)--> Capture.app
```

- **Never** a localhost TCP server (Part I §5.4, §40).
- **Never** transfer image binaries over Native Messaging — Chrome caps
  host-to-extension messages at 1 MB. The bridge sends locators and
  structured metadata; Capture.app performs the actual pixel capture
  natively via ScreenCaptureKit against the resolved element rect.
- Content scripts never talk to the native host directly — only the
  service worker holds the native-messaging port, so the trust boundary
  and message validation are centralized in one place.

## Envelope

Every message is `{version, id, type, tabSessionId?, payload}` (request),
`{version, id, ok: true, payload}` (response), or
`{version, id, ok: false, error: {code, message}}` (error). See
`schemas/ipc/envelope.schema.json` for the exact shape and the closed set
of `type` and `error.code` values.

## Unix socket

- Path: `~/Library/Application Support/Capture/IPC/capture.sock`
- Parent directory: user-only permissions.
- Socket file mode: `0600`.
- `CaptureBrowserBridge` validates every inbound frame against
  `schemas/ipc/messages.schema.json` (mirrored as Swift `Decodable`
  structs with the same closed enum values) **before** dispatch. An
  invalid message returns `INVALID_MESSAGE` and is never partially acted
  upon. There is no code path from a message payload to shell execution or
  arbitrary filesystem access — every `type` maps to one explicitly
  registered handler function; there is no generic "execute" message.
- If Capture.app is not running when the native host starts, the host may
  launch it (`open -g -b com.capture.app`) and retry connecting to the
  socket for a short bounded interval before returning
  `INTERNAL_ERROR` to Chrome.

## Native Messaging host manifest

Installed per-user (never system-wide) by `scripts/install-native-host.sh`
at:

```text
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.capture.bridge.json
```

```json
{
  "name": "com.capture.bridge",
  "description": "Capture browser bridge",
  "path": "/absolute/path/to/capture-native-host",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://<EXTENSION_ID>/"]
}
```

`allowed_origins` is never a wildcard — the install script requires the
real, packaged extension ID.

## Message catalogue (Phase 3 scope)

| type | direction | purpose |
|---|---|---|
| `session.start` | ext → app | Begin an inspect session for a tab; app returns `tabSessionId` |
| `session.end` | ext → app | End the session; app drops any per-tab state |
| `session.ping` | ext → app | Liveness check; app returns its version |
| `inspect.activate` | app → ext | Tell the content script to inject the inspector overlay |
| `inspect.deactivate` | app → ext | Tell the content script to tear down the overlay and remove all listeners/observers |
| `element.pin` | ext → app | User clicked an element while inspecting; carries full `ElementEvidence` |
| `element.captureRequest` | app → ext | Ask the content script to resolve a locator and return fresh `ElementEvidence` (e.g. on recapture) |
| `element.evidence` | ext → app | Response to `element.captureRequest` |
| `element.resolveAnchor` | app → ext | Ask whether a previously-saved locator still resolves; used when reopening a `.capture` project |
| `tab.info` | ext → app | Report active tab URL/title/viewport |
| `bookmarksBar.geometry` | ext → app | Tier-2 bookmarks-bar detection input (Part I bookmarks-bar rule) |
| `bookmarksBar.calibrate` | app → ext (ack) / ext → app (result) | One-time manual calibration round-trip |

## Content-script lifecycle (Part I §5.3)

The inspector content script is injected only while `inspect.activate` is
in effect for that tab and is fully removed (including all DOM event
listeners and any `MutationObserver`) on `inspect.deactivate` or tab
navigation. There is no persistently-injected inspection layer — this is
enforced in `extensions/chromium/src/content/inspector.ts` by tearing down
every listener it attached, not by trusting the page to reload.
