import CaptureCore
import Foundation

/// Configurable retention presets (Part I §25 / spec digest §15: "session,
/// 24 hours, 7 days, 30 days, 90 days, forever. Per-project override
/// supported."). Stored as `projects.retention_policy` (nullable — NULL
/// means "inherit the app-wide default") and as whatever `CaptureApp`
/// persists for the app-wide default (e.g. `UserDefaults`); this module
/// only defines the enum and the purge logic, not where the default lives.
public enum RetentionPolicy: String, Codable, CaseIterable, Sendable {
    /// Kept only for the current app session; eligible for purge once a
    /// *new* session starts (see `purgeExpired(sessionStartDate:)` below).
    /// There is no fixed wall-clock age for "session", so this case is
    /// handled specially rather than through `maxAge`.
    case session
    case hours24 = "24h"
    case days7 = "7d"
    case days30 = "30d"
    case days90 = "90d"
    /// Never purged by `purgeExpired`. Still deletable manually via
    /// `HistoryStore.deleteCapture`.
    case forever

    /// Age past which a capture under this policy is eligible for purge.
    /// `nil` for both `.forever` (never expires) and `.session` (its
    /// expiry isn't age-based — see the case doc comment).
    public var maxAge: TimeInterval? {
        switch self {
        case .session: return nil
        case .hours24: return 24 * 3600
        case .days7: return 7 * 24 * 3600
        case .days30: return 30 * 24 * 3600
        case .days90: return 90 * 24 * 3600
        case .forever: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .session: return "Session"
        case .hours24: return "24 Hours"
        case .days7: return "7 Days"
        case .days30: return "30 Days"
        case .days90: return "90 Days"
        case .forever: return "Forever"
        }
    }
}

extension HistoryStore {
    /// Deletes every capture whose *effective* retention policy has
    /// expired as of `now`, and returns the number of rows deleted.
    ///
    /// Effective policy resolution, per capture: the owning project's
    /// `retention_policy` override if it has one, else `defaultPolicy`.
    /// Captures with no project use `defaultPolicy` directly.
    ///
    /// This is the concrete implementation of Part I §25's "Never silently
    /// retain sensitive captures forever if user chose a shorter policy" —
    /// it is a pure, idempotent function of `(now, defaultPolicy,
    /// sessionStartDate)` and the current database contents: calling it
    /// twice in a row with the same arguments deletes nothing the second
    /// time, so it is safe to call from a recurring timer in `CaptureApp`
    /// without any external de-duplication. Actually invoking it on a
    /// schedule (and updating a "last purge ran at" timestamp, if desired)
    /// is `CaptureApp`'s responsibility, not this module's.
    ///
    /// - Parameters:
    ///   - now: Reference time; defaults to `Date()`. Overridable for
    ///     deterministic tests.
    ///   - defaultPolicy: The app-wide default retention policy, applied
    ///     to every capture whose project has no override (or which has no
    ///     project at all).
    ///   - sessionStartDate: When the *current* app session began. Passed
    ///     only when the caller wants `.session`-policy captures purged —
    ///     a capture retained under `.session` is only eligible once a
    ///     session boundary has actually passed (i.e. it predates the
    ///     current session's start), never mid-session. Pass `nil` (the
    ///     default) to leave `.session` captures untouched, e.g. for a
    ///     periodic in-session timer that should only sweep the
    ///     age-based policies.
    @discardableResult
    public func purgeExpired(
        now: Date = Date(),
        defaultPolicy: RetentionPolicy,
        sessionStartDate: Date? = nil
    ) throws -> Int {
        try connection.transaction {
            let overrides = try projectRetentionOverrides()
            var deleted = 0

            for (projectId, policy) in overrides {
                deleted += try purgeCaptures(
                    matchingPolicy: policy,
                    now: now,
                    sessionStartDate: sessionStartDate,
                    projectScope: .only(projectId)
                )
            }

            deleted += try purgeCaptures(
                matchingPolicy: defaultPolicy,
                now: now,
                sessionStartDate: sessionStartDate,
                projectScope: .excluding(Set(overrides.keys))
            )

            return deleted
        }
    }

    /// Which captures a single `purgeCaptures` pass should consider, in
    /// terms of `captures.project_id`.
    fileprivate enum ProjectScope {
        /// Only captures belonging to this exact project (used for a
        /// project that has its own retention override).
        case only(UUID)
        /// Captures with no project, or whose project id is not in this
        /// set (used for the app-wide default policy pass, so it doesn't
        /// re-sweep projects already handled by their own override).
        case excluding(Set<UUID>)
    }

    private func projectRetentionOverrides() throws -> [UUID: RetentionPolicy] {
        let rows = try connection.query(
            "SELECT id, retention_policy FROM projects WHERE retention_policy IS NOT NULL;"
        ) { statement -> (UUID, RetentionPolicy)? in
            guard
                let id = UUID(uuidString: statement.text(0)),
                let policy = RetentionPolicy(rawValue: statement.text(1))
            else { return nil }
            return (id, policy)
        }
        var result: [UUID: RetentionPolicy] = [:]
        for case let pair? in rows { result[pair.0] = pair.1 }
        return result
    }

    private func purgeCaptures(
        matchingPolicy policy: RetentionPolicy,
        now: Date,
        sessionStartDate: Date?,
        projectScope: ProjectScope
    ) throws -> Int {
        // "forever" never expires — explicitly short-circuit rather than
        // relying on an always-false WHERE clause, so this reads as the
        // hard guarantee it is.
        guard policy != .forever else { return 0 }

        var whereClauses: [String] = []
        var params: [SQLiteConnection.Value] = []

        switch projectScope {
        case .only(let projectId):
            whereClauses.append("project_id = ?")
            params.append(.text(projectId.uuidString))
        case .excluding(let projectIds):
            if !projectIds.isEmpty {
                let placeholders = projectIds.map { _ in "?" }.joined(separator: ", ")
                whereClauses.append("(project_id IS NULL OR project_id NOT IN (\(placeholders)))")
                params.append(contentsOf: projectIds.map { .text($0.uuidString) })
            }
        }

        switch policy {
        case .session:
            guard let sessionStartDate else { return 0 }
            whereClauses.append("capture_date < ?")
            params.append(.real(sessionStartDate.timeIntervalSince1970))
        case .forever:
            return 0
        default:
            guard let maxAge = policy.maxAge else { return 0 }
            let cutoff = now.addingTimeInterval(-maxAge)
            whereClauses.append("capture_date < ?")
            params.append(.real(cutoff.timeIntervalSince1970))
        }

        // Safety net: never issue an unconstrained DELETE. Every branch
        // above should always add at least the age clause, but if a
        // future edit removes that, fail closed instead of wiping history.
        guard !whereClauses.isEmpty else { return 0 }

        let sql = "SELECT id FROM captures WHERE \(whereClauses.joined(separator: " AND "));"
        let ids = try connection.query(sql, params: params) { $0.text(0) }

        for idString in ids {
            try connection.execute("DELETE FROM captures_fts WHERE capture_id = ?;", params: [.text(idString)])
            try connection.execute("DELETE FROM captures WHERE id = ?;", params: [.text(idString)])
        }
        return ids.count
    }
}
