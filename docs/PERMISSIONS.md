# Capture — Permissions

Implements Part I §30 and §20's progressive-permission requirement: ask for
nothing until the specific feature that needs it is actually invoked, and
degrade gracefully (never crash or silently no-op) when a permission is
declined.

## macOS system permissions

| Permission | Requested when | Declined behaviour |
|---|---|---|
| **Screen Recording** | First capture or recording action (area/window/full-screen/record) is invoked, not at launch | `CaptureCapture` returns a typed `.permissionDenied` error; `CaptureUI` shows the standard "Open System Settings" prompt; no capture is silently skipped or faked |
| **Accessibility** | Only when the browser bookmarks-bar-privacy AXUIElement detection (Tier 1, see `docs/ARCHITECTURE.md`) is first needed for a supported browser window | Detection falls back to Tier 2 (extension-reported geometry) automatically; never used as a substitute for the Chromium extension's semantic DOM data |
| **Microphone** | Only when a recording with microphone audio is started (Phase 5 — not yet implemented) | N/A until Phase 5 |
| **Camera** | Only when a recording with a camera overlay is started (Phase 5 — not yet implemented) | N/A until Phase 5 |
| **Input Monitoring** | The first time any global shortcut (Part I's Global Custom Shortcut System) is registered, at first launch after onboarding | Global shortcuts silently fail to fire — `CaptureUI` must surface this state explicitly (e.g. a persistent banner/menu-bar-item state), never leave the user wondering why a shortcut does nothing |

**Correction from an earlier draft of this document:** `CaptureCapture`'s
global shortcut manager uses `NSEvent.addGlobalMonitorForEvents`, which
macOS gates behind the **Input Monitoring** TCC permission (distinct from
Accessibility) — this was missing from this table until the
`CaptureCapture` implementation flagged it. This is requested once, at
first launch, rather than per-shortcut, since nearly every core capture
action in Part I's Global Custom Shortcut System depends on it and gating
it feature-by-feature would just mean repeatedly re-prompting. A
permission-free alternative (Carbon's `RegisterEventHotKey`) exists and is
worth evaluating in a follow-up pass to avoid this prompt entirely — noted
as a real, undecided trade-off, not a settled design choice.

Capture never requests Accessibility merely to obtain browser DOM data the
Chromium extension can supply more precisely and with narrower scope.

## Chromium extension permissions

`extensions/chromium/src/manifest.json` requests the minimum baseline from
Part I §5.2:

```json
{
  "permissions": ["activeTab", "scripting", "storage", "nativeMessaging"],
  "optional_host_permissions": ["http://*/*", "https://*/*"]
}
```

- No broad, persistent `host_permissions` — the inspector content script is
  injected via `activeTab` (a user gesture: pressing the Inspect shortcut)
  plus `chrome.scripting.executeScript`, not a `content_scripts` manifest
  entry that runs on every page load.
- `optional_host_permissions` for `http(s)://*/*` is requested (via
  `chrome.permissions.request`) only the first time a feature that needs
  continued page access without a fresh user gesture is used, and the user
  is told why.
- No cookies, webRequest, or tabs-history permissions are requested — none
  of the implemented Phase 3 features need them.

## What Capture never does

- Never uploads a screenshot, recording, or OCR text without an explicit
  user-initiated share/export action.
- Never inspects a tab's DOM unless Inspect Mode was explicitly activated
  for that tab.
- Never captures or displays keystrokes typed into a secure/password field
  (applies once the Phase 5 recording keystroke track is implemented).
