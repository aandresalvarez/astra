import Combine
import Foundation

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
        let created = ShelfBrowserSession()
        _sharedSession = created
        return created
    }
    private var taskSessions: [UUID: ShelfBrowserSession] = [:]
    /// Last UI access per task, used to pick LRU eviction victims.
    private var lastAccess: [UUID: Date] = [:]
    /// Soft cap on live per-task WebKit sessions. Each session holds a
    /// WKWebView (its own WebContent process) plus a localhost bridge listener,
    /// so without a cap every task ever browsed in a window leaks one until the
    /// window closes. Idle, non-active sessions over this cap are torn down.
    private let maxLiveTaskSessions = 6

    func session(for taskID: UUID?, pinnedToTask: Bool, enabledBrowserAdapters: [String]) -> ShelfBrowserSession {
        guard pinnedToTask, let taskID else {
            sharedSession.bindToTask(taskID)
            sharedSession.setEnabledBrowserAdapters(enabledBrowserAdapters)
            return sharedSession
        }

        lastAccess[taskID] = Date()

        if let session = taskSessions[taskID] {
            session.bindToTask(taskID)
            session.setEnabledBrowserAdapters(enabledBrowserAdapters)
            return session
        }

        let session = ShelfBrowserSession()
        session.bindToTask(taskID)
        session.setEnabledBrowserAdapters(enabledBrowserAdapters)
        taskSessions[taskID] = session
        // Only sweep when the dict actually grew (new task), so the hot
        // `session(for:)` path stays cheap during view updates.
        evictIdleSessionsIfNeeded(keeping: taskID)
        return session
    }

    /// Tear down and drop the session bound to `taskID` (e.g. on task delete).
    func releaseSession(for taskID: UUID) {
        lastAccess.removeValue(forKey: taskID)
        guard let session = taskSessions.removeValue(forKey: taskID) else { return }
        session.teardown()
    }

    /// Evict the least-recently-used *evictable* sessions when over the cap.
    /// Never evicts the kept/presented session or one a background agent is
    /// driving (see ShelfBrowserSession.isEvictable). If everything over the
    /// cap is busy, the cap is exceeded rather than risk interrupting work.
    private func evictIdleSessionsIfNeeded(keeping keepTaskID: UUID?) {
        guard taskSessions.count > maxLiveTaskSessions else { return }
        let overflow = taskSessions.count - maxLiveTaskSessions
        let victims = taskSessions
            .filter { $0.key != keepTaskID && $0.value.isEvictable }
            .sorted { (lastAccess[$0.key] ?? .distantPast) < (lastAccess[$1.key] ?? .distantPast) }
            .prefix(overflow)
        for (victimID, session) in victims {
            taskSessions.removeValue(forKey: victimID)
            lastAccess.removeValue(forKey: victimID)
            session.teardown()
        }
    }

    func promoteSharedSession(
        to taskID: UUID,
        pinnedToTask: Bool,
        isPresented: Bool,
        enabledBrowserAdapters: [String] = []
    ) -> Bool {
        // Don't force-create a shared session just to inspect it: if one was
        // never made, there is no draft page to promote. Short-circuit on the
        // backing before touching the lazy accessor.
        guard pinnedToTask,
              taskSessions[taskID] == nil,
              let existingShared = _sharedSession,
              existingShared.hasDisplayablePage || existingShared.isLoading else {
            return false
        }

        existingShared.bindToTask(taskID)
        existingShared.setEnabledBrowserAdapters(enabledBrowserAdapters)
        existingShared.setPresented(isPresented)
        taskSessions[taskID] = existingShared
        lastAccess[taskID] = Date()
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
        enabledBrowserAdapters: [String] = []
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
            enabledBrowserAdapters: enabledBrowserAdapters
        ).setPresented(true)
    }
}

@MainActor
final class ShelfMarkdownSessionStore: ObservableObject {
    private let sharedSession = ShelfMarkdownSession()
    private var taskSessions: [UUID: ShelfMarkdownSession] = [:]

    func session(for taskID: UUID?, pinnedToTask: Bool) -> ShelfMarkdownSession {
        guard pinnedToTask, let taskID else {
            sharedSession.bindToTask(taskID)
            return sharedSession
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
}
