import Foundation

/// Mirrors `schemas/findings/audit-finding.schema.json` (Part III §17/§24).
/// A structured evidence object — explicitly "not a Jira replacement".
public struct AuditFinding: Codable, Identifiable, Hashable, Sendable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case navigation = "Navigation", homepage = "Homepage", plp = "PLP", pdp = "PDP"
        case search = "Search", recommendations = "Recommendations", cart = "Cart"
        case checkout = "Checkout", accessibility = "Accessibility", performance = "Performance"
        case seo = "SEO", analytics = "Analytics", merchandising = "Merchandising", content = "Content"
    }

    public enum Severity: String, Codable, Sendable, CaseIterable {
        case critical = "Critical", high = "High", medium = "Medium", low = "Low", opportunity = "Opportunity"
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case open, inProgress = "in-progress", resolved, verified, wontfix, duplicate
    }

    /// Human-facing auto-numbered id, e.g. "PDP-01" — see
    /// `AuditFindingIdGenerator`, not the same as a database primary key.
    public var id: String
    public var projectId: UUID?
    public var title: String
    public var category: Category
    public var severity: Severity
    public var status: Status
    public var finding: String
    public var recommendation: String?
    public var expectedImpact: String?
    public var pageUrl: String
    public var viewport: [Double]?
    public var captureId: UUID?
    public var elementEvidenceIds: [UUID]
    public var measurementIds: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var tags: [String]

    public init(
        id: String, projectId: UUID? = nil, title: String, category: Category, severity: Severity,
        status: Status = .open, finding: String, recommendation: String? = nil, expectedImpact: String? = nil,
        pageUrl: String, viewport: [Double]? = nil, captureId: UUID? = nil,
        elementEvidenceIds: [UUID] = [], measurementIds: [String] = [],
        createdAt: Date = Date(), updatedAt: Date = Date(), tags: [String] = []
    ) {
        self.id = id; self.projectId = projectId; self.title = title; self.category = category
        self.severity = severity; self.status = status; self.finding = finding
        self.recommendation = recommendation; self.expectedImpact = expectedImpact; self.pageUrl = pageUrl
        self.viewport = viewport; self.captureId = captureId; self.elementEvidenceIds = elementEvidenceIds
        self.measurementIds = measurementIds; self.createdAt = createdAt; self.updatedAt = updatedAt; self.tags = tags
    }
}

/// Generates sequential per-category ids like `PDP-01`, `NAV-02` (Part III §17).
public struct AuditFindingIdGenerator {
    private static let categoryPrefixes: [AuditFinding.Category: String] = [
        .navigation: "NAV", .homepage: "HOME", .plp: "PLP", .pdp: "PDP", .search: "SEARCH",
        .recommendations: "REC", .cart: "CART", .checkout: "CHECKOUT", .accessibility: "A11Y",
        .performance: "PERF", .seo: "SEO", .analytics: "ANALYTICS", .merchandising: "MERCH", .content: "CONTENT"
    ]

    public init() {}

    /// `existingCount` is the number of findings already created for this
    /// category within the current project/audit; the caller (history
    /// store) is the source of truth for that count.
    public func nextId(category: AuditFinding.Category, existingCount: Int) -> String {
        let prefix = Self.categoryPrefixes[category] ?? category.rawValue.uppercased()
        let number = existingCount + 1
        return String(format: "%@-%02d", prefix, number)
    }
}
