import CaptureCore
import CaptureEditor
import CaptureInspection
import SwiftUI

/// Snapshot of document-level state the "nothing selected" inspector page
/// shows (Part I §28 inspector hierarchy: "nothing selected -> document/
/// export settings").
public struct EditorDocumentInfo: Equatable {
    public var canvasSize: CaptureSize
    public var cropRect: CaptureRect
    public var sourceSize: CaptureSize
    public var annotationCount: Int
    public var isDirty: Bool

    public init(canvasSize: CaptureSize, cropRect: CaptureRect, sourceSize: CaptureSize, annotationCount: Int, isDirty: Bool) {
        self.canvasSize = canvasSize
        self.cropRect = cropRect
        self.sourceSize = sourceSize
        self.annotationCount = annotationCount
        self.isDirty = isDirty
    }
}

/// What the contextual right-side inspector currently shows, per Part I
/// §28's "Inspector hierarchy". `.domEvidence` carries
/// `CaptureInspection.ForensicsCardContent` — already-summarized evidence,
/// so this view never needs to know about `CaptureBrowserBridge` (which
/// `CaptureUI` cannot import; see this module's final report) — `CaptureApp`
/// resolves the live evidence and hands over just the summarized card.
public enum EditorInspectorSelection {
    case none
    case annotation(Annotation)
    case domEvidence(ForensicsCardContent)
}

/// The contextual right-side inspector panel, hosted via `NSHostingView` in
/// `EditorWindowController`.
public struct EditorInspectorView: View {
    public var selection: EditorInspectorSelection
    public var documentInfo: EditorDocumentInfo
    /// Folded into `AnnotationInspector`'s SwiftUI identity alongside the
    /// selected annotation's id — see `EditorWindowController.
    /// inspectorRefreshGeneration`'s doc comment for why this exists (it
    /// forces the inspector's local `@State` to reload after an undo/redo
    /// changes the selected annotation's style out from under it, without
    /// resetting that state on every ordinary keystroke/slider-drag edit).
    public var refreshToken: Int
    public var onStyleChange: (Annotation) -> Void
    public var onDelete: (UUID) -> Void
    public var onExport: () -> Void
    public var onCopy: () -> Void

    public init(
        selection: EditorInspectorSelection,
        documentInfo: EditorDocumentInfo,
        refreshToken: Int = 0,
        onStyleChange: @escaping (Annotation) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onExport: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) {
        self.selection = selection
        self.documentInfo = documentInfo
        self.refreshToken = refreshToken
        self.onStyleChange = onStyleChange
        self.onDelete = onDelete
        self.onExport = onExport
        self.onCopy = onCopy
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selection {
                case .none:
                    documentSection
                case .annotation(let annotation):
                    AnnotationInspector(annotation: annotation, onChange: onStyleChange, onDelete: onDelete)
                        .id("\(annotation.id)-\(refreshToken)")
                case .domEvidence(let card):
                    forensicsSection(card)
                }
            }
            .padding(CaptureMetrics.contentPadding)
        }
        .background(Color.capturePanelBackground)
        .frame(minWidth: CaptureMetrics.inspectorWidth, maxWidth: CaptureMetrics.inspectorWidth)
    }

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Document", family: .neutral)
            infoRow("Canvas", "\(Int(documentInfo.canvasSize.width)) × \(Int(documentInfo.canvasSize.height)) px")
            infoRow("Crop", "\(Int(documentInfo.cropRect.width)) × \(Int(documentInfo.cropRect.height)) px")
            infoRow("Source", "\(Int(documentInfo.sourceSize.width)) × \(Int(documentInfo.sourceSize.height)) px")
            infoRow("Annotations", "\(documentInfo.annotationCount)")
            infoRow("Status", documentInfo.isDirty ? "Unsaved changes" : "Saved")

            Divider().background(Color.captureSeparator)
            sectionHeader("Export", family: .neutral)
            HStack(spacing: 8) {
                Button("Copy", action: onCopy)
                    .buttonStyle(.bordered)
                Button("Export…", action: onExport)
                    .buttonStyle(.borderedProminent)
                    .tint(.captureAccent)
            }
        }
    }

    private func forensicsSection(_ card: ForensicsCardContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Design Forensics", family: .inspect)
            Text(card.selector)
                .font(CaptureFont.monospacedLabel())
                .foregroundStyle(Color.captureViolet)
                .lineLimit(2)
            if let dims = card.dimensionsLabel { infoRow("Size", dims) }
            if let font = card.fontFamily { infoRow("Font", font) }
            if let sizeWeight = card.fontSizeAndWeightLabel { infoRow("Size / Weight", sizeWeight) }
            if let lineHeight = card.lineHeightLabel { infoRow("Line height", lineHeight) }
            Divider().background(Color.captureSeparator)
            if let text = card.textColor { swatchRow("Text", hex: text) }
            if let bg = card.backgroundColor { swatchRow("Background", hex: bg) }
            if let contrast = card.contrastLabel { infoRow("Contrast", contrast) }
            Divider().background(Color.captureSeparator)
            if let padding = card.padding { infoRow("Padding", padding) }
            if let radius = card.borderRadius { infoRow("Radius", radius) }
            if let display = card.display { infoRow("Display", display) }
            if let gap = card.gap { infoRow("Gap", gap) }
        }
    }

    private func swatchRow(_ label: String, hex: String) -> some View {
        HStack {
            Text(label).font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(Self.color(hex: hex)).frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.captureSeparator, lineWidth: 1))
            Text(hex).font(CaptureFont.monospacedLabel(10))
        }
    }

    /// Parses a `"#RRGGBB"`/`rgb()`-style CSS colour string (exactly the
    /// formats `ElementEvidence.Typography.textColor`/`Appearance.
    /// backgroundColor` carry) via `CaptureInspection.ParsedColor` — reused
    /// here rather than duplicating hex-parsing logic a second time.
    static func color(hex: String) -> Color {
        guard let parsed = try? ParsedColor(cssString: hex) else { return .captureTextSecondary }
        return Color(red: parsed.red, green: parsed.green, blue: parsed.blue, opacity: parsed.alpha)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
            Spacer()
            Text(value).font(CaptureFont.body()).foregroundStyle(Color.captureTextPrimary)
        }
    }

    private func sectionHeader(_ title: String, family: CaptureSemanticColor.Family) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.captureSemantic(family)).frame(width: 8, height: 8)
            Text(title.uppercased()).font(CaptureFont.caption()).foregroundStyle(Color.captureTextSecondary)
        }
    }
}

/// Annotation-selected page. Owns a small amount of local `@State` so
/// sliders/colour pickers feel responsive; every change is immediately
/// forwarded to `onChange`, which `EditorWindowController` wires to a
/// `RestyleAnnotationCommand`/frame update through `CaptureCore.UndoStack`.
private struct AnnotationInspector: View {
    @State private var annotation: Annotation
    let onChange: (Annotation) -> Void
    let onDelete: (UUID) -> Void

    init(annotation: Annotation, onChange: @escaping (Annotation) -> Void, onDelete: @escaping (UUID) -> Void) {
        _annotation = State(initialValue: annotation)
        self.onChange = onChange
        self.onDelete = onDelete
    }

    private static let swatches = ["#4D6BFF", "#8557E8", "#FF6262", "#22C7D6", "#B9E94E", "#F4B845", "#11131A", "#FFFFFF"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Circle().fill(Color.captureSemantic(.capture)).frame(width: 8, height: 8)
                Text(annotation.type.rawValue.capitalized.uppercased())
                    .font(CaptureFont.caption())
                    .foregroundStyle(Color.captureTextSecondary)
                Spacer()
                Button(role: .destructive) { onDelete(annotation.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            if annotation.type == .text {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                    TextEditor(text: textBinding)
                        .font(CaptureFont.body())
                        .frame(height: 70)
                        .padding(6)
                        .background(Color.captureCanvasBackground)
                        .clipShape(RoundedRectangle(cornerRadius: CaptureMetrics.controlCornerRadius))
                }
            }

            if annotation.type == .redact {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Redaction style").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                    Picker("", selection: redactionModeBinding) {
                        ForEach(RedactionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Colour").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                    HStack(spacing: 6) {
                        ForEach(Self.swatches, id: \.self) { hex in
                            Button {
                                setStyle(string: hex, key: AnnotationStyleKeys.colour)
                            } label: {
                                Circle().fill(EditorInspectorView.color(hex: hex))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(Color.captureTextPrimary.opacity(currentColorHex == hex ? 0.8 : 0), lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Thickness").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                    Slider(value: thicknessBinding, in: 1...20)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Opacity").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                Slider(value: opacityBinding, in: 0.1...1)
            }
        }
        .onChange(of: annotation) { onChange(annotation) }
    }

    private var currentColorHex: String {
        if case .object(let dict)? = annotation.style, case .string(let hex)? = dict[AnnotationStyleKeys.colour] { return hex }
        return "#4D6BFF"
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                if case .object(let dict)? = annotation.typeData, case .string(let text)? = dict[AnnotationStyleKeys.text] { return text }
                return ""
            },
            set: { newValue in setTypeData(string: newValue, key: AnnotationStyleKeys.text) }
        )
    }

    private var redactionModeBinding: Binding<RedactionMode> {
        Binding(
            get: {
                if case .object(let dict)? = annotation.typeData, case .string(let raw)? = dict[AnnotationStyleKeys.redactionMode], let mode = RedactionMode(rawValue: raw) { return mode }
                return .gaussianBlur
            },
            set: { newValue in setTypeData(string: newValue.rawValue, key: AnnotationStyleKeys.redactionMode) }
        )
    }

    private var thicknessBinding: Binding<Double> {
        Binding(
            get: {
                if case .object(let dict)? = annotation.style, case .number(let value)? = dict[AnnotationStyleKeys.thickness] { return value }
                return 4
            },
            set: { newValue in setStyle(number: newValue, key: AnnotationStyleKeys.thickness) }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { annotation.opacity }, set: { annotation.opacity = $0 })
    }

    private func setStyle(string value: String, key: String) {
        var dict: [String: JSONValue]
        if case .object(let existing)? = annotation.style { dict = existing } else { dict = [:] }
        dict[key] = .string(value)
        annotation.style = .object(dict)
    }

    private func setStyle(number value: Double, key: String) {
        var dict: [String: JSONValue]
        if case .object(let existing)? = annotation.style { dict = existing } else { dict = [:] }
        dict[key] = .number(value)
        annotation.style = .object(dict)
    }

    private func setTypeData(string value: String, key: String) {
        var dict: [String: JSONValue]
        if case .object(let existing)? = annotation.typeData { dict = existing } else { dict = [:] }
        dict[key] = .string(value)
        annotation.typeData = .object(dict)
    }
}
