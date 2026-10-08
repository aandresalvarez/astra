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
        ["runtime.", "execution.request.", "permission.", "plan.", "validation.", "github.review-threads."].contains { type.hasPrefix($0) }
    }

    static func isThreadWorkflowEvent(_ type: String) -> Bool { type.hasPrefix("github.review-threads.") }

    /// The thread workflow events the mirror keeps, which of them to compact, and which compacted
    /// dispatches to mark settled. Keeping the whole namespace whole forever made every export grow
    /// with each batch, and each dispatch embeds its approved payload, up to 256 KiB.
    ///
    /// - Unsettled batches are recovery evidence, so every one stays: the newest few whole, older
    ///   ones without the embedded payload.
    /// - Settled batches (by the same rule completion uses, `GitHubReviewThreadSettlement`) keep the
    ///   newest few whole. Older ones keep what stops a replay: the dispatch, without its payload and
    ///   marked settled, so a batch settled by its action receipts stays settled without them, and
    ///   the final receipt with one entry per operation.
    /// - Every dismissal stays, because it is the only record of the user's decision and of a file
    ///   that must not be offered again; beyond the newest few only its file identity is kept whole.
    static func threadWorkflowRetention(_ task: AgentTask) -> (kept: Set<UUID>, compact: Set<UUID>, markSettled: Set<UUID>) {
        struct Entry { let id: UUID; let type: String; let proposalID: String?; let timestamp: Date }
        let events = task.events.filter { !$0.isDeleted && isThreadWorkflowEvent($0.type) }
        let entries = events.map { event -> Entry in
            let object = event.payload.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return Entry(id: event.id, type: event.type, proposalID: object?["proposalID"] as? String, timestamp: event.timestamp)
        }
        let unsettled = GitHubReviewThreadSettlement.unsettledProposalIDs(events.map {
            GitHubReviewThreadSettlement.Record(type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
        })
        typealias Batch = (events: [Entry], last: Date, settled: Bool)
        let batches: [Batch] = Dictionary(grouping: entries.filter { $0.proposalID != nil }, by: { $0.proposalID ?? "" })
            .map { proposalID, events in
                (events: events, last: events.map(\.timestamp).max() ?? .distantPast, settled: !unsettled.contains(proposalID))
            }
        let newestFirst = { (lhs: Batch, rhs: Batch) in lhs.last > rhs.last }
        var kept = Set<UUID>(), compact = Set<UUID>(), markSettled = Set<UUID>()
        for (index, batch) in batches.filter({ !$0.settled }).sorted(by: newestFirst).enumerated() {
            kept.formUnion(batch.events.map(\.id))
            if index >= MirrorLimits.maxActiveThreadBatches {
                compact.formUnion(batch.events.filter { $0.type == GitHubReviewThreadSettlement.dispatched }.map(\.id))
            }
        }
        for (index, batch) in batches.filter({ $0.settled }).sorted(by: newestFirst).enumerated() {
            if index < MirrorLimits.maxSettledThreadBatches {
                kept.formUnion(batch.events.map(\.id))
            } else {
                let dispatches = batch.events.filter { $0.type == GitHubReviewThreadSettlement.dispatched }
                let identity = dispatches + batch.events.filter { GitHubReviewThreadSettlement.finalTypes.contains($0.type) }
                kept.formUnion(identity.map(\.id))
                compact.formUnion(identity.map(\.id))
                markSettled.formUnion(dispatches.map(\.id))
            }
        }
        for (index, dismissal) in entries.filter({ $0.proposalID == nil }).sorted(by: { $0.timestamp > $1.timestamp }).enumerated() {
            kept.insert(dismissal.id)
            if index >= MirrorLimits.maxThreadDismissals { compact.insert(dismissal.id) }
        }
        return (kept, compact, markSettled)
    }

    /// A record with a summary in place of what recovery no longer needs: a dispatch keeps the
    /// actions its approved payload required (and the settled mark, when given), a final receipt
    /// keeps one entry per operation, which is all that completion reads, and a dismissal keeps
    /// its file with a shortened reason.
    static func compactedThreadPayload(_ payload: String, type: String, markSettled: Bool = false) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return payload }
        if type == GitHubReviewThreadSettlement.dispatched {
            if object["approvedPayload"] != nil {
                object["requiredActions"] = GitHubReviewThreadSettlement.requiredActions(object) ?? []
                object.removeValue(forKey: "approvedPayload")
            }
            if markSettled { object["settled"] = true }
        } else if GitHubReviewThreadSettlement.finalTypes.contains(type), let actions = object["actions"] as? [[String: Any]] {
            let operations = Set(actions.compactMap { $0["operation"] as? String }).sorted()
            object["actions"] = operations.map { ["threadID": "*", "operation": $0] }
        } else if type == "github.review-threads.dismissed", let reason = object["reason"] as? String {
            object["reason"] = String(reason.prefix(MirrorLimits.maxCompactedDismissalReasonCharacters))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let compacted = String(data: data, encoding: .utf8) else { return payload }
        return compacted
    }

    /// Recovery authority is explicit and independent of schedule enablement.
    /// File imports remain quarantined; missing-store recovery opts in locally.
    public enum TaskRecoveryImportTrustPolicy {
        case quarantine
        case trustedLocalRecovery
    }

    static func importedRecoveryEventType(_ type: String, trust: TaskRecoveryImportTrustPolicy) -> String {
        guard trust == .quarantine,
              type.hasPrefix("runtime.") || type.hasPrefix("github.review-threads.") || type == "permission.live_approval.committed" else { return type }
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
