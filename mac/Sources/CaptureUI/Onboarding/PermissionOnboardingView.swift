import AppKit
import SwiftUI

/// First-launch onboarding (Part I §30 / `docs/PERMISSIONS.md`'s progressive
/// permission model: "ask for nothing until the specific feature that needs
/// it is actually invoked"). This screen's only job is to *explain* — it
/// never itself requests a system permission; each permission is requested
/// later, lazily, by the module that actually needs it
/// (`CaptureCapture.ScreenCaptureEngine.requestScreenRecordingPermission()`,
/// `GlobalShortcutManager.requestInputMonitoringAccess()`, the
/// Accessibility-gated bookmarks-bar detector) the first time its feature
/// fires.
public struct PermissionOnboardingView: View {
    public var onContinue: () -> Void

    public init(onContinue: @escaping () -> Void) { self.onContinue = onContinue }

    private struct PermissionExplainer: Identifiable {
        let id = UUID()
        let symbol: String
        let family: CaptureSemanticColor.Family
        let title: String
        let whenAsked: String
        let whyItMatters: String
    }

    private static let permissions: [PermissionExplainer] = [
        PermissionExplainer(
            symbol: "rectangle.dashed.badge.record", family: .capture,
            title: "Screen Recording",
            whenAsked: "Asked the first time you take a capture — area, window, or full screen.",
            whyItMatters: "macOS requires this to read screen pixels at all. Without it, Capture cannot take a screenshot — the request appears only once, right when you press your first capture shortcut."
        ),
        PermissionExplainer(
            symbol: "hand.raised", family: .privacy,
            title: "Accessibility",
            whenAsked: "Asked only if the browser bookmarks-bar privacy detector needs the most precise Tier 1 method for your browser.",
            whyItMatters: "Lets Capture find a Chromium-family browser's bookmarks bar precisely, so it can be blurred automatically. If declined, Capture falls back to extension-reported geometry — bookmarks-bar protection still works, just with a different detection method."
        ),
        PermissionExplainer(
            symbol: "keyboard", family: .measure,
            title: "Input Monitoring",
            whenAsked: "Asked once, right after onboarding, before your first global shortcut is armed.",
            whyItMatters: "Global custom shortcuts (e.g. a capture-area key that works even when another app is frontmost) need this on macOS — there's no narrower permission for a system-wide keyboard shortcut. If declined, shortcuts won't fire; Capture still works fully from the menu bar and Command Palette, and shows a persistent reminder rather than leaving you wondering why a shortcut does nothing."
        )
    ]

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "viewfinder.rectangular")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.captureAccent)
                Text("Welcome to Capture")
                    .font(CaptureFont.title(22))
                Text("Capture asks for system permissions only when a feature that actually needs them is used — never all at once at launch.")
                    .font(CaptureFont.body())
                    .foregroundStyle(Color.captureTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            VStack(spacing: 14) {
                ForEach(Self.permissions) { permission in
                    PermissionCard(permission: permission)
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 20)

            Button("Get Started", action: onContinue)
                .buttonStyle(.borderedProminent)
                .tint(.captureAccent)
                .controlSize(.large)
                .padding(.bottom, 28)
        }
        .frame(width: 520, height: 620)
        .background(Color.captureCanvasBackground)
    }

    private struct PermissionCard: View {
        let permission: PermissionExplainer

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Color.captureSemantic(permission.family).opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: permission.symbol).foregroundStyle(Color.captureSemantic(permission.family))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(permission.title).font(CaptureFont.headline())
                    Text(permission.whenAsked).font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                    Text(permission.whyItMatters).font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: CaptureMetrics.panelCornerRadius).fill(Color.capturePanelBackground))
        }
    }
}

@MainActor
public final class OnboardingWindowController: NSWindowController {
    public init(onContinue: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PermissionOnboardingView(onContinue: onContinue))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
