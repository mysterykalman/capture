import AppKit
import CaptureCore
import Foundation

/// Compact tool-switching toolbar (Part I §28: "central canvas with compact
/// toolbar" — "do not put every possible tool in permanent toolbar"). Shows
/// only the Phase 1/2 annotation tools plus Crop/Undo/Redo/Copy/Save; the
/// Command Palette is where every less-common command lives instead.
public final class EditorToolbarView: NSView {
    public var onSelectTool: ((Annotation.Kind?) -> Void)?
    public var onCrop: (() -> Void)?
    public var onUndo: (() -> Void)?
    public var onRedo: (() -> Void)?
    public var onCopy: (() -> Void)?
    public var onSave: (() -> Void)?

    private var toolButtons: [NSButton] = []
    private(set) var selectedTool: Annotation.Kind?

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CaptureTheme.panelBackground.cgColor
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layout() {
        super.layout()
        layer?.backgroundColor = CaptureTheme.panelBackground.cgColor
    }

    private struct Tool { let kind: Annotation.Kind?; let symbol: String; let label: String; let family: CaptureSemanticColor.Family }
    private static let tools: [Tool] = [
        Tool(kind: nil, symbol: "cursorarrow", label: "Select", family: .neutral),
        Tool(kind: .arrow, symbol: "arrow.up.right", label: "Arrow", family: .capture),
        Tool(kind: .rectangle, symbol: "rectangle", label: "Rectangle", family: .capture),
        Tool(kind: .ellipse, symbol: "circle", label: "Ellipse", family: .capture),
        Tool(kind: .text, symbol: "textformat", label: "Text", family: .capture),
        Tool(kind: .freehand, symbol: "scribble", label: "Freehand", family: .capture),
        Tool(kind: .highlighter, symbol: "highlighter", label: "Highlight", family: .accessibility),
        Tool(kind: .counter, symbol: "1.circle", label: "Counter", family: .capture),
        Tool(kind: .redact, symbol: "eye.slash", label: "Redact", family: .privacy)
    ]

    private func buildContent() {
        let toolStack = NSStackView()
        toolStack.orientation = .horizontal
        toolStack.spacing = 2
        toolStack.translatesAutoresizingMaskIntoConstraints = false

        for tool in Self.tools {
            let button = makeButton(symbol: tool.symbol, tooltip: tool.label, family: tool.family, isToggle: true)
            button.tag = Self.tools.firstIndex { $0.kind == tool.kind } ?? 0
            button.target = self
            button.action = #selector(toolButtonTapped(_:))
            toolButtons.append(button)
            toolStack.addArrangedSubview(button)
        }
        toolButtons.first?.state = .on

        let cropButton = makeButton(symbol: "crop", tooltip: "Crop", family: .neutral, isToggle: false)
        cropButton.target = self
        cropButton.action = #selector(cropTapped)

        let undoButton = makeButton(symbol: "arrow.uturn.backward", tooltip: "Undo", family: .neutral, isToggle: false)
        undoButton.target = self
        undoButton.action = #selector(undoTapped)

        let redoButton = makeButton(symbol: "arrow.uturn.forward", tooltip: "Redo", family: .neutral, isToggle: false)
        redoButton.target = self
        redoButton.action = #selector(redoTapped)

        let copyButton = makeButton(symbol: "doc.on.doc", tooltip: "Copy", family: .neutral, isToggle: false)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)

        let saveButton = makeButton(symbol: "square.and.arrow.down", tooltip: "Save Project", family: .neutral, isToggle: false)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        let trailingStack = NSStackView(views: [cropButton, undoButton, redoButton, copyButton, saveButton])
        trailingStack.orientation = .horizontal
        trailingStack.spacing = 2
        trailingStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toolStack)
        addSubview(trailingStack)
        NSLayoutConstraint.activate([
            toolStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CaptureMetrics.contentPadding),
            toolStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CaptureMetrics.contentPadding),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: CaptureMetrics.toolbarHeight)
        ])
    }

    private func makeButton(symbol: String, tooltip: String, family: CaptureSemanticColor.Family, isToggle: Bool) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.setButtonType(isToggle ? .pushOnPushOff : .momentaryPushIn)
        button.toolTip = tooltip
        button.contentTintColor = CaptureSemanticColor.color(for: family)
        button.setAccessibilityLabel(tooltip)
        return button
    }

    @objc private func toolButtonTapped(_ sender: NSButton) {
        for (index, button) in toolButtons.enumerated() {
            button.state = (index == sender.tag) ? .on : .off
        }
        let kind = Self.tools[sender.tag].kind
        selectedTool = kind
        onSelectTool?(kind)
    }

    @objc private func cropTapped() { onCrop?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
}
