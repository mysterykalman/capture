import CoreGraphics
import Foundation

/// Shared geometry primitives used across the snap engine, annotation
/// frames, and browser-evidence rects. `CaptureCore` intentionally avoids
/// AppKit/SwiftUI/ScreenCaptureKit so it stays a pure-logic, unit-testable
/// layer, but CoreGraphics's numeric types (`CGFloat`) are fine to use.
///
/// NOTE: `CGRect`/`CGPoint`/`CGSize` already conform to `Codable` via
/// CoreGraphics, but their synthesized encoding is `{origin:{x,y},
/// size:{width,height}}`, which does not match the flat `{x,y,width,height}`
/// shape used throughout `schemas/`. `CaptureRect` below is the JSON-facing
/// type; convert to/from `CGRect` at the edges where AppKit code needs it.

public struct CapturePoint: Codable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let zero = CapturePoint(x: 0, y: 0)
}

public struct CaptureSize: Codable, Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public static let zero = CaptureSize(width: 0, height: 0)
}

/// Flat rect matching every `{x, y, width, height}` shape in `schemas/`.
public struct CaptureRect: Codable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: CapturePoint, size: CaptureSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = CaptureRect(x: 0, y: 0, width: 0, height: 0)

    public var origin: CapturePoint { CapturePoint(x: x, y: y) }
    public var size: CaptureSize { CaptureSize(width: width, height: height) }
    public var minX: CGFloat { x }
    public var minY: CGFloat { y }
    public var maxX: CGFloat { x + width }
    public var maxY: CGFloat { y + height }
    public var midX: CGFloat { x + width / 2 }
    public var midY: CGFloat { y + height / 2 }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public init(cgRect: CGRect) {
        self.init(x: cgRect.origin.x, y: cgRect.origin.y, width: cgRect.size.width, height: cgRect.size.height)
    }

    public func intersects(_ other: CaptureRect) -> Bool {
        cgRect.intersects(other.cgRect)
    }
}

public struct EdgeInsets: Codable, Hashable, Sendable {
    public var top: CGFloat
    public var right: CGFloat
    public var bottom: CGFloat
    public var left: CGFloat

    public init(top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public static let zero = EdgeInsets()
}

/// A normalized (0...1) rect, used for calibrated bookmarks-bar masks so
/// they scale with window size instead of being pinned in absolute pixels.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Resolve to pixel coordinates within a container of the given size.
    public func resolved(in containerSize: CaptureSize) -> CaptureRect {
        CaptureRect(
            x: x * containerSize.width,
            y: y * containerSize.height,
            width: width * containerSize.width,
            height: height * containerSize.height
        )
    }
}
