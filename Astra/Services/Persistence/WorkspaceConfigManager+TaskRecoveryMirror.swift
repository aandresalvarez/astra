import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

extension WorkspaceConfigManager {
    struct TaskRecoveryMirror {
        let requests: [TaskTurnRequestSnapshot]
        let sourceEventIDs: Set<UUID>
        let pendingRunIDs: Set<UUID>
    }

    /// Execution evidence is not presentation text. Keep its structured payload
    /// and source identities intact even when display history is bounded.
    static func isTaskRecoveryEvent(_ type: String) -> Bool {
        ["runtime.", "execution.request.", "permission.", "plan.", "validation."].contains { type.hasPrefix($0) }
    }

    static func taskRecoveryMirror(task: AgentTask, modelContext: ModelContext) throws -> TaskRecoveryMirror {
        let id = task.id
        let descriptor = FetchDescriptor<TaskTurnRequest>(predicate: #Predicate { $0.taskID == id })
        let requests = try modelContext.fetch(descriptor).map { try requestSnapshotForMirror($0.snapshot) }
        let settled = Set(task.events.filter { !$0.isDeleted && $0.type == "runtime.turn.settled" }.compactMap { $0.run?.id })
        let pending = Set(task.events.filter { !$0.isDeleted && $0.type == "runtime.result.captured" }.compactMap { $0.run?.id })
            .subtracting(settled)
        let retainedRuns = Set(task.runs.sorted { $0.startedAt < $1.startedAt }
            .suffix(MirrorLimits.maxRunsPerTask).map(\.id)).union(pending)
        let retained = requests.filter { $0.state.isActive || $0.runID.map { retainedRuns.contains($0) } == true }
        return TaskRecoveryMirror(requests: retained, sourceEventIDs: Set(retained.map(\.messageEventID)), pendingRunIDs: pending)
    }

    static func importTaskRequestOwners(_ requests: [TaskTurnRequestSnapshot], task: AgentTask, modelContext: ModelContext) {
        for snapshot in requests {
            guard snapshot.taskID == task.id,
                  task.events.contains(where: { $0.id == snapshot.messageEventID }),
                  snapshot.runID == nil || task.runs.contains(where: { $0.id == snapshot.runID }) else { continue }
            let id = snapshot.id
            guard let existing = try? modelContext.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate { $0.id == id })),
                  existing.isEmpty else { continue }
            modelContext.insert(TaskTurnRequest(snapshot: snapshot, task: task))
        }
    }
    private static func requestSnapshotForMirror(_ source: TaskTurnRequestSnapshot) throws -> TaskTurnRequestSnapshot {
        guard let json = source.executionPolicySnapshotJSON else { return source }
        var policy = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        policy = try redactedLaunchPolicy(policy)
        var projection = source
        projection.executionPolicySnapshotJSON = String(data: try JSONSerialization.data(withJSONObject: policy), encoding: .utf8)
        return projection
    }

    static func taskRecoveryPayload(_ event: TaskEvent) throws -> String {
        guard event.type == "runtime.result.captured" else { return event.payload }
        var checkpoint = try JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any] ?? [:]
        if let launch = checkpoint["launchSnapshot"] as? [String: Any] {
            checkpoint["launchSnapshot"] = try redactedLaunchPolicy(launch)
        }
        return String(data: try JSONSerialization.data(withJSONObject: checkpoint), encoding: .utf8) ?? ""
    }

    private static func redactedLaunchPolicy(_ source: [String: Any]) throws -> [String: Any] {
        var policy = source
        if let value = policy["skillSnapshotsJSON"] as? String, !value.isEmpty {
            let snapshots = try JSONDecoder().decode([SkillSnapshotConfig].self, from: Data(value.utf8))
            policy["skillSnapshotsJSON"] = String(data: try JSONEncoder().encode(snapshots.map(redactedSkillSnapshot)), encoding: .utf8)
        }
        if let environment = policy["executionEnvironmentSnapshotJSON"] as? String {
            policy["executionEnvironmentSnapshotJSON"] = sanitizedExecutionEnvironmentJSON(environment, preservingHost: true)
        }
        return policy
    }

}
