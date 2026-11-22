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
    /// Worktree events are the task's durable checkout binding; dropping them
    /// would turn a worktree pin into a legacy pin on recovery.
    static func isTaskRecoveryEvent(_ type: String) -> Bool {
        if type.hasPrefix("astra.provider_session_usage_") { return true }
        return ["runtime.", "execution.request.", "permission.", "plan.", "validation.", "task.worktree."]
            .contains { type.hasPrefix($0) }
    }

    /// Recovery authority is explicit and independent of schedule enablement.
    /// File imports remain quarantined; missing-store recovery opts in locally.
    public enum TaskRecoveryImportTrustPolicy {
        case quarantine
        case trustedLocalRecovery
    }

    static func importedRecoveryEventType(_ type: String, trust: TaskRecoveryImportTrustPolicy) -> String {
        guard trust == .quarantine,
              type.hasPrefix("runtime.") || type == "permission.live_approval.committed" else { return type }
        return "imported." + type
    }

    static func quarantinesActiveRecovery(_ config: TaskConfig, trust: TaskRecoveryImportTrustPolicy) -> Bool {
        trust == .quarantine && ((config.turnRequests ?? []).contains { $0.state.isActive }
            || config.events.contains { $0.type == "runtime.result.captured" })
    }

    static func recordImportedHistoryProvenance(task: AgentTask, trust: TaskRecoveryImportTrustPolicy, modelContext: ModelContext) {
        guard trust == .quarantine else { return }
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.historyImported,
            payload: "History imported as a separate local copy. Previous execution ownership is not transferred."))
    }

    static func recordImportedRecoveryQuarantine(task: AgentTask, modelContext: ModelContext) {
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info,
            payload: "Imported execution is paused. Resume this task to authorize a new run."))
    }

    /// Orders rows by time and then by ID, as the mirror always has. Each
    /// row's keys are read once: a comparator that reads a model's property
    /// pays for a SwiftData getter on every comparison, which was a quarter
    /// of the time a large workspace's export took.
    static func chronological<Row>(_ rows: [Row], time: (Row) -> Date, id: (Row) -> UUID) -> [Row] {
        var keyed: [ChronologicalKey<Row>] = []
        keyed.reserveCapacity(rows.count)
        for row in rows {
            keyed.append(ChronologicalKey(row: row, time: time(row), id: id(row)))
        }
        keyed.sort { first, second in
            if first.time == second.time { return first.id.uuidString < second.id.uuidString }
            return first.time < second.time
        }
        return keyed.map(\.row)
    }

    private struct ChronologicalKey<Row> {
        let row: Row
        let time: Date
        let id: UUID
    }

    static func taskRecoveryMirror(task: AgentTask, modelContext: ModelContext) throws -> TaskRecoveryMirror {
        var owners = TaskTurnRequestOwnership.Resolver(
            candidates: try TaskTurnRequestOwnership.candidates(taskID: task.id, in: modelContext))
        return try taskRecoveryMirror(
            task: task, events: task.events,
            sortedRuns: chronological(task.runs, time: \.startedAt, id: \.id),
            owners: &owners, modelContext: modelContext)
    }

    /// `events` and `sortedRuns` are the task's, read once by the caller that
    /// goes on to mirror them. `owners` covers the task; an export holds one
    /// for all its tasks (`TaskTurnRequestOwnership.candidates(taskIDs:in:)`).
    static func taskRecoveryMirror(
        task: AgentTask, events: [TaskEvent], sortedRuns: [TaskRun],
        owners: inout TaskTurnRequestOwnership.Resolver, modelContext: ModelContext
    ) throws -> TaskRecoveryMirror {
        var settled = Set<UUID>()
        var captured = Set<UUID>()
        for event in events where !event.isDeleted {
            switch event.type {
            case "runtime.turn.settled": if let run = event.run?.id { settled.insert(run) }
            case "runtime.result.captured": if let run = event.run?.id { captured.insert(run) }
            default: break
            }
        }
        let pending = captured.subtracting(settled)
        let retainedRuns = Set(sortedRuns.suffix(MirrorLimits.maxRunsPerTask).map(\.id)).union(pending)
        let id = task.id
        let runIDs = retainedRuns.map { Optional($0) }
        let activeStates = TaskTurnRequestState.allCases.filter(\.isActive).map(\.rawValue)
        let descriptor = FetchDescriptor<TaskTurnRequest>(predicate: #Predicate {
            $0.taskID == id && (activeStates.contains($0.stateRawValue) || runIDs.contains($0.runID))
        })
        let rows = try modelContext.fetch(descriptor)
        let requests = TaskTurnRequestOwnership.owned(rows, by: task, resolver: &owners).compactMap { owner -> TaskTurnRequestSnapshot? in
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
        // Imported metadata may bind only after SwiftData assigns a durable local identity.
        if task.persistentModelID.storeIdentifier == nil {
            guard (try? modelContext.save()) != nil else { return }
        }
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
        policy.removeValue(forKey: "taskOwnerID") // A local row identity is never portable.
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
        var policy = try PluginLaunchPolicyRedactor.redact(source)
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
