import Combine
import Foundation

/// Deterministic LRU ownership for expensive per-scope sessions. Capacity is
/// soft: callers decide whether a candidate is safe to evict, so active work
/// is never interrupted merely to satisfy a memory target.
struct BoundedSessionRegistry<Key: Hashable, Session: AnyObject> {
    private(set) var sessions: [Key: Session] = [:]
    private var accessOrdinals: [Key: UInt64] = [:]
    private var nextAccessOrdinal: UInt64 = 1
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { sessions.count }
    var values: Dictionary<Key, Session>.Values { sessions.values }

    mutating func session(for key: Key) -> Session? {
        guard let session = sessions[key] else { return nil }
        touch(key)
        return session
    }

    mutating func insert(_ session: Session, for key: Key) {
        sessions[key] = session
        touch(key)
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Session? {
        accessOrdinals.removeValue(forKey: key)
        return sessions.removeValue(forKey: key)
    }

    func contains(_ key: Key) -> Bool {
        sessions[key] != nil
    }

    @MainActor
    mutating func evictIfNeeded(
        keeping keptKey: Key?,
        canEvict: @MainActor (Session) -> Bool,
        onEvict: @MainActor (Session) -> Void
    ) {
        let overflow = sessions.count - capacity
        guard overflow > 0 else { return }
        let victims = sessions.keys
            .filter { $0 != keptKey && sessions[$0].map(canEvict) == true }
            .sorted {
                let lhs = accessOrdinals[$0] ?? 0
                let rhs = accessOrdinals[$1] ?? 0
                if lhs != rhs { return lhs < rhs }
                return String(describing: $0) < String(describing: $1)
            }
            .prefix(overflow)
        for key in victims {
            guard let session = removeValue(forKey: key) else { continue }
            onEvict(session)
        }
    }

    private mutating func touch(_ key: Key) {
        if nextAccessOrdinal == UInt64.max {
            let orderedKeys = accessOrdinals.keys.sorted {
                let lhs = accessOrdinals[$0] ?? 0
                let rhs = accessOrdinals[$1] ?? 0
                if lhs != rhs { return lhs < rhs }
                return String(describing: $0) < String(describing: $1)
            }
            for (offset, existingKey) in orderedKeys.enumerated() {
                accessOrdinals[existingKey] = UInt64(offset + 1)
            }
            nextAccessOrdinal = UInt64(orderedKeys.count + 1)
        }
        accessOrdinals[key] = nextAccessOrdinal
        nextAccessOrdinal += 1
    }
}

@MainActor
final class ShelfBrowserSessionStore: ObservableObject {
    /// Lazily created shared (non-pinned) browser session. Creating a
    /// ShelfBrowserSession spins up a WKWebView (its own WebContent process)
    /// plus a localhost bridge listener, so we defer it until the first time a
    /// caller actually needs the shared session — users who never open the
    /// browser panel pay nothing.
    private var _sharedSession: ShelfBrowserSession?
    private var sharedSession: ShelfBrowserSession {
        if let existing = _sharedSession { return existing }
        let created = sessionFactory()
        _sharedSession = created
        return created
    }
    private var taskSessions: BoundedSessionRegistry<UUID, ShelfBrowserSession>
    /// Soft cap on live per-task WebKit sessions. Each session holds a
    /// WKWebView (its own WebContent process) plus a localhost bridge listener,
    /// so without a cap every task ever browsed in a window leaks one until the
    /// window closes. Idle, non-active sessions over this cap are torn down.
    private let sessionFactory: @MainActor () -> ShelfBrowserSession
    private let evictionEligibility: @MainActor (ShelfBrowserSession) -> Bool

    init(
        maxLiveTaskSessions: Int = 6,
        sessionFactory: @escaping @MainActor () -> ShelfBrowserSession = ShelfBrowserSession.init,
        evictionEligibility: @escaping @MainActor (ShelfBrowserSession) -> Bool = { $0.isEvictable }
    ) {
        self.taskSessions = BoundedSessionRegistry(capacity: maxLiveTaskSessions)
        self.sessionFactory = sessionFactory
        self.evictionEligibility = evictionEligibility
    }

    func session(
        for taskID: UUID?,
        pinnedToTask: Bool,
        enabledBrowserAdapters: [String],
        githubReadOnlyMode: Bool = false
    ) -> ShelfBrowserSession {
        guard pinnedToTask, let taskID else {
            sharedSession.bindToTask(taskID)
            sharedSession.setEnabledBrowserAdapters(enabledBrowserAdapters)
            sharedSession.setGitHubReadOnlyMode(githubReadOnlyMode)
            return sharedSession
        }

        if let session = taskSessions.session(for: taskID) {
            session.bindToTask(taskID)
            session.setEnabledBrowserAdapters(enabledBrowserAdapters)
            session.setGitHubReadOnlyMode(githubReadOnlyMode)
            return session
        }

        let session = sessionFactory()
        session.bindToTask(taskID)
        session.setEnabledBrowserAdapters(enabledBrowserAdapters)
        session.setGitHubReadOnlyMode(githubReadOnlyMode)
        taskSessions.insert(session, for: taskID)
        // Only sweep when the dict actually grew (new task), so the hot
        // `session(for:)` path stays cheap during view updates.
        evictIdleSessionsIfNeeded(keeping: taskID)
        return session
    }

    /// Tear down and drop the session bound to `taskID` (e.g. on task delete).
    func releaseSession(for taskID: UUID) {
        guard let session = taskSessions.removeValue(forKey: taskID) else { return }
        session.teardown()
    }

    /// Evict the least-recently-used *evictable* sessions when over the cap.
    /// Never evicts the kept/presented session or one a background agent is
    /// driving (see ShelfBrowserSession.isEvictable). If everything over the
    /// cap is busy, the cap is exceeded rather than risk interrupting work.
    private func evictIdleSessionsIfNeeded(keeping keepTaskID: UUID?) {
        taskSessions.evictIfNeeded(
            keeping: keepTaskID,
            canEvict: evictionEligibility,
            onEvict: { $0.teardown() }
        )
    }

    func promoteSharedSession(
        to taskID: UUID,
        pinnedToTask: Bool,
        isPresented: Bool,
        enabledBrowserAdapters: [String] = [],
        githubReadOnlyMode: Bool = false
    ) -> Bool {
        // Don't force-create a shared session just to inspect it: if one was
        // never made, there is no draft page to promote. Short-circuit on the
        // backing before touching the lazy accessor.
        guard pinnedToTask,
              !taskSessions.contains(taskID),
              let existingShared = _sharedSession,
              existingShared.hasDisplayablePage || existingShared.isLoading else {
            return false
        }

        existingShared.bindToTask(taskID)
        existingShared.setEnabledBrowserAdapters(enabledBrowserAdapters)
        existingShared.setGitHubReadOnlyMode(githubReadOnlyMode)
        existingShared.setPresented(isPresented)
        taskSessions.insert(existingShared, for: taskID)
        // Drop the backing so the next shared access lazily mints a fresh draft
        // rather than eagerly rebuilding a WebView the user may never reopen.
        _sharedSession = nil
        evictIdleSessionsIfNeeded(keeping: taskID)
        return true
    }

    func setPresented(
        _ isPresented: Bool,
        taskID: UUID?,
        pinnedToTask: Bool,
        enabledBrowserAdapters: [String] = [],
        githubReadOnlyMode: Bool = false
    ) {
        // Touch the backing, not the lazy accessor — hiding sessions must never
        // force-create a shared WebView that was never opened.
        _sharedSession?.setPresented(false)
        for session in taskSessions.values {
            session.setPresented(false)
        }

        // Presentation changes are a safe moment to reclaim idle, off-screen
        // sessions (isEvictable guards against tearing down agent-driven ones).
        evictIdleSessionsIfNeeded(keeping: pinnedToTask ? taskID : nil)

        guard isPresented else { return }
        session(
            for: taskID,
            pinnedToTask: pinnedToTask,
            enabledBrowserAdapters: enabledBrowserAdapters,
            githubReadOnlyMode: githubReadOnlyMode
        ).setPresented(true)
    }

    var taskSessionCountForTesting: Int { taskSessions.count }

    func hasTaskSessionForTesting(_ taskID: UUID) -> Bool {
        taskSessions.contains(taskID)
    }
}

@MainActor
final class ShelfMarkdownSessionStore: ObservableObject {
    private let unscopedSession = ShelfMarkdownSession()
    private var workspaceSessions: [UUID: ShelfMarkdownSession] = [:]
    private var taskSessions: [UUID: ShelfMarkdownSession] = [:]

    func session(
        for taskID: UUID?,
        workspaceID: UUID?,
        pinnedToTask: Bool
    ) -> ShelfMarkdownSession {
        guard pinnedToTask, let taskID else {
            guard let workspaceID else {
                unscopedSession.bindToTask(taskID)
                return unscopedSession
            }

            if let session = workspaceSessions[workspaceID] {
                session.bindToTask(taskID)
                return session
            }

            let session = ShelfMarkdownSession()
            session.bindToTask(taskID)
            workspaceSessions[workspaceID] = session
            return session
        }

        if let session = taskSessions[taskID] {
            session.bindToTask(taskID)
            return session
        }

        let session = ShelfMarkdownSession()
        session.bindToTask(taskID)
        taskSessions[taskID] = session
        return session
    }

    /// Drop the markdown session bound to `taskID` (e.g. on task delete).
    /// These are plain value-backed sessions with no WebKit/bridge resources,
    /// so removing the reference is sufficient.
    func releaseSession(for taskID: UUID) {
        taskSessions.removeValue(forKey: taskID)
    }

    func releaseSession(forWorkspaceID workspaceID: UUID) {
        workspaceSessions.removeValue(forKey: workspaceID)
    }

    var taskSessionCountForTesting: Int { taskSessions.count }
    var workspaceSessionCountForTesting: Int { workspaceSessions.count }
}
