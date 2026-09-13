import Foundation

/// Tracks the inspect-mode sessions created by `session.start` and expired
/// by `session.end` or idle timeout. This is what turns
/// `IPCErrorCode.tabSessionExpired` into real behaviour: any request that
/// references a `tabSessionId` this manager doesn't currently consider
/// active is rejected before it reaches evidence storage or anywhere else.
///
/// Deliberately pure logic — no socket, no `Foundation.Timer`, no
/// `DispatchQueue` — so it is trivially unit-testable with an injected
/// clock. Expiry is checked lazily (on lookup/touch) rather than via a
/// background timer; `purgeExpired()` is provided for callers that want a
/// periodic sweep (e.g. `BrowserBridgeService` on a timer) to actually free
/// memory for sessions nobody ever asks about again.
public final class TabSessionManager: @unchecked Sendable {
    public struct Session: Sendable, Equatable {
        public let id: UUID
        public let tabURL: String
        public let tabTitle: String?
        public let createdAt: Date
        public fileprivate(set) var lastActivityAt: Date
    }

    /// Per docs/IPC_PROTOCOL.md, the native host may reconnect and a
    /// content script's `session.start` should not stay "active" forever
    /// if the tab navigated away or Chrome quit without a clean
    /// `session.end`. 30 minutes of inactivity is a generous default for
    /// an interactive inspection session.
    public static let defaultIdleTimeout: TimeInterval = 30 * 60

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private let idleTimeout: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - idleTimeout: seconds of inactivity after which a session is
    ///     considered expired.
    ///   - now: injectable clock, for deterministic tests.
    public init(idleTimeout: TimeInterval = TabSessionManager.defaultIdleTimeout, now: @escaping @Sendable () -> Date = Date.init) {
        self.idleTimeout = idleTimeout
        self.now = now
    }

    /// Creates and stores a new session for a `session.start` request.
    @discardableResult
    public func startSession(tabURL: String, tabTitle: String?) -> Session {
        let session = Session(id: UUID(), tabURL: tabURL, tabTitle: tabTitle, createdAt: now(), lastActivityAt: now())
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
        return session
    }

    /// Drops a session immediately, e.g. on `session.end` or a clean
    /// connection close for the connection that owned it.
    public func endSession(_ id: UUID) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    /// Looks up a session, evicting and returning `nil` if it has gone
    /// idle past `idleTimeout` — the single place "expired" is decided.
    public func session(for id: UUID) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[id] else { return nil }
        if isExpired(session) {
            sessions.removeValue(forKey: id)
            return nil
        }
        return session
    }

    /// `true` iff `id` refers to a session that exists and has not gone
    /// idle. This is the check every session-scoped handler
    /// (`element.pin`, `tab.info`, ...) should perform before doing
    /// anything with `request.tabSessionId`.
    public func isActive(_ id: UUID) -> Bool {
        session(for: id) != nil
    }

    /// Refreshes `lastActivityAt` for a still-active session. Returns
    /// `false` (and does nothing) if the session is unknown or already
    /// expired, so callers can treat that the same way as any other
    /// `TAB_SESSION_EXPIRED` case.
    @discardableResult
    public func touch(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[id], !isExpired(session) else {
            sessions.removeValue(forKey: id)
            return false
        }
        var updated = session
        updated.lastActivityAt = now()
        sessions[id] = updated
        return true
    }

    /// Evicts every currently-expired session and returns their ids, for
    /// callers that want to run a periodic sweep rather than rely purely
    /// on lazy eviction at lookup time.
    @discardableResult
    public func purgeExpired() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        let expiredIds = sessions.values.filter(isExpired).map(\.id)
        for id in expiredIds { sessions.removeValue(forKey: id) }
        return expiredIds
    }

    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    private func isExpired(_ session: Session) -> Bool {
        now().timeIntervalSince(session.lastActivityAt) > idleTimeout
    }
}
