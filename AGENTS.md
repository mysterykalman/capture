# Working in this repository (for coding agents and humans alike)

Capture is being built against a large master specification. This file is
the condensed, load-bearing subset of that spec's own "coding-agent
workflow" and "non-negotiable principles" sections — read it before making
architectural changes. For full context, also read `docs/ARCHITECTURE.md`
and `docs/IMPLEMENTATION_STATUS.md` (the latter is the source of truth for
what's actually done vs. planned; keep it honest and current).

## Non-negotiable principles

- **Native Mac core.** Swift, SwiftUI for the app shell, AppKit-backed
  custom views where precision pointer handling/canvas editing needs it.
  Never Electron, never an embedded/bundled Chromium browser as product
  architecture, never a webview as the main app.
- **Local-first.** Screenshots, editor, annotations, measurement, OCR,
  history, projects, and browser inspection of the active local page must
  all work with no account and no network. Cloud/AI features are optional
  modules, opt-in, never silently invoked.
- **Non-destructive editing.** Don't flatten annotations/redactions during
  normal editing — only on explicit export or an explicit "Flatten"
  command. See `docs/PROJECT_FORMAT.md`.
- **Privacy.** No silent screenshot upload, no silent inspection of every
  browser tab, no capturing/displaying secure-field keystrokes, minimum
  browser-extension permissions (see `docs/PERMISSIONS.md`).
- **Chrome Native Messaging, never a localhost server.** See
  `docs/IPC_PROTOCOL.md` — this is a hard requirement, not a preference.

## Before making a change

1. Check `docs/IMPLEMENTATION_STATUS.md` for what's already real vs.
   scaffolded/not-started in the area you're touching.
2. Check `docs/ARCHITECTURE.md` for module boundaries — `CaptureCore` has
   no AppKit/SwiftUI/ScreenCaptureKit dependency and everything else
   depends on it, not the other way around.
3. If you're touching the browser bridge, the IPC envelope/message shapes
   in `schemas/ipc/*.schema.json` are the contract — the Swift types in
   `mac/Sources/CaptureCore/Models/IPCMessage.swift` and the TypeScript
   types in `extensions/chromium/src/shared/ipc.ts` must both match them.
   Same for `schemas/project/element-evidence.schema.json` and
   `ElementEvidence` on both sides.
4. If you're touching the `.capture` project format, read
   `docs/PROJECT_FORMAT.md` first — schema-version migrations, atomic
   writes, and "never rewrite source media just because an annotation
   changed" are all load-bearing constraints, not style preferences.

## Definition of done for a feature

Not complete until: the happy path works; error states are handled; a
keyboard flow exists where appropriate; it's represented correctly in
save/project state; undo/redo works if it edits a document; export renders
it correctly; accessibility labels exist for its controls; tests cover the
core logic; permission/failure degradation is documented; and
`docs/IMPLEMENTATION_STATUS.md` reflects it. A button wired to an empty
function is not "done."

## Honesty rules

- Never claim a stub, disabled control, hard-coded result, placeholder, or
  fake demo is complete.
- Never silently drop a requirement — mark it deferred in
  `docs/IMPLEMENTATION_STATUS.md` with a reason and, if known, a target
  phase.
- Never claim Swift code "builds" or "passes tests" unless you actually ran
  `swift build`/`swift test` and saw it succeed. As of this writing, no
  Swift toolchain has been available in any environment this project has
  been built in — check `docs/IMPLEMENTATION_STATUS.md`'s environment note
  before assuming that's changed.

## Phase sequencing

The master spec explicitly sequences work into Phases 0-9 (foundation →
core screenshot utility → project format/precision → Chromium inspector →
scrolling/stable capture → recording → responsive/diff → accessibility/audit
→ ecommerce intelligence → collaboration/extensibility) and says not to
jump into ecommerce/AI/responsive-lab work before the capture/editor
foundation is real. Follow that order unless a technical dependency
genuinely requires reordering — and if you do reorder, note why in
`docs/decisions/`.
