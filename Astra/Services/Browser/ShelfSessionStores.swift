import Combine
import Foundation
import SwiftData

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
    private var taskSessions: BoundedSessionRegistry<ShelfBrowserOwner, ShelfBrowserSession>
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
        githubReadOnlyMode: Bool = false,
        taskOwnerID: PersistentIdentifier? = nil
    ) -> ShelfBrowserSession {
        let owner = taskID.map { ShelfBrowserOwner(taskID: $0, modelID: taskOwnerID) }
        guard pinnedToTask, let taskID, let owner else {
            if !sharedSession.bindToTask(taskID, ownerID: taskOwnerID) {
                sharedSession.teardown()
                _sharedSession = sessionFactory()
                sharedSession.ownershipNotice = "The previous task is finishing a browser operation. This task has a separate Browser session."
                sharedSession.bindToTask(taskID, ownerID: taskOwnerID)
            }
            selectForLaunch(sharedSession, owner: owner)
            sharedSession.setEnabledBrowserAdapters(enabledBrowserAdapters)
            sharedSession.setGitHubReadOnlyMode(githubReadOnlyMode)
            return sharedSession
        }

        if let session = taskSessions.session(for: owner) {
            session.bindToTask(taskID, ownerID: taskOwnerID)
            selectForLaunch(session, owner: owner)
            session.setEnabledBrowserAdapters(enabledBrowserAdapters)
            session.setGitHubReadOnlyMode(githubReadOnlyMode)
            return session
        }

        let session = sessionFactory()
        session.bindToTask(taskID, ownerID: taskOwnerID)
        session.setEnabledBrowserAdapters(enabledBrowserAdapters)
        session.setGitHubReadOnlyMode(githubReadOnlyMode)
        taskSessions.insert(session, for: owner)
        selectForLaunch(session, owner: owner)
        // Only sweep when the dict actually grew (new task), so the hot
        // `session(for:)` path stays cheap during view updates.
        evictIdleSessionsIfNeeded(keeping: owner)
        return session
    }

    /// Tear down and drop the session bound to `taskID` (e.g. on task delete).
    func releaseSession(for taskID: UUID, ownerID: PersistentIdentifier? = nil) {
        let owner = ShelfBrowserOwner(taskID: taskID, modelID: ownerID)
        taskSessions.removeValue(forKey: owner)?.teardown()
        if _sharedSession?.boundOwner == owner {
            _sharedSession?.teardown()
            _sharedSession = nil
        }
    }

    private func selectForLaunch(_ selected: ShelfBrowserSession, owner: ShelfBrowserOwner?) {
        for session in taskSessions.values where session.boundOwner == owner {
            session.setLaunchSelected(session === selected)
        }
        if let shared = _sharedSession, shared.boundOwner == owner {
            shared.setLaunchSelected(shared === selected)
        }
        selected.setLaunchSelected(true)
    }

    /// Evict the least-recently-used *evictable* sessions when over the cap.
    /// Never evicts the kept/presented session or one a background agent is
    /// driving (see ShelfBrowserSession.isEvictable). If everything over the
    /// cap is busy, the cap is exceeded rather than risk interrupting work.
    private func evictIdleSessionsIfNeeded(keeping keepTaskID: ShelfBrowserOwner?) {
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
        githubReadOnlyMode: Bool = false,
        taskOwnerID: PersistentIdentifier? = nil
    ) -> Bool {
        let owner = ShelfBrowserOwner(taskID: taskID, modelID: taskOwnerID)
        // Don't force-create a shared session just to inspect it: if one was
        // never made, there is no draft page to promote. Short-circuit on the
        // backing before touching the lazy accessor.
        guard pinnedToTask,
              !taskSessions.contains(owner),
              let existingShared = _sharedSession,
              existingShared.hasDisplayablePage || existingShared.isLoading else {
            return false
        }

        guard existingShared.bindToTask(taskID, ownerID: taskOwnerID) else { return false }
        existingShared.setEnabledBrowserAdapters(enabledBrowserAdapters)
        existingShared.setGitHubReadOnlyMode(githubReadOnlyMode)
        existingShared.setPresented(isPresented)
        taskSessions.insert(existingShared, for: owner)
        selectForLaunch(existingShared, owner: owner)
        // Drop the backing so the next shared access lazily mints a fresh draft
        // rather than eagerly rebuilding a WebView the user may never reopen.
        _sharedSession = nil
        evictIdleSessionsIfNeeded(keeping: owner)
        return true
    }

    func setPresented(
        _ isPresented: Bool,
        taskID: UUID?,
        pinnedToTask: Bool,
        enabledBrowserAdapters: [String] = [],
        githubReadOnlyMode: Bool = false,
        taskOwnerID: PersistentIdentifier? = nil
    ) {
        // Touch the backing, not the lazy accessor — hiding sessions must never
        // force-create a shared WebView that was never opened.
        _sharedSession?.setPresented(false)
        for session in taskSessions.values {
            session.setPresented(false)
        }

        // Presentation changes are a safe moment to reclaim idle, off-screen
        // sessions (isEvictable guards against tearing down agent-driven ones).
        evictIdleSessionsIfNeeded(keeping: pinnedToTask ? taskID.map { ShelfBrowserOwner(taskID: $0, modelID: taskOwnerID) } : nil)

        guard isPresented else { return }
        session(
            for: taskID,
            pinnedToTask: pinnedToTask,
            enabledBrowserAdapters: enabledBrowserAdapters,
            githubReadOnlyMode: githubReadOnlyMode,
            taskOwnerID: taskOwnerID
        ).setPresented(true)
    }

    var taskSessionCountForTesting: Int { taskSessions.count }

    func hasTaskSessionForTesting(_ taskID: UUID, ownerID: PersistentIdentifier? = nil) -> Bool {
        taskSessions.contains(ShelfBrowserOwner(taskID: taskID, modelID: ownerID))
    }
}

@MainActor
final class ShelfMarkdownSessionStore: ObservableObject {
    private let unscopedSession = ShelfMarkdownSession()
    private var workspaceSessions: [ShelfFilesOwner: ShelfMarkdownSession] = [:]
    private var taskSessions: [ShelfFilesOwner: ShelfMarkdownSession] = [:]

    func session(
        for taskID: UUID?,
        workspaceID: UUID?,
        pinnedToTask: Bool,
        taskOwnerID: PersistentIdentifier? = nil,
        workspaceOwnerID: PersistentIdentifier? = nil
    ) -> ShelfMarkdownSession {
        guard pinnedToTask, let taskID else {
            guard let workspaceID else {
                unscopedSession.bindToTask(taskID, ownerID: taskOwnerID)
                return unscopedSession
            }

            if let session = workspaceSessions[ShelfFilesOwner(id: workspaceID, ownerID: workspaceOwnerID)] {
                session.bindToTask(taskID, ownerID: taskOwnerID)
                return session
            }

            let session = ShelfMarkdownSession()
            session.bindToTask(taskID, ownerID: taskOwnerID)
            workspaceSessions[ShelfFilesOwner(id: workspaceID, ownerID: workspaceOwnerID)] = session
            return session
        }

        if let session = taskSessions[ShelfFilesOwner(id: taskID, ownerID: taskOwnerID)] {
            session.bindToTask(taskID, ownerID: taskOwnerID)
            return session
        }

        let session = ShelfMarkdownSession()
        session.bindToTask(taskID, ownerID: taskOwnerID)
        taskSessions[ShelfFilesOwner(id: taskID, ownerID: taskOwnerID)] = session
        return session
    }

    /// Drop the markdown session bound to `taskID` (e.g. on task delete).
    /// These are plain value-backed sessions with no WebKit/bridge resources,
    /// so removing the reference is sufficient.
    func releaseSession(for taskID: UUID, ownerID: PersistentIdentifier? = nil) {
        taskSessions.removeValue(forKey: ShelfFilesOwner(id: taskID, ownerID: ownerID))?.cancelPendingDocumentLoad()
    }

    func releaseSession(forWorkspaceID workspaceID: UUID, ownerID: PersistentIdentifier? = nil) {
        workspaceSessions.removeValue(forKey: ShelfFilesOwner(id: workspaceID, ownerID: ownerID))?.cancelPendingDocumentLoad()
    }

    var taskSessionCountForTesting: Int { taskSessions.count }
    var workspaceSessionCountForTesting: Int { workspaceSessions.count }
}
