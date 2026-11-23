import Foundation
import ASTRAModels
import ASTRAPersistence

/// The workspace SSH connections one launch works from, read once.
///
/// A launch reads the connections file in several places: its remote-folder
/// drift check, its launch grants, the SSH route and job helper it offers the
/// agent, and its prompt. Read separately, a file changed between those reads
/// lets the launch reach a folder its lease never covered, after the drift
/// check passed. The worker pins one read before its remote-workspace
/// preflight and releases it when the run ends, so the check and everything
/// the launch builds agree on one set.
///
/// Source: `SSHConnectionManager.load` at pin time. Invalidated when the
/// worker releases it. Without a pin — admission, the UI, any other caller —
/// readers get the live file, so nothing outside a launch sees a stale copy.
enum LaunchSSHConnectionSnapshot {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pinned: [UUID: [SSHConnection]] = [:]

    /// Reads the task's workspace connections once and pins them for its
    /// launch. Returns what was pinned.
    @discardableResult
    static func pin(for task: AgentTask) -> [SSHConnection] {
        let connections = task.workspace.map { SSHConnectionManager.load(workspacePath: $0.primaryPath) } ?? []
        lock.lock()
        pinned[task.id] = connections
        lock.unlock()
        return connections
    }

    static func release(taskID: UUID) {
        lock.lock()
        pinned[taskID] = nil
        lock.unlock()
    }

    static func pinnedConnections(taskID: UUID) -> [SSHConnection]? {
        lock.lock()
        defer { lock.unlock() }
        return pinned[taskID]
    }

    /// The pinned set during a launch, otherwise the live file.
    static func connections(for task: AgentTask) -> [SSHConnection] {
        if let pinned = pinnedConnections(taskID: task.id) { return pinned }
        return task.workspace.map { SSHConnectionManager.load(workspacePath: $0.primaryPath) } ?? []
    }

    /// As `connections(for:)`, but outside a launch it reads without
    /// migrating the file: admission asks often and must not move domain
    /// files as a side effect.
    static func connectionsWithoutMigrating(for task: AgentTask) -> [SSHConnection] {
        if let pinned = pinnedConnections(taskID: task.id) { return pinned }
        return task.workspace.map { SSHConnectionManager.loadForExport(workspacePath: $0.primaryPath) } ?? []
    }
}
