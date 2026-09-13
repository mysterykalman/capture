import AppKit
import SwiftUI

/// Type tokens. Part I §29 "Design Language": "Use system typography by
/// default" — so this deliberately wraps the San Francisco system font at
/// fixed weights/sizes rather than introducing a custom typeface, while
/// still giving every CaptureUI surface one shared vocabulary (matching
/// "compact control density" and consistent hierarchy) instead of ad hoc
/// `.system(size:)` calls scattered through the UI code.
public enum CaptureFont {
    public static func title(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .default) }
    public static func headline(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold) }
    public static func body(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .regular) }
    public static func secondary(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .regular) }
    public static func monospacedLabel(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
    public static func caption(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .medium) }

    public enum AppKit {
        public static func title(_ size: CGFloat = 15) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
        public static func body(_ size: CGFloat = 12) -> NSFont { .systemFont(ofSize: size, weight: .regular) }
        public static func secondary(_ size: CGFloat = 11) -> NSFont { .systemFont(ofSize: size, weight: .regular) }
    }
}

/// Shared corner-radius / spacing constants, so "compact control density"
/// (Part I §29) stays consistent panel to panel instead of every view
/// picking its own numbers.
public enum CaptureMetrics {
    public static let controlCornerRadius: CGFloat = 6
    public static let panelCornerRadius: CGFloat = 10
    public static let cardCornerRadius: CGFloat = 14
    public static let toolbarHeight: CGFloat = 44
    public static let inspectorWidth: CGFloat = 280
    public static let historyRailWidth: CGFloat = 220
    public static let contentPadding: CGFloat = 12
}
