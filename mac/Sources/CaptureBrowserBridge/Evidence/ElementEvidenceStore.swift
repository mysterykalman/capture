import CaptureCore
import Foundation

enum ElementEvidenceStoreError: Error, Sendable {
    /// Thrown by `awaitNextEvidence` if no `element.evidence` arrives for
    /// the tab session before the timeout — e.g. the extension acked
    /// `element.captureRequest` but the element had since been removed
    /// from the page and it never actually sent a follow-up.
    case timedOut
    /// Thrown to any still-pending waiter if the tab session ends or the
    /// store is torn down while a capture is outstanding.
    case cancelled
}

/// Holds the most recent `ElementEvidence` reported for each active tab
/// session. This is the in-memory "current inspection session" store: the
/// `element.pin` and `element.evidence` handlers write into it, and
/// `BrowserBridgeService.latestEvidence(forTabSession:)` is how
/// `CaptureInspection`/`CaptureUI` read it back out — the join between
/// "user pinned/recaptured an element in the browser" and "the Mac app
/// turns that into a capture + a DOM-anchored annotation".
///
/// Plain in-memory state, deliberately not persisted here: once the user
/// commits to capturing/annotating, the evidence that matters gets copied
/// into the `.capture` project (`Annotation.Anchor.elementEvidenceId` /
/// `browser/elements.json`) by `CaptureEditor`/`CaptureCore`, which is the
/// durable home for it. This store only needs to answer "what's the latest
/// evidence for this tab right now".
public final class ElementEvidenceStore: @unchecked Sendable {
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<ElementEvidence, Error>
    }

    private let lock = NSLock()
    private var latestByTabSession: [UUID: ElementEvidence] = [:]
    private var waitersByTabSession: [UUID: [Waiter]] = [:]

    public init() {}

    /// Records `evidence` as the latest for `tabSessionId`, and resolves
    /// every outstanding `awaitNextEvidence` call for that tab session
    /// (there is normally at most one — a concurrent second
    /// `element.captureRequest` for the same tab is unusual but not
    /// unsafe: every waiter gets the same fresh evidence).
    public func store(_ evidence: ElementEvidence, forTabSession tabSessionId: UUID) {
        lock.lock()
        latestByTabSession[tabSessionId] = evidence
        let waiters = waitersByTabSession.removeValue(forKey: tabSessionId) ?? []
        lock.unlock()
        for waiter in waiters { waiter.continuation.resume(returning: evidence) }
    }

    public func latestEvidence(forTabSession tabSessionId: UUID) -> ElementEvidence? {
        lock.lock()
        defer { lock.unlock() }
        return latestByTabSession[tabSessionId]
    }

    /// Drops stored evidence and fails any outstanding waiters — call this
    /// when a tab session ends.
    public func clear(forTabSession tabSessionId: UUID) {
        lock.lock()
        latestByTabSession.removeValue(forKey: tabSessionId)
        let waiters = waitersByTabSession.removeValue(forKey: tabSessionId) ?? []
        lock.unlock()
        for waiter in waiters { waiter.continuation.resume(throwing: ElementEvidenceStoreError.cancelled) }
    }

    /// Awaits the next `element.evidence` message for `tabSessionId`.
    ///
    /// This exists because `element.captureRequest`'s reply is *not* the
    /// generic envelope response correlated by request id — per
    /// docs/IPC_PROTOCOL.md's message catalogue, the extension answers it
    /// with an independent, later `element.evidence` request. So
    /// `BrowserBridgeService.requestElementCapture` sends the
    /// `captureRequest`, then awaits this instead of an envelope response.
    ///
    /// Uses a token rather than the tab session id alone as the removal
    /// key so a timeout firing after the real evidence already arrived
    /// (and already removed/resumed this waiter) is a safe no-op instead
    /// of a double-resume.
    public func awaitNextEvidence(forTabSession tabSessionId: UUID, timeout: TimeInterval = 10) async throws -> ElementEvidence {
        let token = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ElementEvidence, Error>) in
            lock.lock()
            waitersByTabSession[tabSessionId, default: []].append(Waiter(token: token, continuation: continuation))
            lock.unlock()

            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                self?.failWaiter(token: token, tabSessionId: tabSessionId, error: ElementEvidenceStoreError.timedOut)
            }
        }
    }

    private func failWaiter(token: UUID, tabSessionId: UUID, error: Error) {
        lock.lock()
        guard var waiters = waitersByTabSession[tabSessionId],
              let index = waiters.firstIndex(where: { $0.token == token }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            waitersByTabSession.removeValue(forKey: tabSessionId)
        } else {
            waitersByTabSession[tabSessionId] = waiters
        }
        lock.unlock()
        waiter.continuation.resume(throwing: error)
    }
}
