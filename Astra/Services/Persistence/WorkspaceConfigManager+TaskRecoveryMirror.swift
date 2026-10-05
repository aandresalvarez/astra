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
        type == TaskStorageBinding.eventType
            || ["runtime.", "execution.request.", "permission.", "plan.", "validation."].contains { type.hasPrefix($0) }
    }

    /// Recovery authority is explicit and independent of schedule enablement.
    /// File imports remain quarantined; missing-store recovery opts in locally.
    public enum TaskRecoveryImportTrustPolicy {
        case quarantine
        case trustedLocalRecovery
    }

    static func importedRecoveryEventType(_ type: String, trust: TaskRecoveryImportTrustPolicy) -> String {
        guard trust == .quarantine,
              type.hasPrefix("runtime.") || type == TaskStorageBinding.eventType
                || type == "permission.live_approval.committed" else { return type }
        return "imported." + type
    }

    static func quarantinesActiveRecovery(_ config: TaskConfig, trust: TaskRecoveryImportTrustPolicy) -> Bool {
        trust == .quarantine && ((config.turnRequests ?? []).contains { $0.state.isActive }
            || config.events.contains { $0.type == "runtime.result.captured" })
    }

    static func recordImportedRecoveryQuarantine(task: AgentTask, modelContext: ModelContext) {
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info,
            payload: "Imported execution is paused. Resume this task to authorize a new run."))
    }

    static func taskRecoveryMirror(task: AgentTask, modelContext: ModelContext) throws -> TaskRecoveryMirror {
        let settled = Set(task.events.filter { !$0.isDeleted && $0.type == "runtime.turn.settled" }.compactMap { $0.run?.id })
        let pending = Set(task.events.filter { !$0.isDeleted && $0.type == "runtime.result.captured" }.compactMap { $0.run?.id })
            .subtracting(settled)
        let retainedRuns = Set(task.runs.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }.suffix(MirrorLimits.maxRunsPerTask).map(\.id)).union(pending)
        let id = task.id
        let runIDs = retainedRuns.map { Optional($0) }
        let activeStates = TaskTurnRequestState.allCases.filter(\.isActive).map(\.rawValue)
        let descriptor = FetchDescriptor<TaskTurnRequest>(predicate: #Predicate {
            $0.taskID == id && (activeStates.contains($0.stateRawValue) || runIDs.contains($0.runID))
        })
        let requests = try modelContext.fetch(descriptor).compactMap { owner -> TaskTurnRequestSnapshot? in
            do { return try requestSnapshotForMirror(owner.snapshot) }
            catch {
                AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                    "operation": "mirror_request_omitted", "request_id": owner.id.uuidString
                ], level: .error)
                return nil
            }
        }
        return TaskRecoveryMirror(requests: requests, sourceEventIDs: Set(requests.map(\.messageEventID)), pendingRunIDs: pending)
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
        guard var policy = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        policy = try redactedLaunchPolicy(policy)
        var projection = source
        projection.executionPolicySnapshotJSON = String(data: try JSONSerialization.data(withJSONObject: policy), encoding: .utf8)
        return projection
    }

    static func taskRecoveryPayload(_ event: TaskEvent) -> String? {
        guard event.type == "runtime.result.captured" else { return event.payload }
        do {
            guard var checkpoint = try JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let launch = checkpoint["launchSnapshot"] as? [String: Any] {
                checkpoint["launchSnapshot"] = try redactedLaunchPolicy(launch)
            }
            return String(data: try JSONSerialization.data(withJSONObject: checkpoint), encoding: .utf8)
        } catch {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "mirror_checkpoint_omitted", "event_id": event.id.uuidString
            ], level: .error)
            return nil // No malformed or unredacted executable payload enters the mirror.
        }
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
