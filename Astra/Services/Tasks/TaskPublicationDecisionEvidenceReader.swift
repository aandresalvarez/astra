import Foundation
import SwiftData
import ASTRAModels

/// Bounded decision evidence, independent of the rendered transcript. Called by
/// the history store on its fresh background context. Views consume only the
/// resulting values.
/// A typed request/receipt, valid durable failure, matching legacy failure/use,
/// and the latest task-wide receipt suffice for the durable resolver's rules.
enum TaskPublicationDecisionEvidenceReader {
    private static let batchSize = 64

    static func latest(
        ownerID: PersistentIdentifier,
        runID: UUID?,
        cache: Cache? = nil,
        historyInvalidation: Int = 0,
        readRevision: Int? = nil,
        in context: ModelContext
    ) throws -> [TaskEventSnapshot] {
        guard let runID else { return [] }
        cache?.selectOwner(ownerID, container: context.container)
        let editsAtStart = readRevision ?? cache?.mutations.revision
        var evidence: [TaskEventSnapshot] = []
        if let request = try newest(ownerID: ownerID, runID: runID,
                                    type: TaskExternalOutcomeEventTypes.publicationRequested, in: context) {
            evidence.append(TaskEventSnapshot(event: request))
        }
        // A valid typed request owns the decision, whether pending or already
        // receipted in this run. The resolver never falls back to legacy data.
        if let request = evidence.first(where: { $0.type == TaskExternalOutcomeEventTypes.publicationRequested }),
           let data = request.payload.data(using: .utf8),
           (try? TaskEventPayloadCodec.makeDecoder().decode(TaskRequiredExternalOutcomeRequest.self, from: data)) != nil {
            cache?.entry = nil
            if let receipt = try newest(ownerID: ownerID, runID: runID,
                                        type: TaskExternalOutcomeEventTypes.publicationReceipt, in: context) {
                evidence.append(TaskEventSnapshot(event: receipt))
            }
            return evidence
        }
        // Wording matters only for legacy failures. A typed request above is
        // authoritative even after the user removes PR wording from the task.
        var taskQuery = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.persistentModelID == ownerID })
        taskQuery.fetchLimit = 1
        guard let task = try context.fetch(taskQuery).first,
              TaskExternalOutcomeRequirementResolver.requestsGitHubPullRequest(task) else {
            cache?.entry = nil
            cache?.work.intentSkips += 1
            return evidence
        }
        if let ownReceipt = try newest(ownerID: ownerID, runID: runID,
                                       type: TaskExternalOutcomeEventTypes.publicationReceipt, in: context) {
            evidence.append(TaskEventSnapshot(event: ownReceipt))
        }
        // Legacy failures can be resolved by a receipt in any run, including
        // an older run not retained by the transcript, or a runless receipt.
        let receipt = try newest(ownerID: ownerID, runID: nil,
                                 type: TaskExternalOutcomeEventTypes.publicationReceipt, in: context)
        if let receipt {
            evidence.append(TaskEventSnapshot(event: receipt))
        }
        let signature: Signature?
        var precedingSearch: Cache.Entry?
        if let cache {
            let current = try signatureFor(ownerID: ownerID, runID: runID, head: evidence,
                                           historyInvalidation: historyInvalidation,
                                           edits: editsAtStart ?? cache.mutations.revision, in: context)
            signature = current
            if let entry = cache.entry, entry.signature == current,
               try selectedEventsUnchanged(entry.events, ownerID: ownerID, in: context),
               cache.mutations.revision == current.edits {
                cache.work.cacheHits += 1
                return entry.events
            }
            if let entry = cache.entry, try canExtend(entry, to: current, in: context),
               try selectedEventsUnchanged(entry.events, ownerID: ownerID, in: context),
               cache.mutations.revision == current.edits {
                precedingSearch = entry
            }
        } else { signature = nil }
        func finish(_ events: [TaskEventSnapshot]) -> [TaskEventSnapshot] {
            let result = deduplicated(events)
            if let cache, let signature, cache.mutations.revision == signature.edits {
                cache.entry = Cache.Entry(signature: signature, events: result)
            }
            return result
        }
        if let signature, signature.failureCount == 0 { return finish(evidence) }
        // A proven append extends the searched suffix. Keep at most the prior
        // decision packet and one boundary, never a growing list of failures.
        let cutoff = [receipt?.timestamp, precedingSearch?.signature.newestFailure?.timestamp].compactMap { $0 }.max()
        var durableFailure = try firstMatching(ownerID: ownerID, runID: runID,
                                      type: TaskExternalOutcomeEventTypes.publicationFailed,
                                      after: cutoff, cache: cache, in: context) { event in
            guard let data = event.payload.data(using: .utf8),
                  (try? TaskEventPayloadCodec.makeDecoder().decode(TaskRequiredExternalOutcomeFailure.self, from: data)) != nil else {
                return nil
            }
            return [TaskEventSnapshot(event: event)]
        }
        if durableFailure.isEmpty {
            durableFailure = precedingSearch?.events.filter { $0.type == TaskExternalOutcomeEventTypes.publicationFailed } ?? []
        }
        if !durableFailure.isEmpty {
            return finish(evidence + durableFailure)
        }
        var legacyFailure = try firstMatching(ownerID: ownerID, runID: runID,
                                      type: TaskEventTypes.Tool.resultFailed.rawValue,
                                      after: cutoff, cache: cache, in: context) { failed in
            if TaskExternalOutcomeFailureClassifier.publicationFailureMessage(
                payload: failed.payload, legacyPrecedingToolUse: ""
            ) != nil {
                return [TaskEventSnapshot(event: failed)]
            }
            // Embedded tool-use evidence is authoritative, even if empty.
            guard ToolResultFailurePayload.decode(from: failed.payload)?.toolUseEvidence == nil else { return nil }
            let useType = TaskEventTypes.Tool.use.rawValue
            let timestamp = failed.timestamp
            var useQuery = FetchDescriptor<TaskEvent>(predicate: #Predicate {
                $0.task?.persistentModelID == ownerID && $0.run?.id == runID
                    && $0.type == useType && $0.timestamp <= timestamp
            }, sortBy: ordering)
            useQuery.fetchLimit = 1
            cache?.work.toolUseLookups += 1
            guard let use = try context.fetch(useQuery).first,
                  TaskExternalOutcomeFailureClassifier.publicationFailureMessage(
                    payload: failed.payload, legacyPrecedingToolUse: use.payload
                  ) != nil else { return nil }
            return [TaskEventSnapshot(event: failed), TaskEventSnapshot(event: use)]
        }
        if legacyFailure.isEmpty {
            legacyFailure = precedingSearch?.events.filter { $0.type == "tool.result.failed" || $0.type == "tool.use" } ?? []
        }
        return finish(evidence + legacyFailure)
    }

    private static func canExtend(_ entry: Cache.Entry, to current: Signature, in context: ModelContext) throws -> Bool {
        let old = entry.signature
        guard old.ownerID == current.ownerID, old.runID == current.runID,
              old.historyInvalidation == current.historyInvalidation, old.edits == current.edits,
              old.head == current.head, let previous = old.newestFailure,
              let newest = current.newestFailure, newest.timestamp > previous.timestamp,
              current.failureCount > old.failureCount else { return false }
        let ownerID = current.ownerID, runID = current.runID, boundary = previous.timestamp
        let types = ["tool.result.failed", "git.publish.failed"]
        let additions = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.run?.id == runID
                && types.contains($0.type) && $0.timestamp > boundary
        })
        // Any backdated failure is outside this count. Edits/deletions are
        // fenced by the paired-save revision; ties conservatively rescan.
        guard try context.fetchCount(additions) == current.failureCount - old.failureCount else { return false }
        let useType = "tool.use"
        var uses = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.run?.id == runID
                && $0.type == useType && $0.timestamp <= boundary
        }, sortBy: ordering)
        guard try context.fetchCount(uses) == old.precedingUseCount else { return false }
        uses.fetchLimit = 1
        return try context.fetch(uses).first.map(TaskEventSnapshot.init) == old.newestPrecedingUse
    }

    private static func signatureFor(
        ownerID: PersistentIdentifier, runID: UUID, head: [TaskEventSnapshot],
        historyInvalidation: Int, edits: Int, in context: ModelContext
    ) throws -> Signature {
        let failureTypes = [TaskExternalOutcomeEventTypes.publicationFailed, TaskEventTypes.Tool.resultFailed.rawValue]
        var failures = FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && $0.run?.id == runID && failureTypes.contains($0.type)
        }, sortBy: ordering)
        let count = try context.fetchCount(failures)
        failures.fetchLimit = 1
        let newestFailure = try context.fetch(failures).first.map(TaskEventSnapshot.init)
        var useCount = 0
        var newestUse: TaskEventSnapshot?
        if let newestFailure {
            let boundary = newestFailure.timestamp
            let useType = TaskEventTypes.Tool.use.rawValue
            var uses = FetchDescriptor<TaskEvent>(predicate: #Predicate {
                $0.task?.persistentModelID == ownerID && $0.run?.id == runID
                    && $0.type == useType && $0.timestamp <= boundary
            }, sortBy: ordering)
            useCount = try context.fetchCount(uses)
            uses.fetchLimit = 1
            newestUse = try context.fetch(uses).first.map(TaskEventSnapshot.init)
        }
        return Signature(ownerID: ownerID, runID: runID, historyInvalidation: historyInvalidation, edits: edits,
                         head: head, failureCount: count, newestFailure: newestFailure,
                         precedingUseCount: useCount, newestPrecedingUse: newestUse)
    }

    private static func selectedEventsUnchanged(_ events: [TaskEventSnapshot], ownerID: PersistentIdentifier,
                                                in context: ModelContext) throws -> Bool {
        guard !events.isEmpty else { return true }
        let ids = events.map(\.id)
        let rows = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.task?.persistentModelID == ownerID && ids.contains($0.id)
        })).map(TaskEventSnapshot.init)
        return Set(rows) == Set(events)
    }

    private static func deduplicated(_ events: [TaskEventSnapshot]) -> [TaskEventSnapshot] {
        Array(Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, fresh in fresh }).values)
    }

    private static var ordering: [SortDescriptor<TaskEvent>] {
        [SortDescriptor(\TaskEvent.timestamp, order: .reverse), SortDescriptor(\TaskEvent.id, order: .reverse)]
    }

    private static func query(ownerID: PersistentIdentifier, runID: UUID?, type: String) -> FetchDescriptor<TaskEvent> {
        if let runID {
            return FetchDescriptor(predicate: #Predicate<TaskEvent> {
                $0.task?.persistentModelID == ownerID && $0.run?.id == runID && $0.type == type
            }, sortBy: ordering)
        }
        return FetchDescriptor(predicate: #Predicate<TaskEvent> {
            $0.task?.persistentModelID == ownerID && $0.type == type
        }, sortBy: ordering)
    }

    private static func newest(ownerID: PersistentIdentifier, runID: UUID?, type: String,
                               in context: ModelContext) throws -> TaskEvent? {
        var descriptor = query(ownerID: ownerID, runID: runID, type: type)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Malformed durable payloads and unrelated tool failures cannot hide older
    /// actionable evidence. Scan only this run/type in fixed-size batches; do
    /// not materialize its tool history or retain a growing failure list.
    private static func firstMatching(
        ownerID: PersistentIdentifier, runID: UUID, type: String, after cutoff: Date? = nil, cache: Cache? = nil, in context: ModelContext,
        match: (TaskEvent) throws -> [TaskEventSnapshot]?
    ) throws -> [TaskEventSnapshot] {
        var descriptor = query(ownerID: ownerID, runID: runID, type: type)
        if let cutoff {
            descriptor = FetchDescriptor(predicate: #Predicate<TaskEvent> {
                $0.task?.persistentModelID == ownerID && $0.run?.id == runID
                    && $0.type == type && $0.timestamp > cutoff
            }, sortBy: ordering)
        }
        descriptor.fetchLimit = batchSize
        while true {
            let batch = try context.fetch(descriptor)
            for event in batch {
                cache?.work.failureRowsScanned += 1
                if let evidence = try match(event) { return evidence }
            }
            guard batch.count == batchSize else { return [] }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + batch.count
        }
    }
}
