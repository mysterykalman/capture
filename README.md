# Capture

**Capture. Inspect. Prove.**

Capture is a native macOS screenshot, annotation, and visual-evidence
application with a companion Chromium browser extension for DOM-aware
inspection and capture — hover a webpage element to see its real dimensions,
font, colour, and accessible name, pin it, and anchor an annotation to the
actual DOM element rather than a fixed pixel coordinate.

See [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md) for a
current, honest, module-by-module accounting of what is implemented,
partially implemented, or not yet started, and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the system design and
why this build's scope stops where it does.

## Repository layout

```text
mac/          Native macOS app (Swift Package Manager): capture engine,
              non-destructive editor, local history, browser bridge, PDF
              export, and the app shell tying it together.
native-host/  The Chrome Native Messaging host — a small, separate,
              fast-launching binary Chrome spawns per connection.
extensions/
  chromium/   Manifest V3 browser extension (TypeScript) — the Inspect
              Mode overlay, DOM locator strategy, and native-messaging bridge.
  safari/     Not started (planned after the Chromium bridge stabilizes).
docs/         Architecture, implementation status, build/run instructions,
              IPC protocol, project file format, permissions, decisions.
schemas/      JSON Schema contracts shared by the Swift and TypeScript sides.
fixtures/     Static HTML test pages for the extension.
design/       Icon and visual design source assets.
scripts/      Build, packaging, install, and test scripts.
```

## Build environment note

This project was built in a Linux sandbox with no Xcode or Swift toolchain
available (and no way to install one). **All Swift source under `mac/` and
`native-host/` has been written but never compiled or run** — building it
requires a real Mac with Xcode 16+. The Chromium extension is plain
TypeScript/HTML/CSS/JSON and **has** been built and tested for real, in
this sandbox, with Node.js:

```
npm run typecheck   → 0 errors
npm run build        → succeeds
npm test              → 34/34 passing
```

See `docs/IMPLEMENTATION_STATUS.md` for the full, honest detail — including
two real bugs found and fixed during integration, and what's genuinely
wired end-to-end versus still a documented gap.

## Quick start

See [`docs/BUILD_AND_RUN.md`](docs/BUILD_AND_RUN.md) for full build, run,
and browser-extension installation steps. In short:

```bash
scripts/bootstrap.sh           # installs extension deps; checks for Swift on macOS
scripts/build-extension.sh     # builds extensions/chromium/dist/
scripts/generate-icons.sh      # (macOS only) rasterizes the app icon
scripts/package-app.sh         # (macOS only) builds + assembles + signs Capture.app
scripts/test-all.sh            # runs every test suite this machine can run
```
