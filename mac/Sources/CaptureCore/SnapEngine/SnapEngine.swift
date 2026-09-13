import CoreGraphics
import Foundation

/// The Universal Snap Engine (Part I "Universal Snap Engine" — a
/// foundational shared subsystem, explicitly NOT to be reimplemented
/// separately per area). One instance of `SnapEngine` computes snapping for
/// capture-region dragging, crop handles, and canvas/object placement alike
/// — callers differ only in which `SnapTarget`s they supply.
public enum SnapCategory: String, Codable, Sendable, CaseIterable {
    case edges, objects, guides, grid, domElements, equalSpacing
}

/// A single snappable reference line, decomposed to one axis. A rect
/// contributes up to 3 vertical lines (left/centerX/right) and 3 horizontal
/// lines (top/centerY/bottom); a plain guide contributes exactly one line.
public struct SnapLine: Hashable, Sendable {
    public enum Axis: Sendable { case vertical, horizontal }
    public enum Alignment: Sendable { case leading, center, trailing }

    public var axis: Axis
    public var position: CGFloat
    public var alignment: Alignment
    public var category: SnapCategory
    /// Extent along the perpendicular axis, for drawing a bounded guide
    /// line rather than one spanning the whole canvas. `nil` = unbounded
    /// (screen/canvas edges).
    public var extent: ClosedRange<CGFloat>?

    public init(axis: Axis, position: CGFloat, alignment: Alignment, category: SnapCategory, extent: ClosedRange<CGFloat>? = nil) {
        self.axis = axis
        self.position = position
        self.alignment = alignment
        self.category = category
        self.extent = extent
    }
}

public struct SnapSettings: Codable, Sendable, Hashable {
    public var enabledCategories: Set<String>
    /// Snap tolerance in points before a line is considered a candidate.
    public var tolerancePoints: CGFloat
    /// Edge-detection tolerance for pixel-only visual edges (shadows,
    /// low-contrast anti-aliased boundaries) — Part I capture-region
    /// snapping requirement.
    public var visualEdgeTolerance: CGFloat

    public init(
        enabledCategories: Set<SnapCategory> = Set(SnapCategory.allCases),
        tolerancePoints: CGFloat = 8,
        visualEdgeTolerance: CGFloat = 4
    ) {
        self.enabledCategories = Set(enabledCategories.map(\.rawValue))
        self.tolerancePoints = tolerancePoints
        self.visualEdgeTolerance = visualEdgeTolerance
    }

    public static let `default` = SnapSettings()

    public func isEnabled(_ category: SnapCategory) -> Bool {
        enabledCategories.contains(category.rawValue)
    }
}

public struct SnapResult: Sendable {
    public var rect: CaptureRect
    /// Lines that were actually snapped to, for rendering magnetic guides.
    public var activeGuides: [SnapLine]

    public init(rect: CaptureRect, activeGuides: [SnapLine]) {
        self.rect = rect
        self.activeGuides = activeGuides
    }
}

public struct SnapEngine {
    public init() {}

    /// Derive the up-to-6 candidate lines a rect contributes.
    public static func lines(for rect: CaptureRect, category: SnapCategory) -> [SnapLine] {
        [
            SnapLine(axis: .vertical, position: rect.minX, alignment: .leading, category: category, extent: rect.minY...rect.maxY),
            SnapLine(axis: .vertical, position: rect.midX, alignment: .center, category: category, extent: rect.minY...rect.maxY),
            SnapLine(axis: .vertical, position: rect.maxX, alignment: .trailing, category: category, extent: rect.minY...rect.maxY),
            SnapLine(axis: .horizontal, position: rect.minY, alignment: .leading, category: category, extent: rect.minX...rect.maxX),
            SnapLine(axis: .horizontal, position: rect.midY, alignment: .center, category: category, extent: rect.minX...rect.maxX),
            SnapLine(axis: .horizontal, position: rect.maxY, alignment: .trailing, category: category, extent: rect.minX...rect.maxX)
        ]
    }

    /// Snap a moving rect's up-to-6 own edges against a pool of candidate
    /// lines (filtered by `settings`), independently on each axis, and
    /// return the adjusted rect plus which guides fired. Pass an empty
    /// `candidates` array (or all-disabled `settings`) to implement the
    /// "temporary modifier to disable snapping during a drag" requirement
    /// — the caller decides whether to call this at all while the modifier
    /// key is held.
    public func snap(moving rect: CaptureRect, candidates: [SnapLine], settings: SnapSettings) -> SnapResult {
        let enabledCandidates = candidates.filter { settings.isEnabled($0.category) }
        var result = rect
        var guides: [SnapLine] = []

        if let (dx, line) = bestOffset(axis: .vertical, rect: rect, candidates: enabledCandidates, tolerance: settings.tolerancePoints) {
            result.x += dx
            guides.append(line)
        }
        if let (dy, line) = bestOffset(axis: .horizontal, rect: rect, candidates: enabledCandidates, tolerance: settings.tolerancePoints) {
            result.y += dy
            guides.append(line)
        }
        return SnapResult(rect: result, activeGuides: guides)
    }

    /// Grid-increment snapping (Part I: "grid increments when enabled").
    public func snappedToGrid(_ rect: CaptureRect, increment: CGFloat) -> CaptureRect {
        guard increment > 0 else { return rect }
        func round(_ value: CGFloat) -> CGFloat { (value / increment).rounded() * increment }
        return CaptureRect(x: round(rect.x), y: round(rect.y), width: round(rect.width), height: round(rect.height))
    }

    /// Equal-spacing snapping: given the moving rect and a set of sibling
    /// rects already placed (e.g. assembly canvas objects), find gaps that
    /// are nearly equal to an existing gap between two other siblings and
    /// snap the moving rect's leading edge to match it exactly.
    public func equalSpacingOffset(moving rect: CaptureRect, siblings: [CaptureRect], axis: SnapLine.Axis, tolerance: CGFloat) -> CGFloat? {
        guard siblings.count >= 2 else { return nil }
        let sorted = siblings.sorted { axis == .vertical ? $0.minX < $1.minX : $0.minY < $1.minY }
        var existingGaps: [CGFloat] = []
        for i in 1..<sorted.count {
            let gap = axis == .vertical
                ? sorted[i].minX - sorted[i - 1].maxX
                : sorted[i].minY - sorted[i - 1].maxY
            if gap > 0 { existingGaps.append(gap) }
        }
        guard let referenceGap = existingGaps.first, let last = sorted.last else { return nil }
        let candidateGap = axis == .vertical ? rect.minX - last.maxX : rect.minY - last.maxY
        let delta = referenceGap - candidateGap
        return abs(delta) <= tolerance ? delta : nil
    }

    private func bestOffset(axis: SnapLine.Axis, rect: CaptureRect, candidates: [SnapLine], tolerance: CGFloat) -> (CGFloat, SnapLine)? {
        let movingLines = SnapEngine.lines(for: rect, category: .objects).filter { $0.axis == axis }
        var best: (distance: CGFloat, offset: CGFloat, line: SnapLine)?
        for movingLine in movingLines {
            for candidate in candidates where candidate.axis == axis {
                let distance = abs(candidate.position - movingLine.position)
                guard distance <= tolerance else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, candidate.position - movingLine.position, candidate)
                }
            }
        }
        return best.map { ($0.offset, $0.line) }
    }
}
