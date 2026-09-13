import AppKit
import CaptureCore
import CaptureEditor
import CaptureHistory
import CaptureInspection
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Per-editor-session state that has no home in `CaptureCore.ProjectManifest`
/// (crop rect / canvas size / Backdrop are `CaptureEditor.EditorDocument`
/// concepts — see this module's final report for why: the manifest schema
/// has no field for them). Persisted as a small sidecar JSON file
/// (`editor-state.json`) alongside the standard `.capture` package files
/// this pass writes through `CaptureCore.CaptureProjectDocument.save`
/// unmodified, so a reopened project's crop/canvas survive a relaunch too —
/// not just its annotations, which alone is all Part I §39's acceptance
/// scenario strictly requires ("existing annotations remain editable").
private struct EditorSessionState: Codable {
    var cropRect: CaptureRect
    var canvasSize: CaptureSize
}

/// Central editor window: canvas + compact toolbar + contextual inspector
/// (Part I §28). Owns the one `EditorDocument`/`UndoStack` pair for this
/// window and mediates every action the toolbar/inspector/menu can trigger
/// — copy to clipboard, crop, save as `.capture` project, export, and
/// (Phase 3) accepting a DOM-anchored annotation `CaptureApp` hands in from
/// the browser bridge.
@MainActor
public final class EditorWindowController: NSWindowController {
    public let editorDocument: EditorDocument
    public let undoStack = UndoStack()
    public let imageStore = EditorImageStore()
    private let canvasView: CaptureCanvasView
    private let toolbarView = EditorToolbarView()
    private let inspectorHost: NSHostingView<EditorInspectorView>
    private let exportRenderer = ExportRenderer()

    /// `ElementEvidence` values referenced by any `.domElement`-anchored
    /// annotation in this document (Phase 3) — persisted alongside
    /// annotations so `CaptureProjectDocument.browserElements` round-trips
    /// through save/reload, and so `CaptureApp` can look one back up by id
    /// (e.g. to re-resolve its anchor on reopen via
    /// `CaptureBrowserBridge.BrowserBridgeService.resolveAnchor`).
    public private(set) var browserElements: [ElementEvidence]
    private let historyStore: HistoryStore?
    /// The `HistoryStore` row this session's capture is indexed under, when
    /// known — set by `CaptureApp` right after `HistoryStore.insertCapture`
    /// so this controller can keep `annotation_text` search content fresh.
    public var historyCaptureId: UUID?
    /// Supplied by `CaptureApp` (which depends on `CapturePDF`); `CaptureUI`
    /// itself cannot import `CapturePDF` (not a declared target dependency —
    /// see this module's final report), so PDF export only works when this
    /// is injected. `nil` disables the PDF export option rather than
    /// crashing or silently producing an empty file.
    public var pdfExporter: PDFExporting?

    /// The package URL this session was loaded from or last saved to, if
    /// any — subsequent saves go straight back here without prompting.
    public private(set) var projectURL: URL?
    /// Fired after every successful `saveProject(to:)` — `CaptureApp` uses
    /// this to keep its content-addressed blob-to-project index
    /// (`ContentAddressedBlobStore`) up to date so "reopen from history"
    /// can find a previously-saved project again.
    public var onProjectSaved: ((URL) -> Void)?
    private var manifest: ProjectManifest
    private var isDirty: Bool = false {
        didSet { refreshInspector() }
    }

    private var keyMonitor: Any?
    /// Bumped only by `performUndo()`/`performRedo()` (never by ordinary
    /// restyle edits) and folded into the inspector's annotation-page
    /// SwiftUI identity (see `refreshInspector()`). SwiftUI's `AnnotationInspector`
    /// seeds its own `@State` from its `init` parameter exactly once per
    /// identity — without this, undoing a restyle would silently leave the
    /// inspector showing the pre-undo (stale) colour/thickness even though
    /// the canvas itself correctly reverted, since the annotation's `id`
    /// alone doesn't change across an undo. Excluded from ordinary
    /// slider-drag/typing edits specifically so those don't get their
    /// SwiftUI identity — and therefore in-progress gesture state — reset
    /// on every keystroke.
    private var inspectorRefreshGeneration = 0

    // MARK: - Construction

    /// Starts a brand-new editing session from a just-captured (or
    /// drag/pasted) source image — Part I §39's "3. Capture appears
    /// immediately."
    public init(sourceImage: CGImage, sourceApp: String?, historyStore: HistoryStore?, historyCaptureId: UUID?) {
        let size = CaptureSize(width: CGFloat(sourceImage.width), height: CGFloat(sourceImage.height))
        self.editorDocument = EditorDocument(sourceSize: size)
        self.browserElements = []
        self.historyStore = historyStore
        self.historyCaptureId = historyCaptureId
        self.manifest = ProjectManifest(
            kind: .screenshot,
            source: ProjectManifest.Source(relativePath: "source.png", contentHash: "", pixelWidth: Int(size.width), pixelHeight: Int(size.height)),
            captureMetadata: CaptureMetadata(sourceApp: sourceApp ?? "Capture", os: "macOS")
        )
        self.canvasView = CaptureCanvasView(document: editorDocument, imageStore: imageStore, undoStack: undoStack)
        self.inspectorHost = NSHostingView(rootView: EditorInspectorView(
            selection: .none,
            documentInfo: EditorDocumentInfo(canvasSize: size, cropRect: editorDocument.cropRect, sourceSize: size, annotationCount: 0, isDirty: false),
            refreshToken: 0,
            onStyleChange: { _ in }, onDelete: { _ in }, onExport: {}, onCopy: {}
        ))
        let window = Self.makeWindow()
        super.init(window: window)
        imageStore.setSourceImage(sourceImage)
        configure(window: window)
    }

    /// Reopens a previously-saved `.capture` project — Part I §39's
    /// "12. Reopen project. 13. Existing annotations remain editable."
    public init(loadingProjectAt url: URL, historyStore: HistoryStore?) throws {
        let projectDocument = try CaptureProjectDocument.load(from: url)
        let sourceURL = url.appendingPathComponent(projectDocument.manifest.source.relativePath)
        guard let cgImage = Self.loadCGImage(from: sourceURL) else {
            throw EditorLoadError.sourceImageUnreadable(sourceURL)
        }
        let pixelSize = CaptureSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let sessionState = Self.loadSessionState(packageURL: url)

        let document = EditorDocument(
            annotations: projectDocument.annotations,
            cropRect: sessionState?.cropRect ?? CaptureRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height),
            canvasSize: sessionState?.canvasSize ?? pixelSize,
            sourceSize: pixelSize
        )
        self.editorDocument = document
        self.browserElements = projectDocument.browserElements
        self.historyStore = historyStore
        self.historyCaptureId = nil
        self.manifest = projectDocument.manifest
        self.projectURL = url
        self.canvasView = CaptureCanvasView(document: document, imageStore: imageStore, undoStack: undoStack)
        self.inspectorHost = NSHostingView(rootView: EditorInspectorView(
            selection: .none,
            documentInfo: EditorDocumentInfo(canvasSize: document.canvasSize, cropRect: document.cropRect, sourceSize: pixelSize, annotationCount: document.annotations.count, isDirty: false),
            refreshToken: 0,
            onStyleChange: { _ in }, onDelete: { _ in }, onExport: {}, onCopy: {}
        ))
        let window = Self.makeWindow()
        super.init(window: window)
        imageStore.setSourceImage(cgImage)
        configure(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    enum EditorLoadError: Error { case sourceImageUnreadable(URL) }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Capture"
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        return window
    }

    private func configure(window: NSWindow) {
        let toolbarHost = toolbarView
        toolbarHost.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        inspectorHost.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = CaptureTheme.canvasBackground.cgColor
        container.addSubview(toolbarHost)
        container.addSubview(canvasView)
        container.addSubview(inspectorHost)

        NSLayoutConstraint.activate([
            toolbarHost.topAnchor.constraint(equalTo: container.topAnchor),
            toolbarHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            canvasView.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvasView.trailingAnchor.constraint(equalTo: inspectorHost.leadingAnchor),

            inspectorHost.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor),
            inspectorHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inspectorHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inspectorHost.widthAnchor.constraint(equalToConstant: CaptureMetrics.inspectorWidth)
        ])
        window.contentView = container

        canvasView.onSelectionChanged = { [weak self] _ in self?.refreshInspector() }
        canvasView.onDocumentChanged = { [weak self] in
            self?.isDirty = true
            self?.syncSearchableText()
        }

        toolbarView.onSelectTool = { [weak self] kind in self?.canvasView.currentTool = kind }
        toolbarView.onCrop = { [weak self] in self?.toggleOrApplyCrop() }
        toolbarView.onUndo = { [weak self] in self?.performUndo() }
        toolbarView.onRedo = { [weak self] in self?.performRedo() }
        toolbarView.onCopy = { [weak self] in self?.copyToClipboard() }
        toolbarView.onSave = { [weak self] in self?.promptSaveProject() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                if event.modifierFlags.contains(.shift) { self.performRedo() } else { self.performUndo() }
                return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
                self.copyToClipboard()
                return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
                self.promptSaveProject()
                return nil
            }
            if event.keyCode == 53, self.canvasView.isCropping { // Escape cancels crop mode
                self.canvasView.isCropping = false
                self.toolbarView.needsDisplay = true
                return nil
            }
            return event
        }

        refreshInspector()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - Inspector

    private func refreshInspector() {
        let selection: EditorInspectorSelection
        if let id = canvasView.selectedAnnotationID, let annotation = editorDocument.annotation(id) {
            selection = .annotation(annotation)
        } else {
            selection = .none
        }
        let info = EditorDocumentInfo(
            canvasSize: editorDocument.canvasSize,
            cropRect: editorDocument.cropRect,
            sourceSize: editorDocument.sourceSize,
            annotationCount: editorDocument.annotations.count,
            isDirty: isDirty
        )
        inspectorHost.rootView = EditorInspectorView(
            selection: selection,
            documentInfo: info,
            refreshToken: inspectorRefreshGeneration,
            onStyleChange: { [weak self] updated in self?.applyStyleChange(updated) },
            onDelete: { [weak self] id in self?.deleteAnnotation(id) },
            onExport: { [weak self] in self?.promptExport() },
            onCopy: { [weak self] in self?.copyToClipboard() }
        )
    }

    /// Shows a resolved DOM forensics card in the inspector (Phase 3 —
    /// `CaptureApp` calls this after resolving `CaptureBrowserBridge`
    /// evidence, since `CaptureUI` cannot depend on that module itself).
    public func showForensicsCard(_ card: ForensicsCardContent) {
        let info = EditorDocumentInfo(canvasSize: editorDocument.canvasSize, cropRect: editorDocument.cropRect, sourceSize: editorDocument.sourceSize, annotationCount: editorDocument.annotations.count, isDirty: isDirty)
        inspectorHost.rootView = EditorInspectorView(
            selection: .domEvidence(card),
            documentInfo: info,
            refreshToken: inspectorRefreshGeneration,
            onStyleChange: { [weak self] updated in self?.applyStyleChange(updated) },
            onDelete: { [weak self] id in self?.deleteAnnotation(id) },
            onExport: { [weak self] in self?.promptExport() },
            onCopy: { [weak self] in self?.copyToClipboard() }
        )
    }

    private func applyStyleChange(_ updated: Annotation) {
        guard let original = editorDocument.annotation(updated.id) else { return }
        guard original.style != updated.style || original.typeData != updated.typeData else {
            // Opacity/frame-only change (no restyle) — just write it back
            // directly; still an undoable transform for opacity.
            if let idx = editorDocument.index(ofAnnotation: updated.id) {
                editorDocument.annotations[idx].opacity = updated.opacity
                isDirty = true
            }
            return
        }
        let command = RestyleAnnotationCommand(
            document: editorDocument, annotationId: updated.id,
            beforeStyle: original.style, beforeTypeData: original.typeData,
            afterStyle: updated.style, afterTypeData: updated.typeData
        )
        undoStack.perform(command)
        if let idx = editorDocument.index(ofAnnotation: updated.id) {
            editorDocument.annotations[idx].opacity = updated.opacity
        }
        isDirty = true
        canvasView.needsDisplay = true
        syncSearchableText()
    }

    private func deleteAnnotation(_ id: UUID) {
        undoStack.perform(DeleteAnnotationCommand(document: editorDocument, annotationId: id))
        isDirty = true
        canvasView.needsDisplay = true
        refreshInspector()
    }

    private func performUndo() {
        undoStack.undo()
        isDirty = true
        inspectorRefreshGeneration += 1
        canvasView.needsDisplay = true
        refreshInspector()
    }

    private func performRedo() {
        undoStack.redo()
        isDirty = true
        inspectorRefreshGeneration += 1
        canvasView.needsDisplay = true
        refreshInspector()
    }

    // MARK: - Crop (Part I §39 step 6: "Crop.")

    private func toggleOrApplyCrop() {
        if canvasView.isCropping {
            if let pending = canvasView.pendingCropRect, pending.width > 4, pending.height > 4 {
                let before = editorDocument.cropRect
                undoStack.perform(CropChangeCommand(document: editorDocument, before: before, after: pending))
                // Canvas collapses to the new crop's own size (matching
                // `EditorDocument(sourceSize:)`'s uncropped-canvas
                // convention) so the source media fills the visible canvas
                // after a crop rather than leaving stale empty margins.
                editorDocument.canvasSize = CaptureSize(width: pending.width, height: pending.height)
                isDirty = true
            }
            canvasView.isCropping = false
        } else {
            canvasView.isCropping = true
        }
        canvasView.needsDisplay = true
    }

    // MARK: - Copy (Part I §39 step 7: "Copy image.")

    public func copyToClipboard() {
        guard let image = try? exportRenderer.renderImage(document: editorDocument, images: imageStore, options: ExportOptions(format: .png, scale: 1)) else { return }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    // MARK: - Export

    private func promptExport() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Capture.png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let format: ExportImageFormat = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? .jpeg : .png
            do {
                let data = try self.exportRenderer.exportImageData(document: self.editorDocument, images: self.imageStore, options: ExportOptions(format: format, scale: 2))
                try AtomicFileWriter.write(data, to: url)
            } catch {
                self.presentError(error)
            }
        }
    }

    // MARK: - Save as `.capture` project (Part I §39 steps 10-13)

    public func promptSaveProject() {
        if let projectURL {
            saveProject(to: projectURL)
            return
        }
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Capture.capture"
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.saveProject(to: url)
        }
    }

    public func saveProject(to url: URL) {
        do {
            let isFirstSave = projectURL != url
            let sourceData: Data?
            if isFirstSave, let sourceImage = imageStore.image(for: CanvasRenderer.sourceImageID) {
                sourceData = Self.pngData(from: sourceImage)
            } else {
                sourceData = nil
            }
            let projectDocument = CaptureProjectDocument(
                manifest: manifest,
                annotations: editorDocument.annotations,
                measurements: [],
                redactions: [],
                browserElements: browserElements
            )
            try projectDocument.save(to: url, sourceData: sourceData, sourceRelativePath: sourceData != nil ? "source.png" : nil)
            try Self.saveSessionState(EditorSessionState(cropRect: editorDocument.cropRect, canvasSize: editorDocument.canvasSize), packageURL: url)
            projectURL = url
            isDirty = false
            onProjectSaved?(url)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Phase 3: DOM-anchored annotation from the browser bridge

    /// Inserts a Counter (or other) annotation anchored to a resolved DOM
    /// element, per Part I §39's "First browser milestone" step 8: "Add a
    /// Counter annotation anchored to that DOM element." Also records
    /// `evidence` in `browserElements` (deduplicated by id) so it round
    /// -trips through `saveProject`/`browser/elements.json`, and so a later
    /// reopen can look the full evidence — including its re-resolution
    /// `Locator` — back up by `Annotation.Anchor.elementEvidenceId`.
    @discardableResult
    public func insertDOMAnchoredAnnotation(kind: Annotation.Kind, evidence: ElementEvidence, canvasRect: CaptureRect, style: JSONValue? = nil, typeData: JSONValue? = nil) -> Annotation {
        if !browserElements.contains(where: { $0.id == evidence.id }) {
            browserElements.append(evidence)
        }
        let anchor = Annotation.Anchor(
            kind: .domElement,
            elementEvidenceId: evidence.id,
            relativeAnchor: CapturePoint(x: 0.5, y: 0.5),
            fallbackPixelPosition: canvasRect.origin
        )
        let annotation = Annotation(
            type: kind,
            frame: canvasRect,
            zIndex: editorDocument.nextZIndex(forLayerOf: kind),
            style: style ?? .object([AnnotationStyleKeys.colour: .string("#4D6BFF"), AnnotationStyleKeys.thickness: .number(3)]),
            typeData: typeData,
            anchor: anchor
        )
        undoStack.perform(AddAnnotationCommand(document: editorDocument, annotation: annotation))
        isDirty = true
        canvasView.needsDisplay = true
        refreshInspector()
        return annotation
    }

    /// Looks up the full `ElementEvidence` a `.domElement`-anchored
    /// annotation refers to, for `CaptureApp` to attempt re-resolution
    /// against (Part I §39 step 10: "attempt to resolve the anchor").
    public func elementEvidence(for annotation: Annotation) -> ElementEvidence? {
        guard let id = annotation.anchor.elementEvidenceId else { return nil }
        return browserElements.first { $0.id == id }
    }

    // MARK: - History search text sync

    private func syncSearchableText() {
        guard let historyStore, let historyCaptureId else { return }
        let textAnnotations = editorDocument.annotations
            .filter { $0.type == .text }
            .compactMap { annotation -> String? in
                guard case .object(let dict)? = annotation.typeData, case .string(let text)? = dict[AnnotationStyleKeys.text] else { return nil }
                return text
            }
        let joined = textAnnotations.joined(separator: " ")
        try? historyStore.updateSearchableText(forCapture: historyCaptureId, ocrText: nil, annotationText: joined.isEmpty ? nil : joined)
    }

    // MARK: - Helpers

    private func presentError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Capture couldn't complete that action"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    private static func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    private static func sessionStateURL(packageURL: URL) -> URL { packageURL.appendingPathComponent("editor-state.json") }

    private static func loadSessionState(packageURL: URL) -> EditorSessionState? {
        guard let data = try? Data(contentsOf: sessionStateURL(packageURL: packageURL)) else { return nil }
        return try? CaptureCoreJSON.decoder.decode(EditorSessionState.self, from: data)
    }

    private static func saveSessionState(_ state: EditorSessionState, packageURL: URL) throws {
        try AtomicFileWriter.writeJSON(state, to: sessionStateURL(packageURL: packageURL))
    }
}
