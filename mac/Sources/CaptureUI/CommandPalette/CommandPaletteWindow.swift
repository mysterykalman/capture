import AppKit
import Foundation
import SwiftUI

/// One entry in the `Cmd-K` command palette (Part I §28: "Command palette —
/// all less-common commands, invoked via `Command-K`"). Supplied by
/// `CaptureApp`, which owns every actual action this can invoke.
public struct CommandPaletteItem: Identifiable {
    public let id = UUID()
    public var title: String
    public var subtitle: String?
    public var symbol: String
    public var family: CaptureSemanticColor.Family
    public var action: () -> Void

    public init(title: String, subtitle: String? = nil, symbol: String, family: CaptureSemanticColor.Family = .capture, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.family = family
        self.action = action
    }
}

/// A floating, searchable command list — every less-common command lives
/// here rather than in the toolbar, per Part I §28's "do not put every
/// possible tool in permanent toolbar."
@MainActor
public final class CommandPaletteController {
    private var panel: NSPanel?
    private var items: [CommandPaletteItem] = []

    public init() {}

    public func toggle(items: [CommandPaletteItem]) {
        if panel != nil {
            dismiss()
        } else {
            present(items: items)
        }
    }

    public func present(items: [CommandPaletteItem]) {
        self.items = items
        guard panel == nil else {
            (panel?.contentView as? NSHostingView<CommandPaletteView>)?.rootView = CommandPaletteView(items: items, onDismiss: { [weak self] in self?.dismiss() })
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 480, height: 360)
        let hosting = NSHostingView(rootView: CommandPaletteView(items: items, onDismiss: { [weak self] in self?.dismiss() }))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2 + 80)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    public var isVisible: Bool { panel != nil }
}

private struct CommandPaletteView: View {
    let items: [CommandPaletteItem]
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [CommandPaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.subtitle?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(Color.captureTextSecondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(CaptureFont.body(14))
                    .focused($fieldFocused)
                    .onSubmit { runHighlighted() }
            }
            .padding(12)

            Divider().background(Color.captureSeparator)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        CommandRow(item: item, isHighlighted: index == highlighted)
                            .contentShape(Rectangle())
                            .onTapGesture { item.action(); onDismiss() }
                    }
                    if filtered.isEmpty {
                        Text("No matching commands").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary).padding()
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .background(RoundedRectangle(cornerRadius: CaptureMetrics.panelCornerRadius).fill(Color.captureElevatedBackground))
        .overlay(RoundedRectangle(cornerRadius: CaptureMetrics.panelCornerRadius).stroke(Color.captureSeparator, lineWidth: 1))
        .onAppear { fieldFocused = true }
        .onExitCommand { onDismiss() }
        .onChange(of: query) { highlighted = 0 }
    }

    private func runHighlighted() {
        guard filtered.indices.contains(highlighted) else { return }
        filtered[highlighted].action()
        onDismiss()
    }
}

private struct CommandRow: View {
    let item: CommandPaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(Color.captureSemantic(item.family))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(CaptureFont.body()).foregroundStyle(Color.captureTextPrimary)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHighlighted ? Color.captureAccent.opacity(0.12) : Color.clear)
    }
}
