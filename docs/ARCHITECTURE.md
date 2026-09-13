# Capture — Architecture

This document describes the system design actually implemented in this
repository. For the full product specification this implements a subset of,
see the original master spec (not checked into this repo). For what is
actually built vs. planned, see `IMPLEMENTATION_STATUS.md`.

## Scope of this build

The master specification (~19,000 lines) describes a multi-year product
combining the scope of Shottr, CleanShot X, Snagit, Screen Studio, Chrome
DevTools, Polypane, Percy, and Wappalyzer. It explicitly organizes itself
into Tiers 0-6 and Phases 0-9 and states products should not "ship as one
monolithic first release." This build targets, with real (non-mock) depth:

- **Phase 0 — Foundation**: app scaffold, lifecycle, permission onboarding,
  module boundaries, settings shell, logging.
- **Phase 1 — Core screenshot utility**: area/window/full-screen capture,
  non-destructive editor (arrow/rectangle/ellipse/text/freehand/redact),
  crop, undo/redo, clipboard/save/export, local history.
- **Phase 2 (partial) — Project format and precision**: the `.capture`
  project package format, snap engine, measurement/ruler, colour picker,
  Counter/Spotlight/Magnifier annotation types, filename templates.
- **Phase 3 — Chromium inspector**: MV3 extension, Native Messaging host,
  Unix-socket bridge, Inspect Mode overlay, `ElementEvidence` model,
  DOM-anchored annotations, one-click element capture.

Phases 4-9 (scrolling/stable-capture refinement, full recording engine,
responsive lab, accessibility audit module, performance/SEO/ecommerce
intelligence, visual diff, collaboration/plugins/automation surface) are
**not implemented**. `IMPLEMENTATION_STATUS.md` tracks this per-module.

## Critical environment constraint

This repository was built in a Linux sandbox with no Xcode or Swift
toolchain available, and no network path to install one (swift.org is not
on the sandbox's egress allowlist). **The Swift source under `mac/` and
`native-host/` has been written but never compiled or run.** It must be
built and tested on an actual Mac with Xcode 16+ before it can be trusted.
The Chromium extension under `extensions/chromium/` is plain
TypeScript/HTML/CSS; it **has** been built and unit-tested in this sandbox
with Node.js. See `IMPLEMENTATION_STATUS.md` for exact verification status
of every module.

## Repository layout

```text
Capture/
├── docs/                      Architecture, status, protocol, decisions
├── mac/                       Native macOS app (Swift Package Manager)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── CaptureCore/       Pure-logic layer (no AppKit/SwiftUI import)
│   │   ├── CaptureCapture/    ScreenCaptureKit capture engine, shortcuts
│   │   ├── CaptureEditor/     Non-destructive editor + annotation tools
│   │   ├── CaptureRecording/  Recording pipeline (Phase 5 — scaffold only)
│   │   ├── CaptureHistory/    SQLite history store + FTS5 search
│   │   ├── CaptureBrowserBridge/  Unix-socket IPC server
│   │   ├── CapturePDF/        PDFKit export/redaction (scaffold only)
│   │   ├── CaptureInspection/ Design Forensics Card / CSS inspector UI logic
│   │   ├── CaptureUI/         AppKit/SwiftUI views
│   │   └── CaptureApp/        App entry point, wiring
│   └── Tests/                 XCTest targets mirroring the Sources layout
├── native-host/                Chrome Native Messaging host (separate SPM
│                                package; small, fast-launching, no AppKit)
├── extensions/
│   ├── chromium/                Manifest V3 extension (TypeScript)
│   └── safari/                  Not started — see IMPLEMENTATION_STATUS.md
├── fixtures/                    Test fixture HTML pages for the extension
├── schemas/
│   ├── ipc/                     IPC envelope + per-message payload schemas
│   ├── project/                 .capture manifest, annotation, ElementEvidence
│   └── findings/                AuditFinding schema
└── scripts/                     bootstrap/build/install/test scripts
```

## Module boundaries and dependency direction

```text
CaptureCore  <---  CaptureCapture, CaptureEditor, CaptureHistory,
                   CaptureBrowserBridge, CapturePDF, CaptureRecording
CaptureBrowserBridge  <---  CaptureInspection
CaptureCore, CaptureCapture, CaptureEditor, CaptureHistory, CaptureInspection
    <---  CaptureUI  <---  CaptureApp
```

`CaptureCore` has zero AppKit/SwiftUI/ScreenCaptureKit imports. It holds:
document/annotation models, the `.capture` project format encode/decode,
the universal snap engine's geometry math, the robust locator-candidate
ranking algorithm, filename templating, redaction models, and the IPC
envelope/message Swift types mirroring `schemas/ipc/`. This is the layer
most valuable to unit-test once a Swift toolchain is available, and the
layer every other native module depends on — see
`mac/Sources/CaptureCore/`.

## Process model

Per Part I §5 and §20, browser inspection must not require an embedded
Chromium browser, and the native host must not use an unsecured localhost
server:

```text
Chrome tab (content script)
    |  chrome.runtime.sendMessage
    v
Extension service worker  (extensions/chromium/src/background)
    |  chrome.runtime.connectNative("com.capture.bridge")
    v
CaptureNativeHost  (native-host/ — stdin/stdout, length-prefixed JSON)
    |  Unix domain socket, ~/Library/Application Support/Capture/IPC/capture.sock
    |  socket dir user-only, socket mode 0600
    v
Capture.app  (CaptureBrowserBridge module — validates every message against
              schemas/ipc/*.schema.json before dispatch; no shell
              interpolation, no arbitrary command execution)
```

Image binaries never cross Native Messaging (Chrome's 1 MB message-size
cap). The extension sends metadata/locators; screen pixel capture of the
resolved element rect happens natively via ScreenCaptureKit, anchored to
the browser window's on-screen frame.

## Why SwiftPM instead of an .xcodeproj

See `docs/decisions/0001-spm-instead-of-xcodeproj.md`.

## Why `Capture*` module names instead of the spec's `Aspect*`

See `docs/decisions/0002-module-naming.md`.
