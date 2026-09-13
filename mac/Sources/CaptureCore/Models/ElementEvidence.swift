import Foundation

/// Mirrors `schemas/project/element-evidence.schema.json`. Keep both in sync
/// — this is the flagship DOM-anchored evidence object (Part I §7).
/// Deliberately does **not** persist a full DOM dump; only what recapture/
/// comparison/handoff needs.
public struct ElementEvidence: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var url: String
    public var title: String?
    public var viewport: Viewport
    public var locator: Locator
    public var rect: CaptureRect
    public var boxModel: BoxModel?
    public var typography: Typography?
    public var appearance: Appearance?
    public var layout: Layout?
    public var accessibility: Accessibility?
    /// Custom-property name -> resolved value, only for properties this
    /// element's computed styles actually used.
    public var cssVariables: [String: String]?
    public var authoredSources: [AuthoredSource]?
    public var pageState: PageState?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        url: String,
        title: String? = nil,
        viewport: Viewport,
        locator: Locator,
        rect: CaptureRect,
        boxModel: BoxModel? = nil,
        typography: Typography? = nil,
        appearance: Appearance? = nil,
        layout: Layout? = nil,
        accessibility: Accessibility? = nil,
        cssVariables: [String: String]? = nil,
        authoredSources: [AuthoredSource]? = nil,
        pageState: PageState? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.url = url
        self.title = title
        self.viewport = viewport
        self.locator = locator
        self.rect = rect
        self.boxModel = boxModel
        self.typography = typography
        self.appearance = appearance
        self.layout = layout
        self.accessibility = accessibility
        self.cssVariables = cssVariables
        self.authoredSources = authoredSources
        self.pageState = pageState
    }

    public struct Viewport: Codable, Hashable, Sendable {
        public var width: Double
        public var height: Double
        public var devicePixelRatio: Double
        public var scrollX: Double
        public var scrollY: Double

        public init(width: Double, height: Double, devicePixelRatio: Double, scrollX: Double, scrollY: Double) {
            self.width = width
            self.height = height
            self.devicePixelRatio = devicePixelRatio
            self.scrollX = scrollX
            self.scrollY = scrollY
        }
    }

    /// Ranked locator candidates. Priority order on re-resolution:
    /// data-* id > stable unique id > role+accessibleName > semantic
    /// attributes > class/structure > text fingerprint > ancestry
    /// fingerprint > absolute DOM path (last resort). Actual DOM
    /// resolution happens in the extension content script (JS DOM APIs
    /// aren't available natively); this type only carries the ranked data
    /// and the resolved confidence score computed there.
    public struct Locator: Hashable, Sendable {
        public var primary: String
        public var candidates: [Candidate]
        public var role: String?
        public var accessibleName: String?
        public var textFingerprint: String?
        public var ancestryFingerprint: [String]

        public init(
            primary: String,
            candidates: [Candidate] = [],
            role: String? = nil,
            accessibleName: String? = nil,
            textFingerprint: String? = nil,
            ancestryFingerprint: [String] = []
        ) {
            self.primary = primary
            self.candidates = candidates
            self.role = role
            self.accessibleName = accessibleName
            self.textFingerprint = textFingerprint
            self.ancestryFingerprint = ancestryFingerprint
        }

        public struct Candidate: Codable, Hashable, Sendable {
            public enum Strategy: String, Codable, Sendable, CaseIterable {
                case dataAttribute = "data-attribute"
                case stableId = "stable-id"
                case roleAccessibleName = "role-accessible-name"
                case semanticAttribute = "semantic-attribute"
                case classStructure = "class-structure"
                case textFingerprint = "text-fingerprint"
                case ancestryFingerprint = "ancestry-fingerprint"
                case absolutePath = "absolute-path"

                /// Lower is preferred, matching Part I §8's priority order.
                public var priority: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
            }

            public var strategy: Strategy
            public var value: String
            public var confidence: Double

            public init(strategy: Strategy, value: String, confidence: Double) {
                self.strategy = strategy
                self.value = value
                self.confidence = min(max(confidence, 0), 1)
            }
        }
    }

    public struct BoxModel: Codable, Hashable, Sendable {
        public var padding: EdgeInsets?
        public var border: EdgeInsets?
        public var margin: EdgeInsets?
        public var contentBox: CaptureSize?
        public var gap: String?
        public var display: String?
        public var position: String?

        public init(padding: EdgeInsets? = nil, border: EdgeInsets? = nil, margin: EdgeInsets? = nil, contentBox: CaptureSize? = nil, gap: String? = nil, display: String? = nil, position: String? = nil) {
            self.padding = padding; self.border = border; self.margin = margin
            self.contentBox = contentBox; self.gap = gap; self.display = display; self.position = position
        }
    }

    public struct Typography: Hashable, Sendable {
        public var fontFamilyAuthored: String?
        public var fontFamilyRendered: String?
        public var fontSizePx: Double?
        /// The schema (`element-evidence.schema.json`) allows `string |
        /// number | null` here — a browser can report either `"600"` or
        /// `600`. Stored as `String?` for a stable Swift-side API (every
        /// caller just wants to display it), but see the custom `Codable`
        /// conformance below: it accepts either JSON shape on decode
        /// (synthesized `Decodable` would reject a numeric `fontWeight` as
        /// a type mismatch — a real bug found while implementing
        /// `CaptureBrowserBridge`'s payload validation) and always encodes
        /// back out as a string.
        public var fontWeight: String?
        public var fontStyle: String?
        public var lineHeightPx: Double?
        public var letterSpacing: String?
        public var textAlign: String?
        public var textColor: String?
        public var sourceURL: String?
        public var sourceFormat: String?

        public init(fontFamilyAuthored: String? = nil, fontFamilyRendered: String? = nil, fontSizePx: Double? = nil, fontWeight: String? = nil, fontStyle: String? = nil, lineHeightPx: Double? = nil, letterSpacing: String? = nil, textAlign: String? = nil, textColor: String? = nil, sourceURL: String? = nil, sourceFormat: String? = nil) {
            self.fontFamilyAuthored = fontFamilyAuthored; self.fontFamilyRendered = fontFamilyRendered
            self.fontSizePx = fontSizePx; self.fontWeight = fontWeight; self.fontStyle = fontStyle
            self.lineHeightPx = lineHeightPx; self.letterSpacing = letterSpacing; self.textAlign = textAlign
            self.textColor = textColor; self.sourceURL = sourceURL; self.sourceFormat = sourceFormat
        }
    }

    public struct Appearance: Codable, Hashable, Sendable {
        public var backgroundColor: String?
        public var backgroundImage: String?
        public var borderRadius: String?
        public var boxShadow: String?
        public var opacity: Double?

        public init(backgroundColor: String? = nil, backgroundImage: String? = nil, borderRadius: String? = nil, boxShadow: String? = nil, opacity: Double? = nil) {
            self.backgroundColor = backgroundColor; self.backgroundImage = backgroundImage
            self.borderRadius = borderRadius; self.boxShadow = boxShadow; self.opacity = opacity
        }
    }

    public struct Layout: Codable, Hashable, Sendable {
        public var display: String?
        public var flexDirection: String?
        public var zIndex: String?
        public var overflow: String?

        public init(display: String? = nil, flexDirection: String? = nil, zIndex: String? = nil, overflow: String? = nil) {
            self.display = display; self.flexDirection = flexDirection; self.zIndex = zIndex; self.overflow = overflow
        }
    }

    public struct Accessibility: Codable, Hashable, Sendable {
        public var role: String?
        public var accessibleName: String?
        public var focusable: Bool?
        public var tabIndex: Int?
        public var ariaAttributes: [String: String]?
        public var contrastRatio: Double?

        public init(role: String? = nil, accessibleName: String? = nil, focusable: Bool? = nil, tabIndex: Int? = nil, ariaAttributes: [String: String]? = nil, contrastRatio: Double? = nil) {
            self.role = role; self.accessibleName = accessibleName; self.focusable = focusable
            self.tabIndex = tabIndex; self.ariaAttributes = ariaAttributes; self.contrastRatio = contrastRatio
        }
    }

    /// CSS provenance per inspected property. `sourceUnavailable: true`
    /// means "computed value known, source unavailable" — never fabricate
    /// a source (Part I §17).
    public struct AuthoredSource: Codable, Hashable, Sendable {
        public var property: String
        public var computedValue: String
        public var authoredDeclaration: String?
        public var selector: String?
        public var stylesheetURL: String?
        public var sourceUnavailable: Bool

        public init(property: String, computedValue: String, authoredDeclaration: String? = nil, selector: String? = nil, stylesheetURL: String? = nil, sourceUnavailable: Bool = false) {
            self.property = property; self.computedValue = computedValue
            self.authoredDeclaration = authoredDeclaration; self.selector = selector
            self.stylesheetURL = stylesheetURL; self.sourceUnavailable = sourceUnavailable
        }
    }

    public struct PageState: Codable, Hashable, Sendable {
        public var colourScheme: String?
        public var locale: String?
        public var browser: String?
        public var os: String?

        public init(colourScheme: String? = nil, locale: String? = nil, browser: String? = nil, os: String? = nil) {
            self.colourScheme = colourScheme; self.locale = locale; self.browser = browser; self.os = os
        }
    }
}

extension ElementEvidence.Locator {
    /// Best candidate available right now, ranked by strategy priority
    /// then by confidence — used when choosing what to re-resolve first.
    public var rankedCandidates: [Candidate] {
        candidates.sorted { lhs, rhs in
            if lhs.strategy.priority != rhs.strategy.priority {
                return lhs.strategy.priority < rhs.strategy.priority
            }
            return lhs.confidence > rhs.confidence
        }
    }
}

extension ElementEvidence.Locator: Codable {
    private enum CodingKeys: String, CodingKey {
        case primary, candidates, role, accessibleName, textFingerprint, ancestryFingerprint
    }

    /// Trust-boundary fix (Part I §5.6): `Locator` arrives over IPC from
    /// the untrusted content script.
    /// `schemas/project/element-evidence.schema.json` requires only
    /// `primary`+`candidates`, and doesn't even require `candidates` to be
    /// non-empty — `ancestryFingerprint` isn't required at all. Swift's
    /// *synthesized* `Decodable` would still reject any payload omitting
    /// either array key (no key -> no default for a non-Optional stored
    /// property), silently rejecting schema-valid `element.pin`/
    /// `element.resolveAnchor` messages as `INVALID_MESSAGE` — a real bug
    /// found while implementing `CaptureBrowserBridge`'s payload
    /// validation against this exact type. This custom conformance
    /// defaults both missing arrays to `[]` instead of requiring the key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try container.decode(String.self, forKey: .primary)
        candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        role = try container.decodeIfPresent(String.self, forKey: .role)
        accessibleName = try container.decodeIfPresent(String.self, forKey: .accessibleName)
        textFingerprint = try container.decodeIfPresent(String.self, forKey: .textFingerprint)
        ancestryFingerprint = try container.decodeIfPresent([String].self, forKey: .ancestryFingerprint) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(primary, forKey: .primary)
        try container.encode(candidates, forKey: .candidates)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(accessibleName, forKey: .accessibleName)
        try container.encodeIfPresent(textFingerprint, forKey: .textFingerprint)
        try container.encode(ancestryFingerprint, forKey: .ancestryFingerprint)
    }
}

extension ElementEvidence.Typography: Codable {
    private enum CodingKeys: String, CodingKey {
        case fontFamilyAuthored, fontFamilyRendered, fontSizePx, fontWeight, fontStyle
        case lineHeightPx, letterSpacing, textAlign, textColor, sourceURL, sourceFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamilyAuthored = try container.decodeIfPresent(String.self, forKey: .fontFamilyAuthored)
        fontFamilyRendered = try container.decodeIfPresent(String.self, forKey: .fontFamilyRendered)
        fontSizePx = try container.decodeIfPresent(Double.self, forKey: .fontSizePx)
        // Accept either JSON string or JSON number for fontWeight (schema:
        // string | number | null) — see the property's doc comment.
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: .fontWeight) {
            fontWeight = stringValue
        } else if let numberValue = try container.decodeIfPresent(Double.self, forKey: .fontWeight) {
            fontWeight = numberValue.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(numberValue))
                : String(numberValue)
        } else {
            fontWeight = nil
        }
        fontStyle = try container.decodeIfPresent(String.self, forKey: .fontStyle)
        lineHeightPx = try container.decodeIfPresent(Double.self, forKey: .lineHeightPx)
        letterSpacing = try container.decodeIfPresent(String.self, forKey: .letterSpacing)
        textAlign = try container.decodeIfPresent(String.self, forKey: .textAlign)
        textColor = try container.decodeIfPresent(String.self, forKey: .textColor)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        sourceFormat = try container.decodeIfPresent(String.self, forKey: .sourceFormat)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fontFamilyAuthored, forKey: .fontFamilyAuthored)
        try container.encodeIfPresent(fontFamilyRendered, forKey: .fontFamilyRendered)
        try container.encodeIfPresent(fontSizePx, forKey: .fontSizePx)
        try container.encodeIfPresent(fontWeight, forKey: .fontWeight)
        try container.encodeIfPresent(fontStyle, forKey: .fontStyle)
        try container.encodeIfPresent(lineHeightPx, forKey: .lineHeightPx)
        try container.encodeIfPresent(letterSpacing, forKey: .letterSpacing)
        try container.encodeIfPresent(textAlign, forKey: .textAlign)
        try container.encodeIfPresent(textColor, forKey: .textColor)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(sourceFormat, forKey: .sourceFormat)
    }
}
