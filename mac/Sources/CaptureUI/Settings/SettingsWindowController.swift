import AppKit
import CaptureCapture
import CaptureCore
import SwiftUI

/// Snap Engine settings (spec digest "Universal Snap Engine" > "Settings
/// panel (exact UI copy)": the `Snap to:` checkbox list is transcribed
/// verbatim — Edges/Objects/Guides/Grid/DOM elements/Equal spacing — plus a
/// tolerance slider), wired to real `CaptureCore.SnapSettings`.
@MainActor
public final class SnapSettingsModel: ObservableObject {
    @Published public var enabledCategories: Set<SnapCategory> {
        didSet { onChange(currentSettings) }
    }
    @Published public var tolerancePoints: Double {
        didSet { onChange(currentSettings) }
    }

    public var onChange: (SnapSettings) -> Void

    public init(initial: SnapSettings = .default, onChange: @escaping (SnapSettings) -> Void = { _ in }) {
        self.enabledCategories = Set(SnapCategory.allCases.filter { initial.isEnabled($0) })
        self.tolerancePoints = Double(initial.tolerancePoints)
        self.onChange = onChange
    }

    public var currentSettings: SnapSettings {
        SnapSettings(enabledCategories: enabledCategories, tolerancePoints: CGFloat(tolerancePoints))
    }

    public func binding(for category: SnapCategory) -> Binding<Bool> {
        Binding(
            get: { self.enabledCategories.contains(category) },
            set: { isOn in
                if isOn { self.enabledCategories.insert(category) } else { self.enabledCategories.remove(category) }
            }
        )
    }
}

/// Browser Bookmarks Bar Privacy Rule settings (hard requirement, default
/// ON) plus the redaction-style picker — spec digest: "Always hide browser
/// bookmarks bar: ON" / "Redaction styles (exact list): Soft Blur, Pixelate,
/// Solid" / "Default style: Soft Blur".
@MainActor
public final class PrivacySettingsModel: ObservableObject {
    @Published public var bookmarksBarPrivacyEnabled: Bool { didSet { onChange(self) } }
    @Published public var redactionStyle: BookmarksBarRedactionStyle { didSet { onChange(self) } }

    public var onChange: (PrivacySettingsModel) -> Void

    public init(bookmarksBarPrivacyEnabled: Bool = true, redactionStyle: BookmarksBarRedactionStyle = .default, onChange: @escaping (PrivacySettingsModel) -> Void = { _ in }) {
        self.bookmarksBarPrivacyEnabled = bookmarksBarPrivacyEnabled
        self.redactionStyle = redactionStyle
        self.onChange = onChange
    }
}

@MainActor
public final class SettingsWindowController: NSWindowController {
    public init(
        shortcutsModel: ShortcutsSettingsModel,
        snapModel: SnapSettingsModel,
        privacyModel: PrivacySettingsModel
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsRootView(shortcutsModel: shortcutsModel, snapModel: snapModel, privacyModel: privacyModel))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct SettingsRootView: View {
    @ObservedObject var shortcutsModel: ShortcutsSettingsModel
    @ObservedObject var snapModel: SnapSettingsModel
    @ObservedObject var privacyModel: PrivacySettingsModel

    var body: some View {
        TabView {
            ShortcutsSettingsView(model: shortcutsModel)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            SnapSettingsPane(model: snapModel)
                .tabItem { Label("Snapping", systemImage: "align.horizontal.left") }
            PrivacySettingsPane(model: privacyModel)
                .tabItem { Label("Privacy", systemImage: "eye.slash") }
        }
        .frame(width: 620, height: 460)
        .background(Color.captureCanvasBackground)
    }
}

private struct SnapSettingsPane: View {
    @ObservedObject var model: SnapSettingsModel

    private static let rows: [(SnapCategory, String)] = [
        (.edges, "Edges"), (.objects, "Objects"), (.guides, "Guides"),
        (.grid, "Grid"), (.domElements, "DOM elements"), (.equalSpacing, "Equal spacing")
    ]

    var body: some View {
        Form {
            Section("Snap to:") {
                ForEach(Self.rows, id: \.0) { category, label in
                    Toggle(label, isOn: model.binding(for: category))
                }
            }
            Section("Tolerance") {
                HStack {
                    Slider(value: $model.tolerancePoints, in: 1...32, step: 1)
                    Text("\(Int(model.tolerancePoints)) pt").font(CaptureFont.monospacedLabel()).frame(width: 44)
                }
            }
            Text("Hold the temporary disable modifier while dragging to bypass snapping.")
                .font(CaptureFont.secondary())
                .foregroundStyle(Color.captureTextSecondary)
        }
        .padding(CaptureMetrics.contentPadding)
        .formStyle(.grouped)
    }
}

private struct PrivacySettingsPane: View {
    @ObservedObject var model: PrivacySettingsModel

    var body: some View {
        Form {
            Section("Browser Bookmarks Bar Privacy Rule") {
                Toggle("Always hide browser bookmarks bar", isOn: $model.bookmarksBarPrivacyEnabled)
                Text("Whenever a supported browser's bookmarks bar is visible in a screenshot or recording, Capture automatically obscures it — independent of the page, scroll position, or viewport.")
                    .font(CaptureFont.secondary())
                    .foregroundStyle(Color.captureTextSecondary)
                Picker("Redaction style", selection: $model.redactionStyle) {
                    ForEach(BookmarksBarRedactionStyle.allCases, id: \.self) { style in
                        Text(Self.label(for: style)).tag(style)
                    }
                }
                .disabled(!model.bookmarksBarPrivacyEnabled)
            }
        }
        .padding(CaptureMetrics.contentPadding)
        .formStyle(.grouped)
    }

    private static func label(for style: BookmarksBarRedactionStyle) -> String {
        switch style {
        case .softBlur: return "Soft Blur"
        case .pixelate: return "Pixelate"
        case .solid: return "Solid"
        }
    }
}
