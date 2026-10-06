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

    /// The user message a GitHub thread record says it answers. The records are kept
    /// whole, so the message that made the request has to be kept with them, or a
    /// recovered task no longer owes the rest of a partly sent batch.
    static func threadRequestEventIDs(_ task: AgentTask, retained: Set<UUID>) -> Set<UUID> {
        Set(task.events.flatMap { event -> [UUID] in
            // Only for records the mirror keeps: a batch it dropped must not keep its request
            // message, whole and past every bound, forever.
            guard retained.contains(event.id), event.type.hasPrefix("github.review-threads."),
                  let data = event.payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            // The whole chain: a continuation like "resolve them" only means something
            // with the message that named the pull request kept beside it.
            let ids = ((object["requestEventIDs"] as? [String]) ?? []) + [object["requestID"] as? String].compactMap { $0 }
            return ids.compactMap { UUID(uuidString: $0) }
        })
    }

    static func isThreadWorkflowEvent(_ type: String) -> Bool { type.hasPrefix("github.review-threads.") }

    /// The thread workflow events the mirror keeps, and which of them to compact. Keeping
    /// the whole namespace whole forever made every export grow with each batch, and each
    /// dispatch embeds its approved payload, up to 256 KiB. A batch that was sent and never
    /// receipted is recovery evidence, so every one of them stays: the newest few whole,
    /// older ones without the embedded payload (their file and recorded actions are what
    /// stop a duplicate send). Settled batches are compacted to the newest few, and
    /// dismissals to a bounded number.
    static func threadWorkflowRetention(_ task: AgentTask) -> (kept: Set<UUID>, compact: Set<UUID>) {
        struct Entry { let id: UUID; let type: String; let proposalID: String?; let timestamp: Date }
        let entries = task.events.compactMap { event -> Entry? in
            guard !event.isDeleted, isThreadWorkflowEvent(event.type) else { return nil }
            let object = event.payload.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return Entry(id: event.id, type: event.type, proposalID: object?["proposalID"] as? String, timestamp: event.timestamp)
        }
        let settledTypes: Set<String> = ["github.review-threads.receipt", "github.review-threads.receipt-recovery"]
        typealias Batch = (events: [Entry], last: Date, settled: Bool)
        let batches: [Batch] = Dictionary(grouping: entries.filter { $0.proposalID != nil }, by: { $0.proposalID ?? "" })
            .values.map { events in
                (events: events, last: events.map(\.timestamp).max() ?? .distantPast,
                 settled: events.contains { settledTypes.contains($0.type) })
            }
        let newestFirst = { (lhs: Batch, rhs: Batch) in lhs.last > rhs.last }
        var kept = Set<UUID>(), compact = Set<UUID>()
        for (index, batch) in batches.filter({ !$0.settled }).sorted(by: newestFirst).enumerated() {
            kept.formUnion(batch.events.map(\.id))
            if index >= MirrorLimits.maxActiveThreadBatches {
                compact.formUnion(batch.events.filter { $0.type == "github.review-threads.dispatched" }.map(\.id))
            }
        }
        for batch in batches.filter({ $0.settled }).sorted(by: newestFirst).prefix(MirrorLimits.maxSettledThreadBatches) {
            kept.formUnion(batch.events.map(\.id))
        }
        kept.formUnion(entries.filter { $0.proposalID == nil }.sorted { $0.timestamp > $1.timestamp }
            .prefix(MirrorLimits.maxThreadDismissals).map(\.id))
        return (kept, compact)
    }

    /// A dispatch record with a summary of the required actions in place of its approved payload.
    static func compactedThreadPayload(_ payload: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let approved = object.removeValue(forKey: "approvedPayload") as? [String: Any] else { return payload }
        // What completion recovery needs from the payload: which operations it required.
        var required: [String] = []
        for thread in (approved["threads"] as? [[String: Any]]) ?? [] {
            guard let id = thread["threadId"] as? String else { continue }
            if thread["reply"] is String { required.append("\(id):reply") }
            if thread["resolve"] as? Bool == true { required.append("\(id):resolve") }
        }
        object["requiredActions"] = required
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let compacted = String(data: data, encoding: .utf8) else { return payload }
        return compacted
    }

    /// User messages that may start, renew or cancel a GitHub thread request. The
    /// request is derived from the conversation, so a cancellation dropped by the
    /// bounded history would bring a cancelled request back after recovery. This
    /// cannot call the request logic from here, so it keeps the newest short messages
    /// that use its vocabulary, within a fixed bound.
    static func threadRequestLanguageEventIDs(_ task: AgentTask) -> Set<UUID> {
        let types: Set<String> = [TaskEventTypes.Conversation.userMessage.rawValue, TaskEventTypes.Plan.userMessage.rawValue]
        let words = ["thread", "resolv", "reslolv", "conversation", "comment", "coment", "repl",
                     "never mind", "nevermind", "cancel", "skip", "forget", "drop", "stop", "do not send", "don't send"]
        let matching = task.events.filter { event in
            types.contains(event.type)
                && event.payload.count <= MirrorLimits.maxThreadLanguagePayloadCharacters
                && words.contains(where: { event.payload.localizedCaseInsensitiveContains($0) })
        }
        return Set(matching.sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString > $1.id.uuidString : $0.timestamp > $1.timestamp }
            .prefix(MirrorLimits.maxThreadLanguageEvents).map(\.id))
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
