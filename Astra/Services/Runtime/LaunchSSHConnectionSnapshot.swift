import Foundation
import ASTRACore
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
/// last launch holding it releases it. Without a pin — admission, the UI, any other caller —
/// readers get the live file, so nothing outside a launch sees a stale copy.
enum LaunchSSHConnectionSnapshot {
    /// Imported task rows may share one task id, so the id alone does not
    /// name a launch. The workspace folder is what the connections are read
    /// from; two rows that share both read the same file, and share one pin.
    private struct Key: Hashable {
        let taskID: UUID
        let workspacePath: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pinned: [Key: (connections: [SSHConnection], pins: Int)] = [:]

    private static func key(for task: AgentTask) -> Key? {
        guard let path = task.workspace?.primaryPath, !path.isEmpty else { return nil }
        return Key(taskID: task.id, workspacePath: WorkspacePathPresentation.standardizedPath(path))
    }

    /// Reads the task's workspace connections once and pins them for its
    /// launch. A launch that finds a pin for the same task id and workspace
    /// joins it, so neither replaces the other's set. Returns what is pinned.
    @discardableResult
    static func pin(for task: AgentTask) -> [SSHConnection] {
        guard let key = key(for: task) else { return [] }
        lock.lock()
        if var existing = pinned[key] {
            existing.pins += 1
            pinned[key] = existing
            lock.unlock()
            return existing.connections
        }
        lock.unlock()
        let connections = SSHConnectionManager.load(workspacePath: key.workspacePath)
        lock.lock()
        defer { lock.unlock() }
        if var existing = pinned[key] {
            // Another launch pinned while this one was reading: join it.
            existing.pins += 1
            pinned[key] = existing
            return existing.connections
        }
        pinned[key] = (connections, 1)
        return connections
    }

    /// Ends one launch's pin. The set stays pinned while another launch of
    /// the same task id and workspace still holds it.
    static func release(for task: AgentTask) {
        guard let key = key(for: task) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var existing = pinned[key] else { return }
        existing.pins -= 1
        pinned[key] = existing.pins > 0 ? existing : nil
    }

    static func pinnedConnections(for task: AgentTask) -> [SSHConnection]? {
        guard let key = key(for: task) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return pinned[key]?.connections
    }

    /// The pinned set during a launch, otherwise the live file.
    static func connections(for task: AgentTask) -> [SSHConnection] {
        if let pinned = pinnedConnections(for: task) { return pinned }
        return task.workspace.map { SSHConnectionManager.load(workspacePath: $0.primaryPath) } ?? []
    }

    /// As `connections(for:)`, but outside a launch it reads without
    /// migrating the file: admission asks often and must not move domain
    /// files as a side effect.
    static func connectionsWithoutMigrating(for task: AgentTask) -> [SSHConnection] {
        if let pinned = pinnedConnections(for: task) { return pinned }
        return task.workspace.map { SSHConnectionManager.loadForExport(workspacePath: $0.primaryPath) } ?? []
    }
}
