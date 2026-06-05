import Combine
import Foundation

@MainActor
final class ShelfBrowserSessionStore: ObservableObject {
    private var sharedSession = ShelfBrowserSession()
    private var taskSessions: [UUID: ShelfBrowserSession] = [:]

    func session(for taskID: UUID?, pinnedToTask: Bool, enabledBrowserAdapters: [String] = []) -> ShelfBrowserSession {
        guard pinnedToTask, let taskID else {
            sharedSession.bindToTask(taskID)
            sharedSession.setEnabledBrowserAdapters(enabledBrowserAdapters)
            return sharedSession
        }

        if let session = taskSessions[taskID] {
            session.bindToTask(taskID)
            session.setEnabledBrowserAdapters(enabledBrowserAdapters)
            return session
        }

        let session = ShelfBrowserSession()
        session.bindToTask(taskID)
        session.setEnabledBrowserAdapters(enabledBrowserAdapters)
        taskSessions[taskID] = session
        return session
    }

    func promoteSharedSession(
        to taskID: UUID,
        pinnedToTask: Bool,
        isPresented: Bool,
        enabledBrowserAdapters: [String] = []
    ) -> Bool {
        guard pinnedToTask,
              taskSessions[taskID] == nil,
              sharedSession.hasDisplayablePage || sharedSession.isLoading else {
            return false
        }

        sharedSession.bindToTask(taskID)
        sharedSession.setEnabledBrowserAdapters(enabledBrowserAdapters)
        sharedSession.setPresented(isPresented)
        taskSessions[taskID] = sharedSession
        sharedSession = ShelfBrowserSession()
        sharedSession.bindToTask(nil)
        return true
    }

    func setPresented(
        _ isPresented: Bool,
        taskID: UUID?,
        pinnedToTask: Bool,
        enabledBrowserAdapters: [String] = []
    ) {
        sharedSession.setPresented(false)
        for session in taskSessions.values {
            session.setPresented(false)
        }

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
}
