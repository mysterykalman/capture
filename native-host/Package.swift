// swift-tools-version:5.10
import PackageDescription

// CaptureNativeHost: the small Chrome Native Messaging host binary.
// Chrome launches this as a separate process per connection and exchanges
// length-prefixed JSON over stdin/stdout. It forwards validated messages to
// the running Capture.app over a Unix domain socket. It intentionally does
// NOT depend on the mac/ SwiftPM package (which links AppKit/SwiftUI) so it
// stays a tiny, fast-launching helper — see docs/IPC_PROTOCOL.md.

let package = Package(
    name: "CaptureNativeHost",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(name: "CaptureNativeHost", path: "Sources/CaptureNativeHost"),
        .testTarget(name: "CaptureNativeHostTests", dependencies: ["CaptureNativeHost"], path: "Tests/CaptureNativeHostTests")
    ]
)
