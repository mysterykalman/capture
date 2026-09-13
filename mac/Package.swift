// swift-tools-version:5.10
import PackageDescription

// NOTE: This is a Swift Package Manager project, not an .xcodeproj/.xcworkspace.
// See docs/decisions/0001-spm-instead-of-xcodeproj.md for why.
//
// Build (on a Mac with Xcode 16+ / Swift 5.10+ installed):
//   cd mac && swift build -c release
//   scripts/package-app.sh   (assembles Capture.app from the built executable)

let package = Package(
    name: "Capture",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Capture", targets: ["CaptureApp"]),
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "CaptureCapture", targets: ["CaptureCapture"]),
        .library(name: "CaptureEditor", targets: ["CaptureEditor"]),
        .library(name: "CaptureRecording", targets: ["CaptureRecording"]),
        .library(name: "CaptureHistory", targets: ["CaptureHistory"]),
        .library(name: "CaptureBrowserBridge", targets: ["CaptureBrowserBridge"]),
        .library(name: "CapturePDF", targets: ["CapturePDF"]),
        .library(name: "CaptureInspection", targets: ["CaptureInspection"]),
        .library(name: "CaptureUI", targets: ["CaptureUI"])
    ],
    targets: [
        // Pure-logic layer shared by every module: document/annotation models,
        // the .capture project format, the universal snap engine, the robust
        // locator strategy, filename templating, redaction models, IPC
        // envelope types. No AppKit/SwiftUI import — platform-agnostic and
        // unit-testable wherever a Swift toolchain is available.
        .target(name: "CaptureCore", dependencies: [], path: "Sources/CaptureCore"),

        // Screenshot + recording capture engine: ScreenCaptureKit session
        // management, area/window/full-screen/scrolling capture interaction,
        // global shortcut registration, bookmarks-bar accessibility detection.
        .target(name: "CaptureCapture", dependencies: ["CaptureCore"], path: "Sources/CaptureCapture"),

        // Non-destructive editor: layered canvas renderer, annotation tools,
        // undo/redo command stack, crop, export pipeline.
        .target(name: "CaptureEditor", dependencies: ["CaptureCore"], path: "Sources/CaptureEditor"),

        // Screen recording pipeline (Phase 5 — scaffold only, see
        // docs/IMPLEMENTATION_STATUS.md).
        .target(name: "CaptureRecording", dependencies: ["CaptureCore"], path: "Sources/CaptureRecording"),

        // Local history store: SQLite metadata index + FTS5 search.
        .target(name: "CaptureHistory", dependencies: ["CaptureCore"], path: "Sources/CaptureHistory"),

        // Unix-socket IPC server that the CaptureNativeHost helper (in the
        // sibling native-host/ package) connects to; validates and dispatches
        // browser-bridge requests (Inspect Mode, ElementEvidence ingestion).
        .target(name: "CaptureBrowserBridge", dependencies: ["CaptureCore"], path: "Sources/CaptureBrowserBridge"),

        // PDFKit-backed export/redaction workflows.
        .target(name: "CapturePDF", dependencies: ["CaptureCore"], path: "Sources/CapturePDF"),

        // Design Forensics Card rendering, CSS/typography/colour inspector
        // panels driven by ElementEvidence (browser-bridge dependent).
        .target(name: "CaptureInspection", dependencies: ["CaptureCore", "CaptureBrowserBridge"], path: "Sources/CaptureInspection"),

        // AppKit/SwiftUI views: capture overlay, editor canvas view, settings,
        // history browser, menu bar item, onboarding.
        .target(
            name: "CaptureUI",
            dependencies: ["CaptureCore", "CaptureCapture", "CaptureEditor", "CaptureHistory", "CaptureInspection"],
            path: "Sources/CaptureUI"
        ),

        // App entry point: AppDelegate/App lifecycle, menu bar item,
        // permission onboarding flow, wiring of all modules.
        .executableTarget(
            name: "CaptureApp",
            dependencies: [
                "CaptureCore", "CaptureCapture", "CaptureEditor", "CaptureRecording",
                "CaptureHistory", "CaptureBrowserBridge", "CapturePDF", "CaptureInspection", "CaptureUI"
            ],
            path: "Sources/CaptureApp",
            resources: [
                .process("../Resources/Assets.xcassets")
            ]
        ),

        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"], path: "Tests/CaptureCoreTests"),
        .testTarget(name: "CaptureCaptureTests", dependencies: ["CaptureCapture"], path: "Tests/CaptureCaptureTests"),
        .testTarget(name: "CaptureEditorTests", dependencies: ["CaptureEditor"], path: "Tests/CaptureEditorTests"),
        .testTarget(name: "CaptureHistoryTests", dependencies: ["CaptureHistory"], path: "Tests/CaptureHistoryTests"),
        .testTarget(name: "CaptureBrowserBridgeTests", dependencies: ["CaptureBrowserBridge"], path: "Tests/CaptureBrowserBridgeTests")
    ]
)
