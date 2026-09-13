// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Capture", targets: ["CaptureApp"]),
        .executable(name: "CaptureBridgeHost", targets: ["CaptureBridgeHost"]),
        .library(name: "CaptureCore", targets: ["CaptureCore"])
    ],
    targets: [
        // Pure-logic layer: models, snap engine math, shortcut parsing, redaction
        // calibration storage, diff algorithm. No AppKit/SwiftUI import so this
        // layer is unit-testable and platform-agnostic wherever possible.
        .target(
            name: "CaptureCore",
            dependencies: [],
            path: "Sources/CaptureCore"
        ),
        // AppKit/SwiftUI views, windows, overlays, editor canvas.
        .target(
            name: "CaptureUI",
            dependencies: ["CaptureCore"],
            path: "Sources/CaptureUI"
        ),
        // App entry point, menu bar item, app delegate, global shortcut
        // registration, XPC/socket server for the bridge host.
        .executableTarget(
            name: "CaptureApp",
            dependencies: ["CaptureCore", "CaptureUI"],
            path: "Sources/CaptureApp",
            resources: [
                .process("../../Resources/Assets.xcassets")
            ]
        ),
        // Chrome Native Messaging host: stdin/stdout length-prefixed JSON,
        // forwards to CaptureApp over a local Unix domain socket.
        .executableTarget(
            name: "CaptureBridgeHost",
            dependencies: ["CaptureCore"],
            path: "Sources/CaptureBridgeHost"
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            path: "Tests/CaptureCoreTests"
        )
    ]
)
