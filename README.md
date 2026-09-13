# Capture

**Capture. Inspect. Prove.**

Capture is a native macOS screenshot, annotation, and screen-recording
application with a companion Chromium browser extension bridge for
DOM-aware capture (element selection, scroll-stitching, browser-chrome
privacy redaction).

This repository is under active build-out. See
[`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) for a
current, honest accounting of what is implemented, partially implemented,
or not yet started, and see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
for the system design.

## Repository layout

```text
macapp/     Native macOS app (Swift Package Manager). Builds Capture.app
            and the CaptureBridgeHost Native Messaging helper.
extension/  Chromium Manifest V3 extension (TypeScript).
docs/       Architecture, implementation status, build/run instructions.
design/     Icon and visual design source assets.
```

## Build environment note

This project was built in a Linux sandbox with no Xcode or Swift toolchain
available. The macOS app source has been written but **not compiled or run**
in this environment — building it requires a real Mac with Xcode 16+. The
Chromium extension is plain TypeScript/HTML/CSS and **has** been built and
tested here. See `docs/IMPLEMENTATION_STATUS.md` for full detail.

## Quick start

See `docs/BUILD_AND_RUN.md`.
