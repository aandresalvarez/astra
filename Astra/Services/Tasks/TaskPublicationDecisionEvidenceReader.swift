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
        in context: ModelContext
    ) throws -> [TaskEventSnapshot] {
        guard let runID else { return [] }
        var evidence: [TaskEventSnapshot] = []
        for type in [TaskExternalOutcomeEventTypes.publicationRequested,
                     TaskExternalOutcomeEventTypes.publicationReceipt] {
            if let event = try newest(ownerID: ownerID, runID: runID, type: type, in: context) {
                evidence.append(TaskEventSnapshot(event: event))
            }
        }
        // A valid typed request owns the decision, whether pending or already
        // receipted in this run. The resolver never falls back to legacy data.
        if let request = evidence.first(where: { $0.type == TaskExternalOutcomeEventTypes.publicationRequested }),
           let data = request.payload.data(using: .utf8),
           (try? TaskEventPayloadCodec.makeDecoder().decode(TaskRequiredExternalOutcomeRequest.self, from: data)) != nil {
            return evidence
        }
        // Legacy failures can be resolved by a receipt in any run, including
        // an older run not retained by the transcript, or a runless receipt.
        let receipt = try newest(ownerID: ownerID, runID: nil,
                                 type: TaskExternalOutcomeEventTypes.publicationReceipt, in: context)
        if let receipt {
            evidence.append(TaskEventSnapshot(event: receipt))
        }
        let durableFailure = try firstMatching(ownerID: ownerID, runID: runID,
                                      type: TaskExternalOutcomeEventTypes.publicationFailed,
                                      after: receipt?.timestamp, in: context) { event in
            guard let data = event.payload.data(using: .utf8),
                  (try? TaskEventPayloadCodec.makeDecoder().decode(TaskRequiredExternalOutcomeFailure.self, from: data)) != nil else {
                return nil
            }
            return [TaskEventSnapshot(event: event)]
        }
        if !durableFailure.isEmpty {
            return deduplicated(evidence + durableFailure)
        }
        evidence += try firstMatching(ownerID: ownerID, runID: runID,
                                      type: TaskEventTypes.Tool.resultFailed.rawValue,
                                      after: receipt?.timestamp, in: context) { failed in
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
            guard let use = try context.fetch(useQuery).first,
                  TaskExternalOutcomeFailureClassifier.publicationFailureMessage(
                    payload: failed.payload, legacyPrecedingToolUse: use.payload
                  ) != nil else { return nil }
            return [TaskEventSnapshot(event: failed), TaskEventSnapshot(event: use)]
        }
        return deduplicated(evidence)
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
        ownerID: PersistentIdentifier, runID: UUID, type: String, after cutoff: Date? = nil, in context: ModelContext,
        match: (TaskEvent) throws -> [TaskEventSnapshot]?
    ) throws -> [TaskEventSnapshot] {
        var descriptor = query(ownerID: ownerID, runID: runID, type: type)
        descriptor.fetchLimit = batchSize
        while true {
            let batch = try context.fetch(descriptor)
            for event in batch {
                if let cutoff, event.timestamp <= cutoff { return [] }
                if let evidence = try match(event) { return evidence }
            }
            guard batch.count == batchSize else { return [] }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + batch.count
        }
    }
}
