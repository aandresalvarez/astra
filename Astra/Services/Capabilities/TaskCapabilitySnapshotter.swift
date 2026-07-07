import Foundation
import ASTRACore
import ASTRAModels

enum TaskCapabilitySnapshotter {
    static func capture(for task: AgentTask) {
        TaskCapabilitySnapshotCapture.capture(for: task)
    }

    /// Re-captures snapshots at the start of a fresh run and returns the
    /// names of detached snapshots that were dropped. Snapshots of deleted
    /// skills stay valid for resuming the run that captured them, but a new
    /// run must not keep executing instructions from skills the user removed.
    @discardableResult
    static func refreshForFreshRun(task: AgentTask) -> [String] {
        let liveIDs = Set(task.skills.map { $0.id.uuidString })
        let liveNames = Set(task.skills.map { $0.name.lowercased() })
        let dropped = task.skillSnapshots
            .filter { snapshot in
                if let id = snapshot.id, liveIDs.contains(id) { return false }
                return !liveNames.contains(snapshot.name.lowercased())
            }
            .map(\.name)
        capture(for: task)
        if !dropped.isEmpty {
            AppLogger.audit(.capabilityChatContext, category: "Capabilities", taskID: task.id, fields: [
                "source": "skill_snapshot_refresh",
                "result": "detached_snapshots_dropped",
                "dropped_count": String(dropped.count),
                "dropped_names": dropped.sorted().joined(separator: ",")
            ], level: .info)
        }
        return dropped
    }
}
