import AppKit
import Foundation
import SwiftUI

/// The small floating post-capture panel (Part I §28: "Quick Access
/// Overlay — recent capture with: Copy, Save, Edit, Pin, OCR, Share"). Shown
/// for a few seconds immediately after every still capture completes;
/// clicking any action (or the thumbnail itself, which opens the editor)
/// dismisses it, and it also auto-dismisses on a timer so it never
/// stubbornly blocks the screen.
@MainActor
public final class QuickAccessOverlay {
    public struct Actions {
        public var copy: () -> Void
        public var save: () -> Void
        public var edit: () -> Void
        public var pin: () -> Void
        /// OCR is not implemented anywhere in this build (no OCR module
        /// exists yet — see this module's final report) — the button is
        /// shown per spec, but `CaptureApp` wires it to a "not yet
        /// available" explanation rather than a silent no-op.
        public var ocr: () -> Void

        public init(copy: @escaping () -> Void, save: @escaping () -> Void, edit: @escaping () -> Void, pin: @escaping () -> Void, ocr: @escaping () -> Void) {
            self.copy = copy
            self.save = save
            self.edit = edit
            self.pin = pin
            self.ocr = ocr
        }
    }

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var currentThumbnail: NSImage?

    public init() {}

    public func present(thumbnail: NSImage, near screenPoint: NSPoint? = nil, actions: Actions, autoDismissAfter seconds: TimeInterval = 8) {
        dismiss()
        currentThumbnail = thumbnail

        let content = QuickAccessView(thumbnail: thumbnail, actions: actionsWithDismiss(actions), onShare: { [weak self] anchorView in
            self?.presentSharingPicker(from: anchorView)
        })
        let hosting = NSHostingView(rootView: content)
        let size = NSSize(width: 240, height: 180)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let targetOrigin = screenPoint ?? Self.defaultOrigin(size: size)
        panel.setFrameOrigin(targetOrigin)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    public func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func actionsWithDismiss(_ actions: Actions) -> Actions {
        Actions(
            copy: { [weak self] in actions.copy(); self?.dismiss() },
            save: { [weak self] in actions.save(); self?.dismiss() },
            edit: { [weak self] in actions.edit(); self?.dismiss() },
            pin: { [weak self] in actions.pin() }, // pin stays open — pinning shouldn't dismiss the overlay it lives in
            ocr: { [weak self] in actions.ocr(); self?.dismiss() }
        )
    }

    private static func defaultOrigin(size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let margin: CGFloat = 20
        return NSPoint(x: screen.visibleFrame.maxX - size.width - margin, y: screen.visibleFrame.minY + margin)
    }

    /// Native macOS share sheet, anchored to the overlay panel itself — a
    /// plain AppKit `NSSharingServicePicker` rather than SwiftUI's
    /// `ShareLink` (which needs a `Transferable` conformance `Image` alone
    /// doesn't provide) so this "just works" against an arbitrary `NSImage`.
    private func presentSharingPicker(from anchorView: NSView) {
        guard let image = currentThumbnail else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }
}

private struct QuickAccessView: View {
    let thumbnail: NSImage
    let actions: QuickAccessOverlay.Actions
    let onShare: (NSView) -> Void
    @State private var isPinned = false

    var body: some View {
        VStack(spacing: 10) {
            Button(action: actions.edit) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: CaptureMetrics.controlCornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: CaptureMetrics.controlCornerRadius).stroke(Color.captureSeparator, lineWidth: 1))
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                actionButton("doc.on.doc", "Copy", .capture, actions.copy)
                actionButton("square.and.arrow.down", "Save", .capture, actions.save)
                actionButton("pencil", "Edit", .capture, actions.edit)
                actionButton(isPinned ? "pin.fill" : "pin", "Pin", .verified) {
                    isPinned.toggle()
                    actions.pin()
                }
                actionButton("text.viewfinder", "OCR", .measure, actions.ocr)
                ShareAnchorButton(onShare: onShare)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: CaptureMetrics.panelCornerRadius).fill(Color.captureElevatedBackground))
        .overlay(RoundedRectangle(cornerRadius: CaptureMetrics.panelCornerRadius).stroke(Color.captureSeparator, lineWidth: 1))
        .frame(width: 232)
    }

    private func actionButton(_ symbol: String, _ label: String, _ family: CaptureSemanticColor.Family, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(label).font(CaptureFont.caption())
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.captureSemantic(family))
    }
}

/// A real `NSButton` bridged into SwiftUI purely so `presentSharingPicker`
/// has a concrete `NSView` to anchor `NSSharingServicePicker` to — SwiftUI
/// has no API of its own for presenting an `NSSharingServicePicker`.
private struct ShareAnchorButton: NSViewRepresentable {
    let onShare: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.tapped))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.contentTintColor = CaptureSemanticColor.color(for: .inspect)
        button.toolTip = "Share"
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onShare: onShare) }

    final class Coordinator: NSObject {
        let onShare: (NSView) -> Void
        weak var button: NSButton?
        init(onShare: @escaping (NSView) -> Void) { self.onShare = onShare }
        @objc func tapped() {
            guard let button else { return }
            onShare(button)
        }
    }
}
