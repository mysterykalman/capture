import Foundation

/// Filename template engine (Part I §26 / Part III §18). Exact tokens from
/// the spec: `{date} {time} {domain} {pageTitle} {app} {project} {width}
/// {height} {viewport} {counter}`.
public struct FilenameTemplateContext {
    public var date: Date
    public var domain: String?
    public var pageTitle: String?
    public var app: String?
    public var project: String?
    public var width: Int?
    public var height: Int?
    public var counter: Int?

    public init(date: Date = Date(), domain: String? = nil, pageTitle: String? = nil, app: String? = nil, project: String? = nil, width: Int? = nil, height: Int? = nil, counter: Int? = nil) {
        self.date = date
        self.domain = domain
        self.pageTitle = pageTitle
        self.app = app
        self.project = project
        self.width = width
        self.height = height
        self.counter = counter
    }
}

public enum FilenameTemplate {
    public static let defaultTemplate = "{app}_{date}_{counter}"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH.mm.ss"
        return f
    }()

    /// Renders a template, replacing every `{token}` and sanitizing the
    /// result for the filesystem (no `/`, `:`, leading/trailing whitespace).
    /// Unknown or unavailable tokens are dropped (not left as literal
    /// `{token}` text) so a missing page title doesn't corrupt the name.
    public static func render(_ template: String, context: FilenameTemplateContext) -> String {
        var result = template
        let viewport: String? = {
            guard let w = context.width, let h = context.height else { return nil }
            return "\(w)x\(h)"
        }()

        let replacements: [String: String?] = [
            "{date}": dateFormatter.string(from: context.date),
            "{time}": timeFormatter.string(from: context.date),
            "{domain}": context.domain,
            "{pageTitle}": context.pageTitle.map(sanitizeComponent),
            "{app}": context.app,
            "{project}": context.project.map(sanitizeComponent),
            "{width}": context.width.map(String.init),
            "{height}": context.height.map(String.init),
            "{viewport}": viewport,
            "{counter}": context.counter.map { String(format: "%03d", $0) }
        ]

        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value ?? "")
        }

        // Collapse duplicate separators left by dropped empty tokens.
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        return result.isEmpty ? "Capture" : sanitizeComponent(result)
    }

    /// Strips characters that are invalid or awkward in a macOS filename.
    public static func sanitizeComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
