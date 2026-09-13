# 0001 — Swift Package Manager instead of an .xcodeproj

**Status:** decided
**Context:** Part I §3 of the spec suggests `mac/Capture.xcodeproj or
Capture.xcworkspace`. This build environment has no Xcode and no Swift
toolchain at all (confirmed: no `swift`, no `xcodebuild`; swift.org is not
reachable through the sandbox's egress proxy). An `.xcodeproj` is a binary
plist/pbxproj format keyed by generated UUIDs per file reference and build
phase; hand-writing one for dozens of source files with no way to open it
in Xcode or validate it with `xcodebuild -list` is highly error-prone and
essentially unverifiable in this environment.

**Decision:** structure `mac/` and `native-host/` as Swift Package Manager
packages (`Package.swift` + `Sources/`/`Tests/`) instead. SwiftPM fully
supports macOS app targets with AppKit/SwiftUI, asset catalogs (via
`.process()` resource rules, which invoke `actool` during `swift build` on
a real Mac), and produces a plain executable that a build script wraps into
a `.app` bundle with `Info.plist`, an entitlements file, and ad-hoc/Developer
ID code signing.

**Consequences:**
- Building requires `cd mac && swift build -c release`, then
  `scripts/package-app.sh` to assemble `Capture.app` (see
  `docs/BUILD_AND_RUN.md`). There is no `.xcodeproj` to double-click.
- A developer who prefers Xcode can open the folder directly in recent
  Xcode versions (Xcode 16+ opens `Package.swift` as a workspace), or run
  `swift package generate-xcodeproj` (deprecated but still works) if they
  need a classic project file.
- This has **not been validated** — no Swift toolchain exists in this
  environment. The package graph should be inspectable on any Mac with
  `swift package describe` before assuming it is correct.
