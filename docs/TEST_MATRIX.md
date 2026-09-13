# Capture — Test Matrix

What's tested, how, and — honestly — whether it has actually been run.
Cross-reference with `docs/IMPLEMENTATION_STATUS.md` for per-module status.

## Native macOS app (`mac/`, `native-host/`)

| Layer | What's covered | Run in this build? |
|---|---|---|
| `CaptureCoreTests` | Snap engine geometry, filename templates, annotation/project JSON round-trips, IPC framing + response coding, locator ranking, shortcut conflict detection, bookmarks-bar detection-result priority logic | **No** — no Swift toolchain in this sandbox |
| `CaptureCaptureTests` | Area-to-window state machine, shortcut persistence, bookmarks-bar detector combining logic | **No** |
| `CaptureEditorTests` | Counter renumbering, crop math, undo/redo command correctness | **No** |
| `CaptureHistoryTests` | Schema creation, insert/search round-trip, FTS5 matching, dedupe-by-hash, retention purge | **No** |
| `CaptureBrowserBridgeTests` | Per-message-type payload validation, tab-session lifecycle, (attempted) end-to-end Unix-socket exchange | **No** |
| `CaptureInspectionTests` | ForensicsCard summarization, WCAG contrast math, copy-action formatters | **No** |
| `CaptureNativeHostTests` | Wire framing (including partial-read/multi-frame edge cases), inbound-id extraction | **No** |

All of the above are written, hand-reviewed Swift source with no compiler
verification — see the environment note in `docs/IMPLEMENTATION_STATUS.md`.
Running them for real is the single highest-value next step for whoever
picks this up on an actual Mac: `cd mac && swift test`, `cd native-host &&
swift test`.

## Chromium extension (`extensions/chromium/`)

| Check | Command | Run in this build? |
|---|---|---|
| Type checking | `npm run typecheck` | **Yes** |
| Bundle build | `npm run build` | **Yes** |
| Unit tests (vitest, jsdom) | `npm test` | **Yes** |

See `docs/IMPLEMENTATION_STATUS.md` for the actual pass/fail counts from
the run performed while building this repository.

## Golden-image tests (Part I §31)

Deterministic fixture renders for arrow/text/spotlight/Counter/
redaction/Backdrop/magnifier compared with tolerance — **not implemented**.
This needs a real rendering pipeline running on an actual Mac to produce
reference images against; it's listed here as a known gap, not silently
dropped.

## Integration tests (content script → service worker → Native Messaging
host → Unix socket → Capture app)

**Not implemented** — needs a real macOS + Chrome environment. The pieces
it would exercise (`CaptureBrowserBridgeTests`' attempted Unix-socket
round-trip, `CaptureNativeHostTests`' framing tests, the extension's
background-worker native-port handling) are each unit-tested in isolation,
but nothing currently drives the full chain end-to-end.

## Performance tests (app launch, idle CPU/memory, editor with a large
image, history search, extension impact with Inspect Mode on/off)

**Not implemented** — needs a real Mac to measure any of these
meaningfully.

## Manual fixture sites

`fixtures/` (see `fixtures/README.md`) provides real DOM to load the
extension against manually in Chrome — useful for exploratory testing of
the inspector overlay, locator generation, and bookmarks-bar geometry
reporting beyond what the jsdom-based unit tests cover, once loaded per
`docs/BUILD_AND_RUN.md`.
