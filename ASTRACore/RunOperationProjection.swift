import Foundation

/// What one run did, rebuilt from its durable events: each tool operation with
/// the outcome its `tool.operation` record gives, the background jobs that
/// ended, and the milestones worth a line in a progress timeline.
///
/// It reads only stored events, so the same history gives the same projection
/// after a task is reopened. It states what was observed and nothing more: a
/// call with no record has no known outcome, a finished call is not a passed
/// validation, and no milestone is derived from elapsed time.
public struct RunOperationProjection: Sendable, Equatable {
    /// One event of a run, as stored, in the order it was recorded.
    public struct Event: Sendable {
        public let id: UUID
        public let type: String
        public let payload: String
        public let timestamp: Date

        public init(id: UUID, type: String, payload: String, timestamp: Date) {
            self.id = id
            self.type = type
            self.payload = payload
            self.timestamp = timestamp
        }
    }

    public struct Operation: Sendable, Equatable, Identifiable {
        /// The `tool.use` row, or the record's own position when the call was
        /// never among the rows.
        public let id: UUID
        public let tool: String
        /// The call's input as recorded, bounded by the recorder.
        public let detail: String?
        public let startedAt: Date?
        public let finishedAt: Date?
        /// `nil` while nothing says how the call ended.
        public let outcome: AgentOperationOutcome?
        public let exitCode: Int?
        /// Whether the outcome is tied to this call by a record, rather than
        /// unknown because the history predates them.
        public let isCorrelated: Bool
        public let resultEventID: UUID?
    }

    public enum MilestoneKind: Sendable, Equatable {
        /// A tool operation failed or was cancelled.
        case operationFailed
        /// A provider background job ended.
        case backgroundJob(AgentOperationOutcome)
        /// A stretch of operations with no agent message between them.
        case workSummary
    }

    public struct Milestone: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let timestamp: Date
        public let kind: MilestoneKind
        public let text: String
        /// The stored event that is the evidence for this line.
        public let evidenceEventID: UUID?
    }

    public let operations: [Operation]
    public let milestones: [Milestone]
    /// Results that kept output, including ones a display cap later hides.
    public let resultsWithOutput: Int
    public let lastOperationEventAt: Date?
    public let lastAgentMessageAt: Date?

    public static let empty = RunOperationProjection(
        operations: [], milestones: [], resultsWithOutput: 0, lastOperationEventAt: nil, lastAgentMessageAt: nil
    )

    /// Operations between two agent messages before they earn a summary line.
    public static let workSummaryThreshold = 5

    public var finishedCount: Int { operations.filter { $0.outcome != nil }.count }
    public var failedCount: Int { operations.filter { $0.outcome == .failed }.count }
    /// Calls with no terminal evidence. In a run that is still going these
    /// are in flight; in one that ended, how they ended was never recorded.
    public var openOperations: [Operation] { operations.filter { $0.outcome == nil && $0.isCorrelated } }
    public var failedUseEventIDs: Set<UUID> { Set(operations.filter { $0.outcome == .failed }.map(\.id)) }
    /// Whether this run's results are tied to their calls by record.
    public var hasOperationRecords: Bool { operations.contains { $0.outcome != nil && $0.isCorrelated } }

    public init(events: [Event]) {
        var recordOfUse: [UUID: (record: ToolOperationRecord, at: Date)] = [:]
        var orphanRecords: [(record: ToolOperationRecord, at: Date, eventID: UUID, index: Int)] = []
        var recordedResults: Set<UUID> = []
        var resultTimestamps: [UUID: Date] = [:]
        var hasRecords = false
        for event in events {
            switch event.type {
            case "tool.result", "tool.result.failed":
                resultTimestamps[event.id] = event.timestamp
            case ToolOperationRecord.eventType:
                for (index, record) in (ToolOperationBatch.decode(from: event.payload)?.operations ?? []).enumerated() {
                    hasRecords = true
                    if let result = record.resultEventID { recordedResults.insert(result) }
                    let at = record.finishedAt ?? event.timestamp
                    if let use = record.useEventID {
                        recordOfUse[use] = (record, at)
                    } else {
                        orphanRecords.append((record, at, event.id, index))
                    }
                }
            default:
                break
            }
        }

        // A run recorded with records has every result named by one; a run
        // with a result no record names predates them. Before the first
        // result arrives neither is true yet, and the calls are simply open.
        let correlated = hasRecords || resultTimestamps.keys.allSatisfy(recordedResults.contains)

        var operations: [Operation] = []
        var milestones: [Milestone] = []
        var stretch: [Operation] = []
        var lastOperationEventAt: Date?
        var lastAgentMessageAt: Date?

        func closeStretch() {
            defer { stretch = [] }
            guard stretch.count >= Self.workSummaryThreshold, let last = stretch.last else { return }
            milestones.append(Milestone(
                id: Self.derivedID(from: last.id, salt: 1),
                timestamp: last.finishedAt ?? last.startedAt ?? .distantPast,
                kind: .workSummary,
                text: Self.workSummary(of: stretch),
                evidenceEventID: last.id
            ))
        }

        for event in events {
            switch event.type {
            case "agent.response":
                guard !event.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lastAgentMessageAt = event.timestamp
                closeStretch()
            case "tool.use":
                lastOperationEventAt = event.timestamp
                let call = Self.toolCall(fromUsePayload: event.payload)
                let finished = recordOfUse[event.id]
                let operation = Operation(
                    id: event.id,
                    tool: finished?.record.tool ?? call.tool,
                    detail: call.detail,
                    startedAt: event.timestamp,
                    finishedAt: finished.map { finished in
                        finished.record.resultEventID.flatMap { resultTimestamps[$0] } ?? finished.at
                    },
                    outcome: finished?.record.outcome,
                    exitCode: finished?.record.exitCode,
                    // In a history that predates records the call may well
                    // have finished, and nothing here can say so.
                    isCorrelated: correlated,
                    resultEventID: finished?.record.resultEventID
                )
                operations.append(operation)
                stretch.append(operation)
                if let summary = finished?.record.failureSummary {
                    milestones.append(Milestone(
                        id: Self.derivedID(from: event.id, salt: 2),
                        timestamp: operation.finishedAt ?? event.timestamp,
                        kind: .operationFailed,
                        text: call.detail.map { "\(summary) — \($0)" } ?? summary,
                        evidenceEventID: finished?.record.resultEventID ?? event.id
                    ))
                }
            case "tool.result":
                lastOperationEventAt = event.timestamp
            case "tool.result.failed":
                lastOperationEventAt = event.timestamp
                // A failure no record names: recorded before records existed.
                guard !recordedResults.contains(event.id) else { continue }
                milestones.append(Milestone(
                    id: Self.derivedID(from: event.id, salt: 2),
                    timestamp: event.timestamp,
                    kind: .operationFailed,
                    text: "Tool failed",
                    evidenceEventID: event.id
                ))
            case BackgroundJobRecord.eventType:
                guard let job = BackgroundJobRecord.decode(from: event.payload) else { continue }
                lastOperationEventAt = event.timestamp
                milestones.append(Milestone(
                    id: event.id,
                    timestamp: event.timestamp,
                    kind: .backgroundJob(job.outcome),
                    text: job.milestoneText,
                    evidenceEventID: event.id
                ))
            default:
                break
            }
        }
        closeStretch()

        // A record whose call was never among these rows — the provider gave
        // no call id, or the call lies outside the loaded history — is still
        // a finished operation, and still a failure worth a line.
        for orphan in orphanRecords {
            let id = Self.derivedID(from: orphan.eventID, salt: UInt8(truncatingIfNeeded: 16 &+ orphan.index))
            operations.append(Operation(
                id: id,
                tool: orphan.record.tool ?? "Tool",
                detail: nil,
                startedAt: nil,
                finishedAt: orphan.record.resultEventID.flatMap { resultTimestamps[$0] } ?? orphan.at,
                outcome: orphan.record.outcome,
                exitCode: orphan.record.exitCode,
                isCorrelated: true,
                resultEventID: orphan.record.resultEventID
            ))
            if let summary = orphan.record.failureSummary {
                milestones.append(Milestone(
                    id: Self.derivedID(from: id, salt: 2),
                    timestamp: orphan.at,
                    kind: .operationFailed,
                    text: summary,
                    evidenceEventID: orphan.record.resultEventID ?? orphan.eventID
                ))
            }
        }

        self.operations = operations
        self.milestones = milestones.sorted { $0.timestamp < $1.timestamp }
        resultsWithOutput = hasRecords
            ? operations.filter { $0.resultEventID != nil }.count
            : resultTimestamps.count
        self.lastOperationEventAt = lastOperationEventAt
        self.lastAgentMessageAt = lastAgentMessageAt
    }

    private init(
        operations: [Operation],
        milestones: [Milestone],
        resultsWithOutput: Int,
        lastOperationEventAt: Date?,
        lastAgentMessageAt: Date?
    ) {
        self.operations = operations
        self.milestones = milestones
        self.resultsWithOutput = resultsWithOutput
        self.lastOperationEventAt = lastOperationEventAt
        self.lastAgentMessageAt = lastAgentMessageAt
    }

    // MARK: - Text

    /// `Using tool: <name>[: <input>]`, as the recorder writes a call.
    static func toolCall(fromUsePayload payload: String) -> (tool: String, detail: String?) {
        let prefix = "Using tool: "
        guard payload.hasPrefix(prefix) else {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? "Tool" : String(trimmed.prefix(60)), nil)
        }
        let body = payload.dropFirst(prefix.count)
        let name = String(body.prefix { $0 != ":" }).trimmingCharacters(in: .whitespaces)
        let rest = body.dropFirst(name.count).drop { $0 == ":" || $0 == " " }
        let detail = rest.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) }
        return (name.isEmpty ? "Tool" : name, detail?.isEmpty == false ? detail : nil)
    }

    /// `14 operations: Bash ×8, Read ×4, Edit ×2`, most frequent first, with
    /// the failures among them counted so a summary never hides one.
    static func workSummary(of operations: [Operation]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for operation in operations {
            if counts[operation.tool] == nil { order.append(operation.tool) }
            counts[operation.tool, default: 0] += 1
        }
        let ranked = order.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (counts[lhs.element] ?? 0, counts[rhs.element] ?? 0)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
        var parts = ranked.prefix(3).map { "\($0) ×\(counts[$0] ?? 0)" }
        if ranked.count > 3 { parts.append("\(ranked.count - 3) more") }
        var text = "\(operations.count) operations: \(parts.joined(separator: ", "))"
        let failed = operations.filter { $0.outcome == .failed }.count
        if failed > 0 { text += " · \(failed) failed" }
        return text
    }

    /// A stable id for a line derived from a stored event, so the same
    /// history yields the same timeline rows on every rebuild.
    static func derivedID(from id: UUID, salt: UInt8) -> UUID {
        var bytes = id.uuid
        bytes.15 = bytes.15 ^ salt
        bytes.14 = bytes.14 &+ salt
        return UUID(uuid: bytes)
    }
}

extension BackgroundJobRecord {
    /// `Background job failed · exit code 1`, then what the provider said.
    public var milestoneText: String {
        let verb: String
        switch outcome {
        case .succeeded: verb = "completed"
        case .failed: verb = "failed"
        case .cancelled: verb = "was cancelled"
        case .unknown: verb = "ended"
        }
        var text = "Background job \(verb)"
        if let exitCode { text += " · exit code \(exitCode)" }
        if let summary, !summary.isEmpty { text += " — \(summary)" }
        return text
    }
}
