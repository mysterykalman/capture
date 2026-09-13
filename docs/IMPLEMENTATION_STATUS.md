# Capture — Implementation Status

Last updated: 2026-09-13. This is the authoritative, honest record of what
is implemented, partially implemented, stubbed, blocked, or not started.
Nothing here is aspirational — see `docs/ARCHITECTURE.md` for why the scope
was cut the way it was, and `AGENTS.md` for the rules this build followed.

## Read this first: the environment constraint

This repository was built in a **Linux sandbox with no Xcode and no Swift
toolchain**, and no network path to install one (swift.org is not reachable
through the sandbox's egress proxy). **Every file under `mac/` and
`native-host/` — all Swift source — has been written but never compiled,
run, or unit-tested by a compiler.** It is source code, hand-reviewed for
correctness, not compiler-verified. Building and running `swift build` /
`swift test` on a real Mac (Xcode 16+, macOS 15+) is the single most
valuable next step for whoever picks this up, and is very likely to surface
real compile errors — six independent implementation passes writing
~9,000 lines of interdependent Swift by hand, with no compiler in the loop,
is not a process that produces error-free code. Two real cross-module type
bugs and one Package.swift dependency-graph bug were already found and
fixed this way (by later agents reading earlier agents' code, and by
this document's author reviewing their reports) — more almost certainly
remain.

The Chromium extension under `extensions/chromium/` is plain
TypeScript/HTML/CSS/JSON. It **has** been built and tested for real in this
sandbox with Node.js, and independently re-verified before this document
was written:

```
$ npm run typecheck   # tsc --noEmit, strict — 0 errors
$ npm run build        # esbuild — succeeds, dist/ populated
$ npm test              # vitest, jsdom — 34/34 tests passing
```

## Scope: what this build targets

The master specification (~19,000 lines) describes a multi-year product
combining the scope of Shottr, CleanShot X, Snagit, Screen Studio, Chrome
DevTools, Polypane, Percy, and Wappalyzer. It explicitly organizes itself
into Tiers 0-6 and Phases 0-9 and states the product should not "ship as
one monolithic first release," and its own coding-agent instructions say
not to jump into ecommerce/AI/responsive-lab work before the capture/editor
foundation is real. This build targets, with real (non-mock) depth:

- **Phase 0 — Foundation**: app scaffold, lifecycle, permission onboarding,
  module boundaries, settings shell, logging.
- **Phase 1 — Core screenshot utility**: area/window/full-screen capture,
  non-destructive editor, crop, undo/redo, clipboard/save/export, local
  history.
- **Phase 2 (partial) — Project format and precision**: the `.capture`
  project package format, the universal snap engine, measurement/ruler
  types, Counter/Spotlight/Magnifier/redaction annotation rendering,
  filename templates.
- **Phase 3 — Chromium inspector**: MV3 extension, Native Messaging host,
  Unix-socket bridge, Inspect Mode overlay, `ElementEvidence` model,
  DOM-anchored annotations, one-click element evidence capture.

**Phases 4-9 are not implemented**: scrolling-capture stitching refinement
and DOM-aware full-page capture, the full recording engine (`CaptureRecording`
is an empty placeholder module), the Responsive/State Lab, the
Accessibility audit module (beyond the contrast-math building block),
Performance/SEO/technology-fingerprinting, Shopify/ecommerce intelligence,
Visual Diff/Baselines, OCR/AI intelligence, Documentation/Audit Mode (Step
Recorder, `AuditFinding` UI — the data model exists in `CaptureCore` and is
wired into `CaptureHistory`, but there's no capture-a-finding workflow),
and the automation/CLI/URL-scheme/plugin surface. These are deferred with
this stated reason, not silently dropped.

## Module-by-module status

### `mac/Sources/CaptureCore` — ✅ implemented

Pure-logic layer: `Annotation`, `ElementEvidence`, `ProjectManifest`,
`AuditFinding`/`AuditFindingIdGenerator`, the IPC envelope/message types,
`CaptureRect`/geometry primitives, the universal `SnapEngine`, robust
locator-candidate ranking, `FilenameTemplate`, command-based `UndoStack`,
the global-shortcut `ShortcutConflictDetector`, bookmarks-bar redaction/
detection-result models, the `.capture` package reader/writer
(`CaptureProjectDocument`) with atomic writes and a migration seam,
`CaptureLogger`. Covered by `CaptureCoreTests` (10 test files).

Two real bugs found by later implementation agents and fixed here during
integration: `IPCFraming.decodeOne`'s length read used `load(as:)` on a
possibly-unaligned `Data` slice (undefined behaviour — switched to
`loadUnaligned(as:)`), and `ElementEvidence.Locator`/`Typography`'s
synthesized `Decodable` conformance rejected schema-valid payloads
(missing `candidates`/`ancestryFingerprint` keys, or a numeric
`fontWeight`) — both now have custom `Codable` conformances matching the
JSON Schema exactly instead of Swift's stricter synthesized behaviour.

### `mac/Sources/CaptureCapture` — ✅ implemented

Global shortcut registration (`NSEvent` global+local monitors, live
rebinding, `UserDefaults` persistence, real macOS screenshot-shortcut
keycodes for conflict detection), the Capture-Area-to-Window-Capture
interaction as a pure state machine (crosshair → drag → Space toggles to
window mode → click captures → Space toggles back → Escape cancels →
modifier-click for no-shadow) plus its AppKit controller, a
`ScreenCaptureKit`/`SCScreenshotManager`-based capture engine (full-screen/
window-with-or-without-shadow/area), a repeat-area store, and the
bookmarks-bar-privacy detector's Tier 1 (`AXUIElement` walk, Chromium-family
heuristics) and Tier 3 (stored calibration) logic. Covered by
`CaptureCaptureTests` (34 test cases across 4 files) — all pure-logic
(state machine, shortcut persistence, tier-combining math); AppKit/
ScreenCaptureKit/AXUIElement calls are real API usage but structurally
can't be unit-tested without a live display.

**Known uncertain spots** (flagged by the implementing agent, not silently
assumed correct): the exact macOS 14 property name for excluding a single
window's shadow in `SCStreamConfiguration` (medium confidence); Chromium's
exact `AXUIElement` role/description strings for its bookmarks bar
(heuristic, needs validation against a live Chrome + Accessibility
Inspector — Tier 2, the extension-reported-geometry fallback, doesn't
depend on this and is fully implemented on the extension side).

**Real permissions gap found and fixed in docs**: global shortcuts need
the **Input Monitoring** TCC permission (distinct from Accessibility),
which `docs/PERMISSIONS.md` didn't originally list — now documented,
including the open question of whether to switch to Carbon's
`RegisterEventHotKey` to avoid the prompt entirely.

### `mac/Sources/CaptureEditor` — ✅ implemented

The layered document renderer (Canvas → Backdrop → Source → Appended
images → Redactions → Measurements → Vector annotations), `CGContext`
drawing for every `Annotation.Kind` (arrow, line, rectangle, ellipse,
polygon/star/hexagon/bracket/brace/callout-bubble, freehand, highlighter,
spotlight, counter, magnifier, stamp, cursor, measurement), real CoreImage
redaction (Gaussian blur, regular mosaic, and a seeded-shuffle "secure
randomized pixelation" — honestly documented as a mitigation, not a
cryptographic guarantee), Counter renumbering, non-destructive crop with
snap-engine integration and keyboard nudging, concrete `UndoCommand`
implementations for every edit type, and a PNG/JPEG/TIFF export pipeline
with a `PDFExporting` protocol seam (not importing `CapturePDF` directly).
Covered by `CaptureEditorTests` (7 files, 845 lines) for all pure-logic
pieces (Counter formatting/renumbering, crop math, undo/redo correctness).

**Honest partial implementations**: `RedactionMode.textOnly` and
`.objectRemoval` fail closed to solid redaction / heavy blur respectively
(no OCR-glyph-region input or real inpainting available in this module) —
documented as concealment, not reconstruction, so nothing is silently
under-redacted. Stamp `type: "custom"` (arbitrary SVG) is not implemented —
no SVG parser available — and renders a visible placeholder rather than
nothing. Tiled rendering for very large (e.g. 400,000px) scrolling-capture
images is an explicit documented TODO, not implemented.

**Highest-risk unverified spot** (the implementing agent's own words): the
CoreImage-vs-CoreGraphics coordinate-space conversion math in the
redaction renderer (`canvasRectToCIImageSpace`) — a flip bug there would
misplace a redaction, which is a privacy bug, not merely cosmetic. This is
the single highest-priority thing to hand-verify against real screenshots
on a Mac before trusting redaction placement.

### `mac/Sources/CaptureHistory` — ✅ implemented

A hand-written wrapper around the raw `SQLite3` C API (WAL mode, prepared
statements, bound parameters — no string-interpolated SQL), the full
schema (`captures`, `projects`, `capture_tags`, `audit_findings`, and FTS5
virtual tables), `HistoryStore`'s DAO layer (insert with dedupe-by-
content-hash, FTS5 search, retention purge with per-project overrides),
and `AuditFindingIdGenerator` integration for sequential per-category IDs.
Covered by `CaptureHistoryTests` (6 files, 677 lines): schema
creation/idempotency, insert/retrieve round-trip, dedupe, FTS5 search
correctness (including prefix/multi-term matching and re-indexing after
edits), retention purge (age-based, forever-never-deletes, per-project
override, idempotency), and `AuditFindingIdGenerator` sequencing.

### `mac/Sources/CaptureBrowserBridge` + `CaptureInspection` — ✅ implemented

The Unix-socket IPC server (raw BSD sockets — a deliberate choice over
`Network.framework`'s `NWListener`, explained below), per-message-type
payload validation against hand-written `Decodable` structs matching
`schemas/ipc/messages.schema.json` exactly (no generic "execute" path —
every message type maps to one explicitly registered handler), tab-session
lifecycle management, and an `ElementEvidence` store supporting both
inbound (`element.pin`) and app-initiated request/response
(`element.captureRequest` → `element.evidence`) flows. `CaptureInspection`
builds on this with real WCAG contrast math (verified against the
black/white 21:1 reference and the spec's own `#FFFFFF`-on-`#111111` ≈
18.9:1 example), the Design Forensics Card content model (never fabricates
CSS provenance — renders "computed value known, source unavailable" when
`sourceUnavailable` is set), and the one-click copy-action formatters.
Covered by `CaptureBrowserBridgeTests` (6 files, including a genuine
attempted end-to-end Unix-socket round-trip test) and
`CaptureInspectionTests` (3 files).

**Design note**: raw BSD sockets (`socket`/`bind`/`accept` on `AF_UNIX`)
were used instead of the originally-suggested `Network.framework`, because
the implementing agent judged `NWListener` bound to a Unix-domain-socket
path (as opposed to its much more commonly documented TCP/Bonjour cases) a
corner of that API it could not recall with high confidence uncompiled,
whereas raw POSIX `AF_UNIX` socket calls are decades-old and well-understood
even without a compiler to check against. This is a reasonable
uncompiled-code risk trade-off, documented in `UnixSocketServer.swift`
itself, not a silent deviation from the architecture doc (the security
properties — 0700 directory, 0600 socket, length-prefixed framing via
`CaptureCore.IPCFraming` — are unchanged either way).

### `mac/Sources/CapturePDF` — ✅ implemented (no dedicated test target)

`PDFExporter` (single/multi-image → PDF, matching Part I §26's "single
image; multiple captures; scrolling capture split into pages") and
`PDFRedactor` (rasterizes only pages containing a redaction — PDFKit has
no content-stream API to delete text runs under a rect, so this is the
only approach that's actually safe against copy/paste recovery; explicitly
documented as a disclosed trade-off, since it also un-selects any other
text on that same page). Written by the orchestrating session directly
(not a parallel agent), without a `CapturePDFTests` target — **this is a
real gap**: `mac/Package.swift` has no `CapturePDFTests` entry and no unit
tests exist for this module.

### `mac/Sources/CaptureRecording` — ⛔ not implemented

Phase 5 in the spec's own sequencing. Contains only a placeholder source
file (`Placeholder.swift`) so the SwiftPM target isn't empty (an empty
target directory fails `swift build` outright) — no recording capability
exists.

### `mac/Sources/CaptureUI` + `mac/Sources/CaptureApp` — ✅ implemented (the integration layer)

This is where the six modules above actually become an app. Design tokens
carry the spec's exact palette and semantic colour mapping (dynamic
light/dark `NSColor`/`Color`). `MenuBarController` wires an `NSStatusItem`
to real capture triggers. `CaptureOverlayWindow`/`CaptureFlowController`
are the real crosshair/window-picker overlay driving
`CaptureCapture.AreaToWindowCaptureController` and turning a finished
selection into a real `ScreenCaptureEngine` call. `EditorWindowController`/
`CanvasView`/`EditorToolbar`/`InspectorView` host `CaptureEditor.CanvasRenderer`'s
output in a real `NSView`, push interactive annotation edits through
`CaptureCore.UndoStack`, and implement copy/export/`.capture` save-and-
reopen. `QuickAccessOverlay`, `HistoryWindowController` (backed by
`HistoryStore.search`/`.recentCaptures`), `SettingsWindowController` +
`ShortcutsSettingsView` (a real shortcut recorder wired to
`GlobalShortcutManager`, the snap-engine checkbox list, the bookmarks-bar
privacy toggle/redaction-style picker), `CommandPaletteWindow`, and
`PermissionOnboardingView` round out Part I §28's primary surfaces.
`CaptureApp`'s `AppDelegate`/`main.swift`/`AppEnvironment` are the actual
entry point: opens `HistoryStore` at
`~/Library/Application Support/Capture/history.sqlite`, starts
`BrowserBridgeService` listening on the Unix socket at launch, and runs the
permission-onboarding-then-normal-operation flow.

**Phase 1 acceptance scenario (Part I §39 "First milestone") is wired end
to end**: global shortcut → capture overlay → `ScreenCaptureEngine` →
editor window with a real `CGImage` → interactive
arrow/rectangle/ellipse/text/freehand/redact creation → crop → copy to
clipboard → `HistoryStore.insertCapture` (indexed on capture, not gated
behind an explicit save) → save as `.capture` via
`CaptureProjectDocument.save` → reopen via `.load` with annotations still
editable.

**Phase 3 acceptance scenario ("First browser milestone") is wired end to
end**, including a real fix applied during integration review: the
implementing agent found that `BrowserBridgeService` exposed no way to
*discover* that a tab session or new evidence existed — every read API
(`latestEvidence(forTabSession:)`, `resolveAnchor`, ...) required already
knowing the `UUID` a `session.start` request produced, but nothing told
`CaptureApp` that `UUID`. Fixed by adding
`BrowserBridgeService.onSessionStarted`/`.onEvidenceUpdated` callback
properties (set by `AppEnvironment` before `start()`) so the app is now
actually notified the moment the extension pins an element, instead of
Phase 3 being unreachable outside manual testing with a known session id.
The capture-target rect still needs a browser window frame to anchor
against; `AppEnvironment.frontmostBrowserWindowFrame()` resolves this via
`CGWindowListCopyWindowInfo` filtered to known browser bundle IDs'
frontmost window — a **best-effort heuristic** (assumes the browser is
still frontmost when the callback fires, and picks the first matching
window if more than one is open), stacked on top of
`BrowserElementCaptureFlow.resolveScreenRect`'s own already-documented
"least-trusted, unverified on a real browser/DPI combination" coordinate
assumption. Both are honestly uncertain, not silently assumed correct —
validating this whole chain against a real Chrome window is the single
most important manual test for Phase 3 once this builds on a Mac.

**Two small app-owned seams fill real gaps found in other modules, kept in
`CaptureApp` rather than retroactively edited into the modules that don't
have them**: `ContentAddressedBlobStore` (no module defined the
content-addressed `SHA256 -> blob` storage `CaptureCore.Data.sha256Hex()`'s
own doc comment names as the intended design), and an `editor-state.json`
sidecar written alongside (not through) `CaptureProjectDocument.save` for
crop rect / canvas size / Backdrop settings, since `ProjectManifest` has no
field for them.

Not implemented in this layer: Phases 4-9's UI (recording controls,
responsive-lab panes, accessibility-audit views, ecommerce panels, visual
diff, automation/CLI surface) — there is nothing to wire them to yet.

### `native-host/` (`CaptureNativeHost`) — ✅ implemented

The Chrome Native Messaging host binary: stdin/stdout length-prefixed
framing (`StdioFraming`/`FrameReader`, handling partial-read pipe
semantics correctly), a raw-BSD-socket client to the app's Unix socket
with a 10s receive timeout, launch-Capture.app-and-retry logic (fixed
250ms × 8 backoff, ~2s total) when the app isn't already running, and
synthesized `INTERNAL_ERROR`/`PAYLOAD_TOO_LARGE` error frames back to
Chrome on failure rather than hanging. Covered by `CaptureNativeHostTests`
(frame encode/decode round-trip, partial-header/partial-payload,
multi-frame-in-buffer, oversized-frame rejection, inbound-id extraction
from valid/malformed JSON).

`scripts/install-native-host.sh` / `uninstall-native-host.sh` are real,
working bash — **actually dry-run tested in this sandbox** (bash itself
runs here even though Swift doesn't): validates the extension ID against
Chrome's real ID alphabet, refuses to run with no ID and no wildcard
fallback, and the generated Native Messaging host manifest JSON was
validated through `python3 -m json.tool`.

### `extensions/chromium/` — ✅ implemented and verified

Manifest V3, permissions exactly matching `docs/PERMISSIONS.md` (no
`content_scripts` entry — the inspector is injected via
`chrome.scripting.executeScript` on the Inspect command's user gesture).
`src/shared/` mirrors `schemas/ipc/*` and `schemas/project/element-evidence.schema.json`
field-for-field. `src/shared/locator.ts` implements the exact 8-tier robust
locator strategy. `src/background/index.ts` holds the sole
`chrome.runtime.connectNative` port and relays between content scripts and
the native host. `src/content/inspector.ts` is the real Inspect Mode
overlay: closed-shadow-DOM host (so its own styles can't leak into or be
overridden by the host page), throttled hover via `elementsFromPoint`, the
hover card matching the spec's exact example format, click-to-pin building
a full `ElementEvidence` (with a best-effort CSS-provenance pass that
correctly falls back to `sourceUnavailable` on cross-origin
`SecurityError` rather than fabricating a source), arrow-key DOM
navigation, and an explicit `teardown()` removing every listener/observer
it added. `src/content/bookmarksBar.ts` implements Tier 2 geometry
reporting (`window.innerWidth` etc. only — never searches the page DOM,
per the hard requirement that the bookmarks bar is browser chrome, not
page content).

**Actually run in this sandbox, with real output** (re-verified
independently before this document was written):
```
npm run typecheck   → 0 errors
npm run build         → succeeds; dist/ contains background.js (ESM),
                        popup/options (ESM), 3 content scripts (IIFE —
                        content scripts run as classic scripts, not
                        modules; the build was originally ESM-only for
                        everything and would have thrown
                        "Unexpected token 'export'" the first time
                        Inspect Mode was triggered in a real browser,
                        a real bug the implementing agent found and fixed)
npm test                → 34/34 tests passing (contrast: 12, locator: 10,
                        inspector teardown: 6, ipc: 6)
```

**Deliberately deferred** (one-line reasons, not silent drops): full
AccName/ARIA-in-HTML accessible-name algorithm (a solid best-effort subset
implemented instead); CSS provenance computed for a fixed "important
properties" list rather than every computed property; actual-rendered-
font-face detection left `null` rather than guessed (no reliable API
without the experimental Font Access API); multi-element comparison UI
(bookkeeping exists, no rendering); bookmarks-bar Tier 3 manual-calibration
round-trip UI (only Tier 2 reporting implemented on the extension side).

### `schemas/` — ✅ implemented, but drift-checking is manual

JSON Schema (draft-07) contracts for the IPC envelope/messages,
`ElementEvidence`, `Annotation`, the `.capture` project manifest, and
`AuditFinding`. There is **no automated schema-vs-code validator** in this
build (deliberately avoided to keep dependencies minimal, matching Part I
§37's "prefer system framework if practical") — Swift and TypeScript types
are hand-mirrored and were re-checked against the schemas during
integration (catching the two `ElementEvidence` bugs above), but nothing
enforces this automatically on future changes. See `schemas/README.md`.

### `fixtures/` — ✅ implemented

Four static HTML fixture pages (inspector, accessibility, responsive,
Shopify-like PDP) per Part I §31's testing-strategy requirement, for
manual `chrome://extensions` testing of the real inspector against real
DOM — not wired into any automated test run. See `fixtures/README.md`.

### Icon and visual design — ✅ implemented

A net-catching-a-pixel icon per the spec's exact requirements (no camera/
aperture/crop-corners/monitor/cursor imagery), procedurally generated and
rasterized in-sandbox via headless Chromium + Pillow (an early version
using SVG `feDropShadow` filters was replaced after those filters
triggered a genuine rendering-clip bug in Chromium's software rasterizer —
see `design/icon/README.md`). `scripts/generate-icons.sh` regenerates
higher-fidelity output from the vector source on a real Mac via
`qlmanage`/`sips`/`iconutil`. `CaptureUI`'s design tokens (if the
integration pass completed them — see above) carry the spec's exact
palette and semantic colour mapping.

## Testing summary

See `docs/TEST_MATRIX.md` for the full breakdown. In one line: **every
Swift test suite is written but unrun (no toolchain); the Chromium
extension's test suite is written, run, and passing (34/34).**

## Known gaps, honestly listed

- `CapturePDF` has no test target.
- No golden-image tests, no Playwright-based extension integration tests
  against the `fixtures/` sites, no performance tests, no real end-to-end
  test of the full content-script → service-worker → native-host →
  Unix-socket → app chain (each hop is unit-tested in isolation; nothing
  currently drives all of them together, which would need a real macOS +
  Chrome environment this sandbox doesn't have).
- No automated JSON-Schema-vs-Swift/TypeScript-type drift check.
- Phases 4-9 are not implemented at all (see "Scope" above).
- `docs/decisions/` covers the three most architecturally significant
  choices made without a stakeholder available to ask (SwiftPM instead of
  `.xcodeproj`, `Capture*` instead of `Aspect*` module names, unsandboxed
  Developer-ID-style distribution) — smaller in-module decisions are
  documented inline in code comments by the implementing agents rather
  than as separate decision records.
- The bookmarks-bar-privacy hard requirement is real on the Tier 2
  (extension-reported geometry) and Tier 3 (calibration) paths; Tier 1
  (live `AXUIElement` role/description matching for each browser family)
  is implemented but its accuracy against real, current Chrome/Edge/Brave
  builds is unverified.
- Phase 3's auto-fire path (browser element pinned → app notified →
  captured) depends on a frontmost-window heuristic
  (`AppEnvironment.frontmostBrowserWindowFrame()`) that assumes the
  browser is still the frontmost app when the callback fires — see the
  `CaptureUI`/`CaptureApp` section above. Reasonable, not guaranteed.
- No UI surfaces `AuditFinding` creation/browsing yet — the model and its
  `CaptureHistory` persistence are real, but there is no "Capture Finding"
  command anywhere in `CaptureUI` (Part III §17's Step Recorder / audit
  mode is Phase 7, out of this build's scope, so this isn't a surprise —
  named here so it isn't mistaken for an oversight in the Phase 0-3 UI).

## What to do next (for whoever picks this up on a real Mac)

1. `cd mac && swift build` — fix whatever doesn't compile. Given six
   independent hand-written passes with no compiler in the loop, expect
   real errors, not zero.
2. `cd mac && swift test` — same expectation.
3. `cd native-host && swift build && swift test`.
4. Hand-verify the CoreImage/CoreGraphics coordinate math in
   `CaptureEditor`'s redaction renderer against a real screenshot before
   trusting redaction placement for anything privacy-sensitive.
5. Validate the bookmarks-bar Tier 1 `AXUIElement` heuristics against a
   real, current Chrome window with Accessibility Inspector.
6. Run the Phase 1 and Phase 3 acceptance scenarios from the spec by hand
   (area capture → annotate → save/reopen a `.capture` project; hover an
   element in Chrome → pin it → see it in `Capture.app`) and fix whatever
   breaks — for Phase 3 specifically, confirm
   `AppEnvironment.frontmostBrowserWindowFrame()` and
   `BrowserElementCaptureFlow.resolveScreenRect()` actually produce the
   right on-screen rect against a real Chrome window; both are documented,
   reasoned-through guesses, not verified behaviour.
7. `scripts/generate-icons.sh` to regenerate the app icon from the vector
   source via native macOS tools (the committed PNGs were rasterized with
   headless Chromium + Pillow in the Linux sandbox this was built in —
   functional, but `qlmanage`/`sips` will produce a crisper result).
