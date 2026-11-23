import Foundation
import ASTRACore
import ASTRAModels

extension TaskRunProgressMessage {
    /// Where a line of the progress timeline comes from.
    enum Origin: Hashable, Sendable {
        /// The agent's own explanatory message.
        case agent
        /// Something observed in the run's recorded operations.
        case observed
        /// An observed failure or cancellation.
        case observedFailure
    }
}

/// What the activity surface shows of a run's operations: counts, what is in
/// flight, and the observed milestones that join the agent's messages in the
/// Updates timeline. Built from the run's stored events alone.
struct RunOperationsPresentation: Hashable, Sendable {
    struct InFlightOperation: Hashable, Sendable, Identifiable {
        let id: UUID
        let tool: String
        let detail: String?
        let startedAt: Date?
    }

    static let inFlightDisplayLimit = 3

    let runID: UUID?
    let isRunning: Bool
    let totalCount: Int
    let finishedCount: Int
    let failedCount: Int
    /// Whether results are tied to their calls by record, so "finished" is a
    /// count of known outcomes rather than a guess.
    let hasOperationRecords: Bool
    /// The newest calls with no result yet, while the run is going.
    let inFlight: [InFlightOperation]
    let inFlightCount: Int
    let milestones: [TaskRunProgressMessage]
    let failedUseEventIDs: Set<UUID>
    /// Results that kept output, of which a display cap may show only some.
    let resultsWithOutput: Int
    let lastRecordedActivityAt: Date?
    let lastAgentMessageAt: Date?
    /// Whether the thread loaded only part of the task's history, so the
    /// counts here are of what is loaded and not of the whole run.
    var historyIsPartial = false

    static let empty = RunOperationsPresentation(
        runID: nil, isRunning: false, totalCount: 0, finishedCount: 0, failedCount: 0,
        hasOperationRecords: false, inFlight: [], inFlightCount: 0, milestones: [],
        failedUseEventIDs: [], resultsWithOutput: 0, lastRecordedActivityAt: nil, lastAgentMessageAt: nil
    )

    init(run: TaskRunSnapshot, events: [TaskEventSnapshot], historyIsPartial: Bool = false) {
        let projection = RunOperationProjection(events: events.map {
            .init(id: $0.id, type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
        })
        self.init(run: run, projection: projection)
        self.historyIsPartial = historyIsPartial
    }

    init(run: TaskRunSnapshot, projection: RunOperationProjection) {
        runID = run.id
        isRunning = run.status == .running
        totalCount = projection.operations.count
        finishedCount = projection.finishedCount
        failedCount = projection.failedCount
        hasOperationRecords = projection.hasOperationRecords
        // Only a run that is still going has calls in flight. Once it has
        // ended, a call with no result is one whose ending was never seen.
        let open = isRunning ? projection.openOperations : []
        inFlightCount = open.count
        inFlight = open.suffix(Self.inFlightDisplayLimit).reversed().map {
            InFlightOperation(id: $0.id, tool: $0.tool, detail: $0.detail, startedAt: $0.startedAt)
        }
        milestones = projection.milestones.map { milestone in
            TaskRunProgressMessage(
                id: milestone.id,
                text: milestone.text,
                timestamp: milestone.timestamp,
                origin: milestone.isAttention ? .observedFailure : .observed
            )
        }
        failedUseEventIDs = projection.failedUseEventIDs
        resultsWithOutput = projection.resultsWithOutput
        lastRecordedActivityAt = [projection.lastOperationEventAt, projection.lastAgentMessageAt].compactMap { $0 }.max()
        lastAgentMessageAt = projection.lastAgentMessageAt
    }

    private init(
        runID: UUID?, isRunning: Bool, totalCount: Int, finishedCount: Int, failedCount: Int,
        hasOperationRecords: Bool, inFlight: [InFlightOperation], inFlightCount: Int,
        milestones: [TaskRunProgressMessage], failedUseEventIDs: Set<UUID>, resultsWithOutput: Int,
        lastRecordedActivityAt: Date?, lastAgentMessageAt: Date?
    ) {
        self.runID = runID
        self.isRunning = isRunning
        self.totalCount = totalCount
        self.finishedCount = finishedCount
        self.failedCount = failedCount
        self.hasOperationRecords = hasOperationRecords
        self.inFlight = inFlight
        self.inFlightCount = inFlightCount
        self.milestones = milestones
        self.failedUseEventIDs = failedUseEventIDs
        self.resultsWithOutput = resultsWithOutput
        self.lastRecordedActivityAt = lastRecordedActivityAt
        self.lastAgentMessageAt = lastAgentMessageAt
    }

    var hasContent: Bool { totalCount > 0 || !milestones.isEmpty }

    /// The agent's messages and the observed milestones as one timeline, in
    /// time order. At the same instant the agent's line comes first.
    func timeline(merging agentMessages: [TaskRunProgressMessage]) -> [TaskRunProgressMessage] {
        guard !milestones.isEmpty else { return agentMessages }
        let tagged = agentMessages.enumerated().map { (message: $0.element, group: 0, offset: $0.offset) }
            + milestones.enumerated().map { (message: $0.element, group: 1, offset: $0.offset) }
        return tagged.sorted { lhs, rhs in
            if lhs.message.timestamp != rhs.message.timestamp { return lhs.message.timestamp < rhs.message.timestamp }
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            return lhs.offset < rhs.offset
        }.map(\.message)
    }

    /// `146 operations · 140 finished · 2 failed · 4 in flight`. "Finished" is
    /// only stated where records make it a fact.
    var summaryLine: String? {
        guard totalCount > 0 else { return nil }
        // Part of the history is not a run total, and must not read as one.
        let scope = historyIsPartial ? " in the loaded history" : ""
        var parts = ["\(totalCount) \(totalCount == 1 ? "operation" : "operations")\(scope)"]
        if hasOperationRecords { parts.append("\(finishedCount) finished") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if inFlightCount > 0 { parts.append("\(inFlightCount) in flight") }
        return parts.joined(separator: " · ")
    }

    /// What is running now, for a run that is still going.
    func currentActivityLine(now: Date) -> String? {
        guard isRunning, let current = inFlight.first else { return nil }
        var text = "Running \(current.tool)"
        if let detail = current.detail { text += " — \(detail)" }
        if let startedAt = current.startedAt { text += " · started \(Self.age(since: startedAt, now: now)) ago" }
        if inFlightCount > 1 { text += " · \(inFlightCount - 1) more in flight" }
        return text
    }

    /// When activity was last seen, stated as what it is: live stream
    /// traffic while the run is streaming here, otherwise the last recorded
    /// event — never a heartbeat this process did not receive.
    func freshnessLine(now: Date, live: RunLiveActivity?) -> String? {
        guard isRunning else { return nil }
        var parts: [String] = []
        if let live {
            parts.append("Last activity \(Self.age(since: live.lastTrafficAt, now: now)) ago")
        } else if let lastRecordedActivityAt {
            parts.append("Last recorded activity \(Self.age(since: lastRecordedActivityAt, now: now)) ago")
        }
        if let lastAgentMessageAt, now.timeIntervalSince(lastAgentMessageAt) >= 60 {
            parts.append("last update from the agent \(Self.age(since: lastAgentMessageAt, now: now)) ago")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
    }
}

private extension RunOperationProjection.Milestone {
    var isAttention: Bool {
        switch kind {
        case .operationFailed: true
        case .backgroundJob(let outcome): outcome == .failed || outcome == .cancelled
        case .workSummary: false
        }
    }
}

extension RunActivityPresentation {
    /// The Updates timeline: the agent's messages with the observed
    /// milestones among them. `progressMessages` stays the agent's own, for
    /// the places that quote or count what the agent said.
    var timeline: [TaskRunProgressMessage] { operations.timeline(merging: progressMessages) }
}

extension RunActivityTabDescriptor {
    /// `12 of 140` when the tab shows only some of what was recorded.
    var countText: String? {
        guard let count, count > 0 else { return nil }
        guard let total, total > count else { return "\(count)" }
        return "\(count) of \(total)"
    }
}
