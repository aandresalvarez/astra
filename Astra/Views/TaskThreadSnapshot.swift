import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskConversationItem: Identifiable, Sendable {
    case userMessage(text: String, timestamp: Date)
    case agentResponse(run: TaskRunSnapshot)
    case planUserMessage(text: String, timestamp: Date)
    case planAssistantMessage(text: String, timestamp: Date)
    case scheduleResult(text: String, timestamp: Date)
    /// `count` > 1 means adjacent identical notices were coalesced into one
    /// row (e.g. the same permission approved several times in a run).
    case systemInfo(text: String, timestamp: Date, count: Int)
    case recapResult(text: String, timestamp: Date)

    var id: String {
        switch self {
        case .userMessage(_, let timestamp): return "user-\(timestamp.timeIntervalSince1970)"
        case .agentResponse(let run): return "agent-\(run.id)"
        case .planUserMessage(_, let timestamp): return "plan-user-\(timestamp.timeIntervalSince1970)"
        case .planAssistantMessage(_, let timestamp): return "plan-assistant-\(timestamp.timeIntervalSince1970)"
        case .scheduleResult(_, let timestamp): return "schedule-\(timestamp.timeIntervalSince1970)"
        case .systemInfo(_, let timestamp, _): return "system-\(timestamp.timeIntervalSince1970)"
        case .recapResult(_, let timestamp): return "recap-\(timestamp.timeIntervalSince1970)"
        }
    }
}

struct TaskEventSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let runID: UUID?
    let type: String
    let payload: String
    let timestamp: Date

    init(event: TaskEvent) {
        id = event.id
        runID = event.run?.id
        type = event.type
        payload = event.payload
        timestamp = event.timestamp
    }
}

struct TaskRunSnapshot: Identifiable, Hashable, Sendable {
    private static let maximumDecodedFileChangesJSONBytes = 262_144
    let id: UUID
    let status: RunStatus
    let startedAt: Date
    let completedAt: Date?
    let tokensUsed: Int
    let inputTokens: Int
    let outputTokens: Int
    let runtimeID: String?
    let providerSessionId: String?
    let providerVersion: String?
    let exitCode: Int?
    let output: String
    let hasVPNWarning: Bool
    let costUSD: Double
    let fileChangesJSONLength: Int
    let fileChanges: [StoredFileChange]
    let hasOmittedFileChanges: Bool
    let stopReason: String

    var completedWithoutUserFacingResult: Bool {
        status == .completed &&
            output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            fileChanges.isEmpty && !hasOmittedFileChanges
    }

    init(input: TaskRunSnapshotInput) {
        self.init(input: input, cancellationCheck: {})
    }

    fileprivate init(
        input: TaskRunSnapshotInput,
        cancellationCheck: () throws -> Void
    ) rethrows {
        try cancellationCheck()
        id = input.id
        status = input.status
        startedAt = input.startedAt
        completedAt = input.completedAt
        tokensUsed = input.tokensUsed
        inputTokens = input.inputTokens
        outputTokens = input.outputTokens
        runtimeID = input.runtimeID
        providerSessionId = input.providerSessionId
        providerVersion = input.providerVersion
        exitCode = input.exitCode
        output = try AstraRunProtocolDisplaySanitizer.clean(
            input.output,
            cancellationCheck: cancellationCheck
        )
        hasVPNWarning = try Self.outputContainsVPNWarning(
            input.output,
            cancellationCheck: cancellationCheck
        )
        costUSD = input.costUSD
        fileChangesJSONLength = input.fileChangesJSON.count
        try Self.checkpoint(
            input.fileChangesJSON,
            cancellationCheck: cancellationCheck
        )
        hasOmittedFileChanges = input.fileChangesJSON.utf8.count > Self.maximumDecodedFileChangesJSONBytes
        fileChanges = hasOmittedFileChanges ? [] : Self.decodeFileChanges(input.fileChangesJSON)
        try cancellationCheck()
        stopReason = input.stopReason
    }

    private static func decodeFileChanges(_ json: String) -> [StoredFileChange] {
        guard let data = json.data(using: .utf8),
              let changes = try? JSONDecoder().decode([StoredFileChange].self, from: data) else {
            return []
        }
        return changes
    }

    private static func outputContainsVPNWarning(
        _ output: String,
        cancellationCheck: () throws -> Void
    ) rethrows -> Bool {
        let needles = [
            "vpc_service_controls",
            "security_policy_violated",
            "request is prohibited by organization's policy",
            "vpcservicecontrolsuniqueidentifier",
        ]
        let overlapCount = (needles.map(\.count).max() ?? 1) - 1
        var carry = ""
        var start = output.startIndex
        while start < output.endIndex {
            try cancellationCheck()
            let end = output.index(start, offsetBy: 16_384, limitedBy: output.endIndex) ?? output.endIndex
            let candidate = carry + output[start..<end]
            let lowercasedCandidate = candidate.lowercased()
            if needles.contains(where: lowercasedCandidate.contains) { return true }
            carry = String(candidate.suffix(overlapCount))
            start = end
        }
        try cancellationCheck()
        return false
    }

    private static func checkpoint(
        _ text: String,
        cancellationCheck: () throws -> Void
    ) rethrows {
        var index = text.startIndex
        while index < text.endIndex {
            try cancellationCheck()
            index = text.index(index, offsetBy: 16_384, limitedBy: text.endIndex) ?? text.endIndex
        }
        try cancellationCheck()
    }
}

struct TaskRunSnapshotInput: Identifiable, Sendable {
    let id: UUID
    let status: RunStatus
    let startedAt: Date
    let completedAt: Date?
    let tokensUsed: Int
    let inputTokens: Int
    let outputTokens: Int
    let runtimeID: String?
    let providerSessionId: String?
    let providerVersion: String?
    let exitCode: Int?
    let output: String
    let costUSD: Double
    let fileChangesJSON: String
    let stopReason: String

    init(run: TaskRun) {
        id = run.id
        status = run.status
        startedAt = run.startedAt
        completedAt = run.completedAt
        tokensUsed = run.tokensUsed
        inputTokens = run.inputTokens
        outputTokens = run.outputTokens
        runtimeID = run.runtimeID
        providerSessionId = run.providerSessionId
        providerVersion = run.providerVersion
        exitCode = run.exitCode
        output = run.output
        costUSD = run.costUSD
        fileChangesJSON = run.fileChangesJSON
        stopReason = run.stopReason
    }
}

struct TaskThreadSnapshotInput: Sendable {
    let goal: String
    let createdAt: Date
    let events: [TaskEventSnapshot]
    let runs: [TaskRunSnapshotInput]
    let totalEventCount: Int
    let omittedEventCount: Int
    let totalRunCount: Int
    let omittedRunCount: Int

    init(task: AgentTask, maxRuns: Int = 50, performanceFields: [String: String] = [:]) {
        let start = DispatchTime.now().uptimeNanoseconds
        let window = TaskThreadSnapshotWindow(events: task.events, runs: task.runs, maxRuns: maxRuns)
        self.init(
            goal: task.goal,
            createdAt: task.createdAt,
            events: window.events.map(TaskEventSnapshot.init),
            runs: window.runs.map(TaskRunSnapshotInput.init),
            totalEventCount: window.totalEventCount,
            omittedEventCount: window.omittedEventCount,
            totalRunCount: window.totalRunCount,
            omittedRunCount: window.omittedRunCount
        )
        PerformanceTelemetry.logIfNeeded(
            "thread_snapshot_input",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
                "event_count": PerformanceTelemetryFields.count(window.totalEventCount),
                "run_count": PerformanceTelemetryFields.count(window.totalRunCount),
                "snapshot_input_events": PerformanceTelemetryFields.count(events.count),
                "snapshot_input_runs": PerformanceTelemetryFields.count(runs.count),
                "omitted_events": PerformanceTelemetryFields.count(omittedEventCount),
                "omitted_runs": PerformanceTelemetryFields.count(omittedRunCount),
                "max_runs": PerformanceTelemetryFields.count(maxRuns)
            ].merging(performanceFields, uniquingKeysWith: { _, new in new }),
            taskID: task.id
        )
    }

    init(goal: String, createdAt: Date, events: [TaskEvent], runs: [TaskRun]) {
        self.init(
            goal: goal,
            createdAt: createdAt,
            events: events.map(TaskEventSnapshot.init),
            runs: runs.map(TaskRunSnapshotInput.init),
            totalEventCount: events.count,
            omittedEventCount: 0,
            totalRunCount: runs.count,
            omittedRunCount: 0
        )
    }

    init(
        goal: String,
        createdAt: Date,
        events: [TaskEventSnapshot],
        runs: [TaskRunSnapshotInput],
        totalEventCount: Int,
        omittedEventCount: Int,
        totalRunCount: Int,
        omittedRunCount: Int
    ) {
        self.goal = goal
        self.createdAt = createdAt
        self.events = events
        self.runs = runs
        self.totalEventCount = totalEventCount
        self.omittedEventCount = omittedEventCount
        self.totalRunCount = totalRunCount
        self.omittedRunCount = omittedRunCount
    }
}

enum TaskThreadStateEventPolicy {
    static let eventTypes: [String] = [
        "astra.todo.replace", "astra.complete", "astra.protocol.invalid",
        "astra.permission_manifest", "astra.permission_summary",
        "permission.approval.requested", "permission.request.resolved",
        "task.dismissed"
    ]
    private static let eventTypeSet = Set(eventTypes)

    static func contains(_ type: String) -> Bool {
        eventTypeSet.contains(type)
    }
}

struct TaskThreadStateEventKey: Hashable, Sendable {
    let runID: UUID?
    let type: String

    init(runID: UUID?, type: String) {
        self.runID = runID
        self.type = type
    }

    init(event: TaskEventSnapshot) {
        self.init(runID: event.runID, type: event.type)
    }
}

enum TaskThreadEventProjectionPolicy {
    private static let maxToolResultsPerRun = 12
    private static let runlessToolResultID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func storageEvents(
        _ events: [TaskEventSnapshot],
        loadedRunIDs: Set<UUID>
    ) -> [TaskEventSnapshot] {
        let runFilteredEvents = events.filter { event in
            guard let runID = event.runID else { return true }
            return loadedRunIDs.contains(runID)
        }
        return capToolResults(
            runFilteredEvents,
            type: \TaskEventSnapshot.type,
            runID: \TaskEventSnapshot.runID,
            id: \TaskEventSnapshot.id
        )
    }

    static func capToolResults<Event>(
        _ events: [Event],
        type: KeyPath<Event, String>,
        runID: KeyPath<Event, UUID?>,
        id: KeyPath<Event, UUID>
    ) -> [Event] {
        var keptToolResultsByRunID: [UUID: Int] = [:]
        var keepEventIDs = Set<UUID>()

        for event in events.reversed() where event[keyPath: type] == "tool.result" {
            let eventRunID = event[keyPath: runID] ?? runlessToolResultID
            let count = keptToolResultsByRunID[eventRunID, default: 0]
            guard count < maxToolResultsPerRun else { continue }
            keptToolResultsByRunID[eventRunID] = count + 1
            keepEventIDs.insert(event[keyPath: id])
        }

        return events.filter { event in
            event[keyPath: type] != "tool.result" || keepEventIDs.contains(event[keyPath: id])
        }
    }
}

private extension TaskEvent {
    var runIDForThreadProjection: UUID? { run?.id }
}

private struct TaskThreadSnapshotWindow {
    private static let defaultMaxRuns = 50
    private static let maxEvents = 1_200

    let events: [TaskEvent]
    let runs: [TaskRun]
    let totalEventCount: Int
    let omittedEventCount: Int
    let totalRunCount: Int
    let omittedRunCount: Int

    init(events allEvents: [TaskEvent], runs allRuns: [TaskRun], maxRuns: Int = defaultMaxRuns) {
        let start = DispatchTime.now().uptimeNanoseconds
        totalEventCount = allEvents.count
        totalRunCount = allRuns.count

        let sortedRuns = allRuns.sorted { $0.startedAt < $1.startedAt }
        runs = Array(sortedRuns.suffix(maxRuns))
        let keptRunIDs = Set(runs.map(\.id))

        let sortedEvents = allEvents.sorted { $0.timestamp < $1.timestamp }
        let runFilteredEvents = sortedEvents.filter { event in
            guard let runID = event.run?.id else { return true }
            return keptRunIDs.contains(runID)
        }
        let cappedToolResults = TaskThreadEventProjectionPolicy.capToolResults(
            runFilteredEvents,
            type: \TaskEvent.type,
            runID: \TaskEvent.runIDForThreadProjection,
            id: \TaskEvent.id
        )
        let displayEvents = Array(cappedToolResults.suffix(Self.maxEvents))
        // The transcript window is intentionally bounded, but protocol and
        // permission events also reconstruct durable per-run state. Keep the
        // latest state transition for each kept run even when it predates the
        // display window, so a long run does not lose its plan or permission
        // presentation merely because newer conversational events arrived.
        let stateEvents = Self.latestStateEvents(from: cappedToolResults)
        let displayEventIDs = Set(displayEvents.map(\.id))
        events = (displayEvents + stateEvents.filter { !displayEventIDs.contains($0.id) })
            .sorted { $0.timestamp < $1.timestamp }

        omittedEventCount = max(0, totalEventCount - events.count)
        omittedRunCount = max(0, totalRunCount - runs.count)
        PerformanceTelemetry.logIfNeeded(
            "thread_snapshot_window",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "event_count": PerformanceTelemetryFields.count(totalEventCount),
                "run_count": PerformanceTelemetryFields.count(totalRunCount),
                "snapshot_input_events": PerformanceTelemetryFields.count(events.count),
                "snapshot_input_runs": PerformanceTelemetryFields.count(runs.count),
                "omitted_events": PerformanceTelemetryFields.count(omittedEventCount),
                "omitted_runs": PerformanceTelemetryFields.count(omittedRunCount),
                "max_runs": PerformanceTelemetryFields.count(maxRuns)
            ]
        )
    }

    private static func latestStateEvents(from events: [TaskEvent]) -> [TaskEvent] {
        var latestEvents: [StateEventKey: TaskEvent] = [:]
        for event in events where isStateEvent(event) {
            latestEvents[StateEventKey(event: event)] = event
        }
        return Array(latestEvents.values)
    }

    private static func isStateEvent(_ event: TaskEvent) -> Bool {
        TaskThreadStateEventPolicy.contains(event.type)
    }

    private struct StateEventKey: Hashable {
        let runID: UUID?
        let type: String

        init(event: TaskEvent) {
            runID = event.run?.id
            type = event.type
        }
    }
}

struct TaskToolSummary: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int

    var id: String { name }
}

enum TaskToolDetailKind: String, Hashable, Sendable {
    case command
    case path
    case url
    case summary
    case none
}

struct TaskToolCall: Identifiable, Hashable, Sendable {
    let id: UUID
    let toolName: String
    let detail: String?
    let detailKind: TaskToolDetailKind
    let rawPayload: String

    init(id: UUID = UUID(), payload: String) {
        self.id = id
        rawPayload = payload

        let parsed = Self.parse(payload)
        toolName = parsed.toolName
        detail = parsed.detail
        detailKind = parsed.detailKind
    }

    private static func parse(_ payload: String) -> (toolName: String, detail: String?, detailKind: TaskToolDetailKind) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Unknown tool", nil, .none)
        }

        if trimmed == "Running validation tests..." {
            return ("Validation tests", nil, .none)
        }

        if trimmed == "Running AI self-check..." {
            return ("AI self-check", nil, .none)
        }

        if trimmed.hasPrefix("Isolation:") {
            let detail = trimmed
                .dropFirst("Isolation:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ("Workspace isolation", detail.isEmpty ? nil : detail, .summary)
        }

        if trimmed.hasPrefix("Using tool:") {
            let remainder = trimmed
                .dropFirst("Using tool:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else {
                return ("Unknown tool", nil, .none)
            }
            guard let separator = remainder.firstIndex(of: ":") else {
                return (remainder, nil, .none)
            }

            let name = remainder[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = remainder[remainder.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.isEmpty ? "Unknown tool" : name
            return (resolvedName, detail.isEmpty ? nil : detail, detailKind(for: resolvedName, detail: detail))
        }

        if trimmed.hasPrefix("Using ") {
            let name = trimmed
                .dropFirst("Using ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return (name, nil, .none)
            }
        }

        return (trimmed, nil, .none)
    }

    private static func detailKind(for toolName: String, detail: String) -> TaskToolDetailKind {
        guard !detail.isEmpty else { return .none }
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bash", "shell":
            return .command
        case "read", "write", "edit", "multiedit":
            return .path
        case "webfetch", "websearch":
            return .url
        default:
            return .summary
        }
    }
}

struct TaskToolResult: Identifiable, Hashable, Sendable {
    let id: UUID
    let payload: String
}

struct TaskRunNotice: Identifiable, Hashable, Sendable {
    let id: UUID
    let type: String
    let payload: String
}

struct TaskRunProgressMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String
    let timestamp: Date
}

struct TaskRunOutputPresentation: Hashable, Sendable {
    private static let maximumFinalAnswerPresentationBytes = 262_144
    let displayText: String
    let progressMessages: [TaskRunProgressMessage]
    let rawText: String

    static let empty = TaskRunOutputPresentation(displayText: "", progressMessages: [], rawText: "")

    init(displayText: String, progressMessages: [TaskRunProgressMessage], rawText: String) {
        self.displayText = displayText
        self.progressMessages = progressMessages
        self.rawText = rawText
    }

    var hasDisplayText: Bool {
        !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        run: TaskRunSnapshot,
        events: [TaskEventSnapshot],
        cancellationCheck: () throws -> Void = {}
    ) rethrows {
        try cancellationCheck()
        rawText = run.output

        var responseEvents: [TaskEventSnapshot] = []
        for (index, event) in events.enumerated() {
            if index.isMultiple(of: 16) { try cancellationCheck() }
            if event.type == "agent.response" &&
                !event.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                responseEvents.append(event)
            }
        }

        if run.status == .running {
            displayText = ""
            progressMessages = Self.progressMessages(from: responseEvents)
            return
        }

        var latestWorkIndex: Int?
        for index in events.indices.reversed() {
            if index.isMultiple(of: 16) { try cancellationCheck() }
            if Self.isOutputBoundaryEvent(events[index]) {
                latestWorkIndex = index
                break
            }
        }
        guard let latestWorkIndex else {
            let presentation = Self.rawOutputPresentation(for: run)
            displayText = presentation.displayText
            progressMessages = presentation.progressMessages
            return
        }

        var finalResponseEvents: [TaskEventSnapshot] = []
        for (offset, event) in events.dropFirst(latestWorkIndex + 1).enumerated() {
            if offset.isMultiple(of: 16) { try cancellationCheck() }
            if event.type == "agent.response" &&
                !event.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalResponseEvents.append(event)
            }
        }

        guard !finalResponseEvents.isEmpty else {
            let presentation = Self.rawOutputPresentation(for: run)
            displayText = presentation.displayText
            progressMessages = presentation.progressMessages
            return
        }

        if try Self.exceedsFinalAnswerPresentationLimit(
            finalResponseEvents,
            cancellationCheck: cancellationCheck
        ) {
            displayText = "This run produced a very large final response. Open Diagnostics for the raw output."
            let finalIDs = Set(finalResponseEvents.map(\.id))
            progressMessages = Self.progressMessages(from: responseEvents.filter { !finalIDs.contains($0.id) })
            return
        }

        try cancellationCheck()
        let finalText = Self.joinResponsePayloads(finalResponseEvents)
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let presentation = Self.rawOutputPresentation(for: run)
            displayText = presentation.displayText
            progressMessages = presentation.progressMessages
            return
        }

        try cancellationCheck()
        displayText = TaskRunAnswerPresentationPolicy.presentation(rawText: finalText).answerText
        let finalIDs = Set(finalResponseEvents.map(\.id))
        progressMessages = Self.progressMessages(from: responseEvents.filter { !finalIDs.contains($0.id) })
        try cancellationCheck()
    }

    private static func isOutputBoundaryEvent(_ event: TaskEventSnapshot) -> Bool {
        switch event.type {
        case "tool.use", "tool.result", "permission.denied", "permission.approval.requested":
            return true
        default:
            return false
        }
    }

    private static func rawOutputPresentation(for run: TaskRunSnapshot) -> TaskRunOutputPresentation {
        guard run.output.utf8.count <= maximumFinalAnswerPresentationBytes else {
            return TaskRunOutputPresentation(
                displayText: "This run produced very large raw output. Open Diagnostics for the full output.",
                progressMessages: [], rawText: run.output
            )
        }
        let presentation = TaskRunAnswerPresentationPolicy.presentation(rawText: run.output)
        return TaskRunOutputPresentation(
            displayText: presentation.answerText,
            progressMessages: progressMessages(from: presentation.progressMessages, run: run),
            rawText: run.output
        )
    }

    private static func progressMessages(from events: [TaskEventSnapshot]) -> [TaskRunProgressMessage] {
        var previousKey: String?
        return events.compactMap { event -> TaskRunProgressMessage? in
            guard let progress = TaskRunAnswerPresentationPolicy.normalizedProgressText(event.payload),
                  progress.comparisonKey != previousKey else {
                return nil
            }
            previousKey = progress.comparisonKey
            return TaskRunProgressMessage(
                id: event.id,
                text: progress.text,
                timestamp: event.timestamp
            )
        }
    }

    private static func progressMessages(from texts: [String], run: TaskRunSnapshot) -> [TaskRunProgressMessage] {
        let timestamp = run.completedAt ?? run.startedAt
        return texts.enumerated().map { index, text in
            TaskRunProgressMessage(
                id: derivedProgressMessageID(runID: run.id, index: index),
                text: text,
                timestamp: timestamp
            )
        }
    }

    private static func derivedProgressMessageID(runID: UUID, index: Int) -> UUID {
        let source = runID.uuidString.replacingOccurrences(of: "-", with: "")
        let suffix = String(format: "%012llx", CUnsignedLongLong(index))
        let hex = String(source.prefix(20)) + suffix
        let chunks = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ]
        return UUID(uuidString: chunks.joined(separator: "-")) ?? UUID()
    }

    private static func joinResponsePayloads(_ events: [TaskEventSnapshot]) -> String {
        TaskRunAnswerPresentationPolicy.joinedResponsePayloads(events.map(\.payload))
    }

    private static func exceedsFinalAnswerPresentationLimit(
        _ events: [TaskEventSnapshot],
        cancellationCheck: () throws -> Void
    ) rethrows -> Bool {
        var byteCount = 0
        for event in events {
            var start = event.payload.startIndex
            while start < event.payload.endIndex {
                try cancellationCheck()
                let end = event.payload.index(
                    start,
                    offsetBy: 16_384,
                    limitedBy: event.payload.endIndex
                ) ?? event.payload.endIndex
                byteCount += event.payload[start..<end].utf8.count
                if byteCount > maximumFinalAnswerPresentationBytes { return true }
                start = end
            }
        }
        return false
    }
}

struct TaskRunActivity: Sendable {
    let tools: [TaskToolSummary]
    let toolCalls: [TaskToolCall]
    let toolResults: [TaskToolResult]
    let notices: [TaskRunNotice]
    let fileChanges: [StoredFileChange]
    let hasOmittedFileChanges: Bool
    let permissionManifest: RunPermissionManifest?

    static let empty = TaskRunActivity(tools: [], toolCalls: [], toolResults: [], notices: [], fileChanges: [], hasOmittedFileChanges: false, permissionManifest: nil)

    var hasVisibleActivity: Bool {
        !tools.isEmpty || !toolResults.isEmpty || !notices.isEmpty || !fileChanges.isEmpty || hasOmittedFileChanges || permissionManifest != nil
    }
}

struct TaskProtocolTodoItem: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let status: AstraRunProtocolEvent.TodoStatus

    var isDone: Bool { status == .done }
}

struct TaskRunProtocolState: Equatable, Sendable {
    var todoItems: [TaskProtocolTodoItem] = []
    var completionSummary: String?
    var verifiedBy: String?
    var invalidEventCount = 0

    static let empty = TaskRunProtocolState()

    var hasCompletion: Bool {
        completionSummary?.isEmpty == false
    }
}

struct TaskThreadSnapshot: Sendable {
    let sortedEvents: [TaskEventSnapshot]
    let sortedRuns: [TaskRunSnapshot]
    let latestRun: TaskRunSnapshot?
    let conversationItems: [TaskConversationItem]
    let latestAgentPlanItems: [TaskProtocolTodoItem]
    let totalEventCount: Int
    let omittedEventCount: Int
    let totalRunCount: Int
    let omittedRunCount: Int
    /// Transcript shape computed while building the snapshot, so task-open
    /// readiness logging never rescans user-visible content on the main actor.
    let transcriptMetrics: TaskThreadTranscriptMetrics

    private let activityByRunID: [UUID: TaskRunActivity]
    private let protocolByRunID: [UUID: TaskRunProtocolState]
    private let outputPresentationByRunID: [UUID: TaskRunOutputPresentation]
    private let activityPresentationByRunID: [UUID: RunActivityPresentation]

    static let empty = TaskThreadSnapshot(
        goal: "",
        createdAt: Date(timeIntervalSince1970: 0),
        events: [TaskEventSnapshot](),
        runs: [TaskRunSnapshot]()
    )

    static func placeholder(goal: String, createdAt: Date) -> TaskThreadSnapshot {
        TaskThreadSnapshot(
            goal: goal,
            createdAt: createdAt,
            events: [TaskEventSnapshot](),
            runs: [TaskRunSnapshot]()
        )
    }

    static func buildAsync(
        input: TaskThreadSnapshotInput,
        fields: [String: String],
        responsivenessContext: TaskThreadResponsivenessContext? = nil
    ) async throws -> TaskThreadSnapshot {
        try await TaskThreadSnapshotBuildExecutor.testingShared.build(
            input: input,
            fields: fields,
            responsivenessContext: responsivenessContext,
            admittedAt: DispatchTime.now().uptimeNanoseconds
        )
    }

    static func resetBuildConcurrencyStatsForTesting() async {
        await TaskThreadSnapshotBuildExecutor.testingShared.resetStats()
    }

    static func buildConcurrencyStatsForTesting() async -> (active: Int, maximum: Int, cancelled: Int) {
        await TaskThreadSnapshotBuildExecutor.testingShared.stats
    }

    init(task: AgentTask) {
        self.init(input: TaskThreadSnapshotInput(task: task))
    }

    init(input: TaskThreadSnapshotInput) {
        try! self.init(
            goal: input.goal,
            createdAt: input.createdAt,
            events: input.events,
            runs: input.runs.map(TaskRunSnapshot.init),
            totalEventCount: input.totalEventCount,
            omittedEventCount: input.omittedEventCount,
            totalRunCount: input.totalRunCount,
            omittedRunCount: input.omittedRunCount,
            cancellationCheck: {}
        )
    }

    fileprivate init(cancellableInput input: TaskThreadSnapshotInput) throws {
        var runs: [TaskRunSnapshot] = []
        runs.reserveCapacity(input.runs.count)
        for run in input.runs {
            try Task.checkCancellation()
            runs.append(try TaskRunSnapshot(input: run, cancellationCheck: { try Task.checkCancellation() }))
        }
        try self.init(
            goal: input.goal,
            createdAt: input.createdAt,
            events: input.events,
            runs: runs,
            totalEventCount: input.totalEventCount,
            omittedEventCount: input.omittedEventCount,
            totalRunCount: input.totalRunCount,
            omittedRunCount: input.omittedRunCount,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    init(goal: String, createdAt: Date, events: [TaskEvent], runs: [TaskRun]) {
        self.init(input: TaskThreadSnapshotInput(
            goal: goal,
            createdAt: createdAt,
            events: events,
            runs: runs
        ))
    }

    init(
        goal: String,
        createdAt: Date,
        events: [TaskEventSnapshot],
        runs: [TaskRunSnapshot],
        totalEventCount: Int? = nil,
        omittedEventCount: Int = 0,
        totalRunCount: Int? = nil,
        omittedRunCount: Int = 0
    ) {
        try! self.init(
            goal: goal,
            createdAt: createdAt,
            events: events,
            runs: runs,
            totalEventCount: totalEventCount,
            omittedEventCount: omittedEventCount,
            totalRunCount: totalRunCount,
            omittedRunCount: omittedRunCount,
            cancellationCheck: {}
        )
    }

    init(
        goal: String,
        createdAt: Date,
        events: [TaskEventSnapshot],
        runs: [TaskRunSnapshot],
        totalEventCount: Int?,
        omittedEventCount: Int,
        totalRunCount: Int?,
        omittedRunCount: Int,
        cancellationCheck: () throws -> Void
    ) throws {
        try cancellationCheck()
        sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        sortedRuns = runs.sorted { $0.startedAt < $1.startedAt }
        try cancellationCheck()
        latestRun = sortedRuns.last
        self.totalEventCount = totalEventCount ?? events.count
        self.omittedEventCount = omittedEventCount
        self.totalRunCount = totalRunCount ?? runs.count
        self.omittedRunCount = omittedRunCount

        var toolsByRunID: [UUID: [TaskEventSnapshot]] = [:]
        var resultsByRunID: [UUID: [TaskToolResult]] = [:]
        var noticesByRunID: [UUID: [TaskRunNotice]] = [:]
        var permissionManifestByRunID: [UUID: RunPermissionManifest] = [:]
        var protocolStatesByRunID: [UUID: TaskRunProtocolState] = [:]
        var eventsByRunID: [UUID: [TaskEventSnapshot]] = [:]
        var latestPlanItems: [TaskProtocolTodoItem] = []

        for (eventIndex, event) in sortedEvents.enumerated() {
            if eventIndex.isMultiple(of: 32) { try cancellationCheck() }
            if let runID = event.runID {
                eventsByRunID[runID, default: []].append(event)
                switch event.type {
                case "tool.use":
                    toolsByRunID[runID, default: []].append(event)
                case "tool.result" where !event.payload.isEmpty:
                    resultsByRunID[runID, default: []].append(TaskToolResult(
                        id: event.id,
                        payload: event.payload
                    ))
                case "budget.warning", "budget.exceeded", "error", "permission.approval.requested", "astra.permission_summary":
                    noticesByRunID[runID, default: []].append(TaskRunNotice(
                        id: event.id,
                        type: event.type,
                        payload: event.payload
                    ))
                case "astra.permission_manifest":
                    if let data = event.payload.data(using: .utf8),
                       let manifest = try? JSONDecoder().decode(RunPermissionManifest.self, from: data) {
                        permissionManifestByRunID[runID] = manifest
                    }
                default:
                    break
                }
            }

            if let runID = event.runID {
                var state = protocolStatesByRunID[runID] ?? .empty
                switch event.type {
                case "astra.todo.replace":
                    if case .todoReplace(let items)? = AstraRunProtocolEvent.decodeNormalizedPayload(event.payload) {
                        let mapped = Self.protocolTodoItems(from: items, eventID: event.id)
                        state.todoItems = mapped
                        latestPlanItems = mapped
                    }
                case "astra.complete":
                    if case .complete(let summary, let verifiedBy)? = AstraRunProtocolEvent.decodeNormalizedPayload(event.payload) {
                        state.completionSummary = summary
                        state.verifiedBy = verifiedBy
                    }
                case "astra.protocol.invalid":
                    state.invalidEventCount += 1
                default:
                    break
                }
                protocolStatesByRunID[runID] = state
            }
        }

        var activity: [UUID: TaskRunActivity] = [:]
        try cancellationCheck()
        for (runIndex, run) in sortedRuns.enumerated() {
            if runIndex.isMultiple(of: 16) { try cancellationCheck() }
            let toolCalls = (toolsByRunID[run.id] ?? []).map {
                TaskToolCall(id: $0.id, payload: $0.payload)
            }
            activity[run.id] = TaskRunActivity(
                tools: Self.summarizeToolCalls(toolCalls),
                toolCalls: toolCalls,
                toolResults: resultsByRunID[run.id] ?? [],
                notices: noticesByRunID[run.id] ?? [],
                fileChanges: run.fileChanges,
                hasOmittedFileChanges: run.hasOmittedFileChanges,
                permissionManifest: permissionManifestByRunID[run.id]
            )
        }
        activityByRunID = activity
        protocolByRunID = protocolStatesByRunID
        latestAgentPlanItems = latestPlanItems
        var outputPresByRunID: [UUID: TaskRunOutputPresentation] = [:]
        for (runIndex, run) in sortedRuns.enumerated() {
            if runIndex.isMultiple(of: 16) { try cancellationCheck() }
            outputPresByRunID[run.id] = try TaskRunOutputPresentation(
                run: run,
                events: eventsByRunID[run.id] ?? [],
                cancellationCheck: cancellationCheck
            )
        }
        outputPresentationByRunID = outputPresByRunID

        var activityPresentations: [UUID: RunActivityPresentation] = [:]
        for (runIndex, run) in sortedRuns.enumerated() {
            if runIndex.isMultiple(of: 16) { try cancellationCheck() }
            let act = activity[run.id] ?? .empty
            let outputPres = outputPresByRunID[run.id] ?? .empty

            let displayNotices = run.hasVPNWarning ? act.notices.filter { $0.type != "error" } : act.notices
            let actionableNotices = displayNotices.filter { TaskRunNoticePresentationRules.shouldShowInline($0, for: run) }

            activityPresentations[run.id] = RunActivityPresentation(
                run: run,
                activity: act,
                notices: displayNotices,
                suppressedNoticeIDs: Set(actionableNotices.map(\.id)),
                progressMessages: outputPres.progressMessages
            )
        }
        activityPresentationByRunID = activityPresentations

        try cancellationCheck()
        conversationItems = try Self.makeConversationItems(
            goal: goal,
            createdAt: createdAt,
            events: sortedEvents,
            runs: sortedRuns,
            activityByRunID: activity,
            protocolByRunID: protocolStatesByRunID,
            cancellationCheck: cancellationCheck
        )
        transcriptMetrics = try TaskThreadTranscriptMetrics(items: conversationItems, cancellationCheck: cancellationCheck)
    }

    func activityPresentation(for run: TaskRunSnapshot) -> RunActivityPresentation {
        activityPresentationByRunID[run.id] ?? .empty
    }

    func activityPresentation(for run: TaskRun) -> RunActivityPresentation {
        activityPresentationByRunID[run.id] ?? .empty
    }

    func hasVisibleActivityDetails(for run: TaskRunSnapshot) -> Bool {
        activityPresentation(for: run).hasVisibleDetails(
            hasPlanItems: !protocolState(for: run).todoItems.isEmpty
        )
    }

    func activity(for run: TaskRunSnapshot) -> TaskRunActivity {
        activityByRunID[run.id] ?? .empty
    }

    func activity(for run: TaskRun) -> TaskRunActivity {
        activityByRunID[run.id] ?? .empty
    }

    func protocolState(for run: TaskRunSnapshot) -> TaskRunProtocolState {
        protocolByRunID[run.id] ?? .empty
    }

    func protocolState(for run: TaskRun) -> TaskRunProtocolState {
        protocolByRunID[run.id] ?? .empty
    }

    func outputPresentation(for run: TaskRunSnapshot) -> TaskRunOutputPresentation {
        outputPresentationByRunID[run.id] ?? .empty
    }

    private static func summarizeToolCalls(_ calls: [TaskToolCall]) -> [TaskToolSummary] {
        var seen: [String: Int] = [:]
        var order: [String] = []

        for call in calls {
            let name = call.toolName
            if seen[name] != nil {
                seen[name]! += 1
            } else {
                seen[name] = 1
                order.append(name)
            }
        }

        return order.map { TaskToolSummary(name: $0, count: seen[$0] ?? 0) }
    }

    private static func makeConversationItems(
        goal: String,
        createdAt: Date,
        events: [TaskEventSnapshot],
        runs: [TaskRunSnapshot],
        activityByRunID: [UUID: TaskRunActivity],
        protocolByRunID: [UUID: TaskRunProtocolState],
        cancellationCheck: () throws -> Void = {}
    ) throws -> [TaskConversationItem] {
        try cancellationCheck()
        let conversationEvents = events.filter(Self.isVisibleConversationEvent)
        // Plan-created tasks record the user's ask as a plan.user.message
        // event with the same text as the goal; synthesizing the goal bubble
        // on top of it would show the prompt twice.
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let planEchoesGoal = conversationEvents.contains {
            $0.type == TaskPlanConversationEventTypes.userMessage
                && $0.payload.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedGoal
        }
        var items: [TaskConversationItem] = planEchoesGoal
            ? []
            : [.userMessage(text: goal, timestamp: createdAt)]
        let visibleRuns = runs.filter {
            shouldShowAgentResponse(
                for: $0,
                activity: activityByRunID[$0.id] ?? .empty,
                protocolByRunID: protocolByRunID
            )
        }
        var nextRunIndex = 0

        func appendCompletedRuns(upTo timestamp: Date) {
            while nextRunIndex < visibleRuns.count {
                guard let completed = visibleRuns[nextRunIndex].completedAt,
                      completed <= timestamp else {
                    break
                }
                items.append(.agentResponse(run: visibleRuns[nextRunIndex]))
                nextRunIndex += 1
            }
        }

        for (eventIndex, event) in conversationEvents.enumerated() {
            if eventIndex.isMultiple(of: 32) { try cancellationCheck() }
            appendCompletedRuns(upTo: event.timestamp)

            switch event.type {
            case "user.message":
                items.append(.userMessage(text: event.payload, timestamp: event.timestamp))
            case "task.approved":
                items.append(.systemInfo(text: systemTimelineText(for: event), timestamp: event.timestamp, count: 1))
            case TaskPlanConversationEventTypes.userMessage:
                items.append(.planUserMessage(text: event.payload, timestamp: event.timestamp))
            case TaskPlanConversationEventTypes.assistantMessage:
                items.append(.planAssistantMessage(text: event.payload, timestamp: event.timestamp))
            case let type where visibleSystemTimelineEventTypes.contains(type):
                items.append(.systemInfo(text: systemTimelineText(for: event), timestamp: event.timestamp, count: 1))
            case "schedule.result":
                if isActionableScheduleResult(event.payload) {
                    items.append(.scheduleResult(text: event.payload, timestamp: event.timestamp))
                }
            case "system.info":
                if isVisibleSystemInfo(event.payload) {
                    items.append(.systemInfo(text: event.payload, timestamp: event.timestamp, count: 1))
                }
            case "recap.result":
                items.append(.recapResult(text: event.payload, timestamp: event.timestamp))
            default:
                break
            }
        }

        while nextRunIndex < visibleRuns.count {
            items.append(.agentResponse(run: visibleRuns[nextRunIndex]))
            nextRunIndex += 1
        }

        try cancellationCheck()
        return coalescedSystemTimelineItems(items)
    }

    /// One live approval narrates itself twice (the channel's "Live permission
    /// approved for X…" system.info plus the task.approved echo "Permission
    /// approved. Continuing."), and a run with several approvals repeats the
    /// pair each time. Collapse each echo into its richer neighbor and roll
    /// identical adjacent notices into a single item with a count, so system
    /// notes read as chat flow instead of a spam wall.
    static func coalescedSystemTimelineItems(_ items: [TaskConversationItem]) -> [TaskConversationItem] {
        var output: [TaskConversationItem] = []
        for item in items {
            guard case let .systemInfo(text, timestamp, count) = item,
                  case let .systemInfo(previousText, _, previousCount)? = output.last else {
                output.append(item)
                continue
            }

            if text == previousText {
                output[output.count - 1] = .systemInfo(text: previousText, timestamp: timestamp, count: previousCount + count)
                continue
            }
            if isGenericPermissionApprovalText(text), isLivePermissionApprovalText(previousText) {
                // The generic echo of the approval the previous line already narrates.
                continue
            }
            if isLivePermissionApprovalText(text), isGenericPermissionApprovalText(previousText), previousCount == 1 {
                output[output.count - 1] = .systemInfo(text: text, timestamp: timestamp, count: count)
                continue
            }
            output.append(item)
        }
        return output
    }

    private static func isLivePermissionApprovalText(_ text: String) -> Bool {
        text.hasPrefix("Live permission approved for")
    }

    private static func isGenericPermissionApprovalText(_ text: String) -> Bool {
        text == "Permission approved. Continuing." ||
            text == "Permission approved for this task. Continuing."
    }

    private static func isVisibleConversationEvent(_ event: TaskEventSnapshot) -> Bool {
        switch event.type {
        case "user.message":
            return !isBrokerRuntimePermissionResumePrompt(event.payload)
        case "agent.response",
             TaskPlanConversationEventTypes.userMessage,
             TaskPlanConversationEventTypes.assistantMessage,
             "recap.result":
            return true
        case "task.approved":
            return isRuntimePermissionApprovalEvent(event.payload)
        case "system.info":
            return isVisibleSystemInfo(event.payload)
        case "schedule.result":
            return isActionableScheduleResult(event.payload)
        case let type where visibleSystemTimelineEventTypes.contains(type):
            return true
        default:
            return false
        }
    }

    private static let visibleSystemTimelineEventTypes: Set<String> = [
        TaskPlanEventTypes.executionFailed
    ]

    private static func isVisibleSystemInfo(_ payload: String) -> Bool {
        let normalized = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let hiddenLifecycleMarkers = [
            "started working on:",
            "stream started",
            "approval granted",
            "plan approved",
            "plan execution started",
            "plan execution completed",
            "task moved back to draft"
        ]
        return !hiddenLifecycleMarkers.contains { normalized.contains($0) }
    }

    private static func isActionableScheduleResult(_ payload: String) -> Bool {
        let normalized = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.hasPrefix("failed") ||
            normalized.hasPrefix("could not") ||
            normalized.hasPrefix("invalid") ||
            normalized.contains(" error") ||
            normalized.contains(" failed")
    }

    private static func systemTimelineText(for event: TaskEventSnapshot) -> String {
        switch event.type {
        case "task.started":
            return event.payload.isEmpty ? "Task moved back to draft for editing." : event.payload
        case "task.approved":
            if isRuntimePermissionApprovalEvent(event.payload) {
                return event.payload.localizedCaseInsensitiveContains("similar") ||
                    event.payload.localizedCaseInsensitiveContains("task-scoped")
                    ? "Permission approved for this task. Continuing."
                    : "Permission approved. Continuing."
            }
            return "Approval granted."
        case TaskPlanEventTypes.approved:
            return "Plan approved."
        case TaskPlanEventTypes.cancelled:
            return "Plan cancelled."
        case TaskPlanEventTypes.executionStarted:
            return "Plan execution started."
        case TaskPlanEventTypes.executionCompleted:
            return "Plan execution completed."
        case TaskPlanEventTypes.executionFailed:
            return "Plan execution stopped."
        default:
            return event.payload
        }
    }

    private static func isRuntimePermissionApprovalEvent(_ payload: String) -> Bool {
        payload.localizedCaseInsensitiveContains("runtime permission approved")
    }

    private static func isBrokerRuntimePermissionResumePrompt(_ payload: String) -> Bool {
        let normalized = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("astra approved one-time runtime permission") ||
            normalized.hasPrefix("astra approved task-scoped runtime permission")
    }

    private static func shouldShowAgentResponse(
        for run: TaskRunSnapshot,
        activity: TaskRunActivity,
        protocolByRunID: [UUID: TaskRunProtocolState]
    ) -> Bool {
        !run.output.isEmpty
            || activity.hasVisibleActivity
            || protocolByRunID[run.id]?.hasCompletion == true
            || run.completedWithoutUserFacingResult
    }

    private static func protocolTodoItems(
        from items: [AstraRunProtocolEvent.TodoItem],
        eventID: UUID
    ) -> [TaskProtocolTodoItem] {
        items.enumerated().map { index, item in
            TaskProtocolTodoItem(
                id: "\(eventID.uuidString)-\(index)",
                text: item.text,
                status: item.status
            )
        }
    }
}

/// Serial off-main executor for transcript CPU work. Structured actor calls
/// inherit cancellation from the coordinator, while serialization prevents a
/// superseded streaming generation from overlapping its replacement.
actor TaskThreadSnapshotBuildExecutor {
    /// Direct builder tests share an executor so they can assert serialization.
    /// Production view models each own an instance; one window can never queue
    /// behind CPU work belonging to another window.
    static let testingShared = TaskThreadSnapshotBuildExecutor()
    private var activeBuildCount = 0
    private var maximumBuildCount = 0
    private var cancelledBuildCount = 0
#if DEBUG
    private let buildCheckpointForTesting: (@Sendable () -> Void)?

    init(buildCheckpointForTesting: (@Sendable () -> Void)? = nil) {
        self.buildCheckpointForTesting = buildCheckpointForTesting
    }
#else
    init() {}
#endif

    var stats: (active: Int, maximum: Int, cancelled: Int) {
        (activeBuildCount, maximumBuildCount, cancelledBuildCount)
    }

    func resetStats() {
        precondition(activeBuildCount == 0)
        maximumBuildCount = 0
        cancelledBuildCount = 0
    }

#if DEBUG
    /// Holds the actor synchronously so telemetry tests can prove that the
    /// admission metric still reports genuine executor contention.
    func occupyForTelemetryTesting(
        milliseconds: UInt64,
        started: @Sendable () -> Void
    ) {
        started()
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
    }
#endif

    func build(
        input: TaskThreadSnapshotInput,
        fields: [String: String],
        responsivenessContext: TaskThreadResponsivenessContext?,
        admittedAt: UInt64
    ) throws -> TaskThreadSnapshot {
        let admissionWait = PerformanceTelemetry.elapsedMilliseconds(since: admittedAt)
        let admissionFields = fields.merging([
            "admission_state": Task.isCancelled ? "cancelled" : "entered"
        ], uniquingKeysWith: { _, new in new })
        if let responsivenessContext {
            responsivenessContext.performWithCorrelationFields { correlationFields in
                PerformanceTelemetry.log(
                    "thread_snapshot_executor_admission_wait",
                    durationMilliseconds: admissionWait,
                    fields: admissionFields.merging(correlationFields, uniquingKeysWith: { _, new in new })
                )
                responsivenessContext.telemetryObserver?("thread_snapshot_executor_admission_wait", admissionWait)
            }
        }
        activeBuildCount += 1
        maximumBuildCount = max(maximumBuildCount, activeBuildCount)
        defer { activeBuildCount -= 1 }
        do {
#if DEBUG
            buildCheckpointForTesting?()
#endif
            try Task.checkCancellation()
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let snapshot = try PerformanceSignposts.buildThreadSnapshot {
                try TaskThreadSnapshot(cancellableInput: input)
            }
            let resultFields = fields.merging([
                "conversation_item_count": PerformanceTelemetryFields.count(snapshot.conversationItems.count),
                "snapshot_event_count": PerformanceTelemetryFields.count(snapshot.sortedEvents.count),
                "snapshot_run_count": PerformanceTelemetryFields.count(snapshot.sortedRuns.count)
            ], uniquingKeysWith: { _, new in new })
            if let responsivenessContext {
                responsivenessContext.performWithCorrelationFields { correlationFields in
                    PerformanceTelemetry.logIfNeeded(
                        "thread_snapshot_build",
                        start: startedAt,
                        thresholdMilliseconds: 8,
                        fields: resultFields.merging(correlationFields, uniquingKeysWith: { _, new in new })
                    )
                }
            } else {
                PerformanceTelemetry.logIfNeeded(
                    "thread_snapshot_build",
                    start: startedAt,
                    thresholdMilliseconds: 8,
                    fields: resultFields
                )
            }
            return snapshot
        } catch is CancellationError {
            cancelledBuildCount += 1
            throw CancellationError()
        }
    }
}

/// Privacy-safe transcript shape counts calculated off the main actor as part
/// of snapshot construction. The values never retain or emit transcript text.
struct TaskThreadTranscriptMetrics: Equatable, Sendable {
    let textBytes: Int
    let agentResponseCount: Int
    let codeFenceCount: Int
    let tableRowCount: Int

    init(items: [TaskConversationItem]) {
        try! self.init(items: items, cancellationCheck: {})
    }

    fileprivate init(items: [TaskConversationItem], cancellationCheck: () throws -> Void) throws {
        var textBytes = 0
        var agentResponseCount = 0
        var codeFenceCount = 0
        var tableRowCount = 0

        for (itemIndex, item) in items.enumerated() {
            if itemIndex.isMultiple(of: 16) { try cancellationCheck() }
            let text: String
            switch item {
            case .userMessage(let value, _), .planUserMessage(let value, _), .planAssistantMessage(let value, _), .scheduleResult(let value, _), .systemInfo(let value, _, _), .recapResult(let value, _):
                text = value
            case .agentResponse(let run):
                text = run.output
                agentResponseCount += 1
            }
            let scan = try Self.scan(text, cancellationCheck: cancellationCheck)
            textBytes += scan.bytes
            codeFenceCount += scan.codeFences
            tableRowCount += scan.tableRows
        }

        self.textBytes = textBytes
        self.agentResponseCount = agentResponseCount
        self.codeFenceCount = codeFenceCount
        self.tableRowCount = tableRowCount
    }

    private static func scan(
        _ text: String,
        cancellationCheck: () throws -> Void
    ) throws -> (bytes: Int, codeFences: Int, tableRows: Int) {
        var bytes = 0
        var codeFences = 0
        var consecutiveBackticks = 0
        var tableRows = 0
        var atLineStart = true
        for byte in text.utf8 {
            bytes += 1
            if bytes.isMultiple(of: 16_384) { try cancellationCheck() }
            if byte == 96 {
                consecutiveBackticks += 1
                if consecutiveBackticks == 3 {
                    codeFences += 1
                    consecutiveBackticks = 0
                }
            } else {
                consecutiveBackticks = 0
            }
            if atLineStart {
                if byte == 32 || byte == 9 { continue }
                if byte == 124 { tableRows += 1 }
                atLineStart = false
            }
            if byte == 10 { atLineStart = true }
        }
        return (bytes, codeFences, tableRows)
    }
}

struct TaskThreadSnapshotTrigger: Equatable {
    private static let liveOutputBucketSize = 1_024
    private static let highFrequencyEventTypes: Set<String> = ["agent.response", "agent.thinking"]

    let taskID: UUID
    let revision: Date
    private let usesDurableRevision: Bool
    let eventCount: Int
    let visibleEventCount: Int
    let runCount: Int
    let status: TaskStatus
    let latestRunID: UUID?
    let latestRunStatus: RunStatus?
    let latestRunOutputBucket: Int
    let latestRunOutputCount: Int

    init(task: AgentTask) {
        let start = DispatchTime.now().uptimeNanoseconds
        let events = task.events
        let runs = task.runs
        let latestRun = runs.max { $0.startedAt < $1.startedAt }
        taskID = task.id
        revision = task.updatedAt
        usesDurableRevision = false
        eventCount = events.count
        visibleEventCount = events.reduce(0) { count, event in
            Self.highFrequencyEventTypes.contains(event.type) ? count : count + 1
        }
        runCount = runs.count
        status = task.status
        latestRunID = latestRun?.id
        latestRunStatus = latestRun?.status
        latestRunOutputCount = latestRun?.output.utf8.count ?? 0
        latestRunOutputBucket = Self.outputBucket(for: latestRunOutputCount)
        PerformanceTelemetry.logIfNeeded(
            "thread_snapshot_trigger",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
                "event_count": PerformanceTelemetryFields.count(eventCount),
                "visible_event_count": PerformanceTelemetryFields.count(visibleEventCount),
                "run_count": PerformanceTelemetryFields.count(runCount),
                "status": status.rawValue,
                "latest_run_status": latestRunStatus?.rawValue ?? "none",
                "latest_run_output_bucket": PerformanceTelemetryFields.count(latestRunOutputBucket),
                "latest_run_output_bytes": PerformanceTelemetryFields.count(latestRunOutputCount),
                "latest_run_output_byte_bucket": PerformanceTelemetryFields.byteBucket(latestRunOutputCount)
            ]
        )
    }

    init(task: AgentTask, input: TaskThreadSnapshotInput) {
        let latestRun = input.runs.max { $0.startedAt < $1.startedAt }
        taskID = task.id
        revision = task.updatedAt
        usesDurableRevision = true
        eventCount = input.totalEventCount
        // Storage-backed refresh is already driven by the durable task revision
        // and typed insertion notifications. Avoid rescanning loaded events just
        // to manufacture a second invalidation signature.
        visibleEventCount = input.totalEventCount
        runCount = input.totalRunCount
        status = task.status
        latestRunID = latestRun?.id
        latestRunStatus = latestRun?.status
        latestRunOutputCount = latestRun?.output.utf8.count ?? 0
        latestRunOutputBucket = Self.outputBucket(for: latestRunOutputCount)
    }

    static func == (lhs: TaskThreadSnapshotTrigger, rhs: TaskThreadSnapshotTrigger) -> Bool {
        lhs.taskID == rhs.taskID &&
            (!lhs.usesDurableRevision && !rhs.usesDurableRevision || lhs.revision == rhs.revision) &&
            lhs.visibleEventCount == rhs.visibleEventCount &&
            lhs.runCount == rhs.runCount &&
            lhs.status == rhs.status &&
            lhs.latestRunID == rhs.latestRunID &&
            lhs.latestRunStatus == rhs.latestRunStatus &&
            lhs.latestRunOutputBucket == rhs.latestRunOutputBucket
    }

    private static func outputBucket(for byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return ((byteCount - 1) / liveOutputBucketSize) + 1
    }
}

/// Task-based liveness projection retained for non-transcript consumers. The
/// production task thread now uses typed change notifications and bounded
/// SwiftData pages instead of polling or rebuilding relationship-wide triggers.
/// Deliberately narrower than `TaskThreadViewModel.refreshSnapshot`'s inline
/// liveness check (`status == .running/.queued || latestRunStatus == .running`),
/// which also treats `.queued` as live — that's the right call for deciding
/// whether the *terminal snapshot cache* applies (a queued task's plan could
/// still change before its turn), but wrong for deciding whether to *poll*: a
/// task queued behind another run has no live output or events yet, so polling
/// it every tick is pure waste until an actual run starts.
///
/// Requires *both* `task.status == .running` *and* the latest run's status ==
/// `.running` — either alone is insufficient:
/// - `task.status` alone: `TaskQueue.continueSession` owns the continuation
///   admission transition to `.running`, but the worker creates the follow-up
///   run immediately after that. During that narrow launch handoff,
///   `task.status == .running` doesn't guarantee any run has started producing
///   events yet.
/// - run status alone: `AgentInteractivePermissionChannel` sets
///   `task.status = .pendingUser` for a permission prompt while leaving
///   `run.status == .running` until the user decides — the run is still
///   "open" but nothing is streaming while it waits on the user, so treating
///   that run status alone as live would poll a large history every tick for
///   as long as the prompt goes unanswered.
/// Both conditions together correctly exclude `.queued`, the launch handoff
/// before a run exists, and a pending-user permission pause, leaving all of
/// them on the cheap reactive path
/// (`TaskThreadChangeObserver.reactiveTriggerWhenNotLive`,
/// `UsageDashboardView`'s query-driven follow-up) until a run is actually
/// running.
enum TaskLiveness {
    static func isLive(task: AgentTask) -> Bool {
        task.status == .running
            && task.runs.max(by: { $0.startedAt < $1.startedAt })?.status == .running
    }
}

struct TaskThreadSnapshotCacheKey: Hashable, Sendable {
    let taskID: UUID
    let status: TaskStatus
    /// `updatedAt` is the durable task revision. Terminal cache hits must be
    /// O(1), so do not rebuild signatures across an entire event history here.
    let revision: Date
    let createdAt: Date
    let completedAt: Date?
    let maxRuns: Int

    init?(
        task: AgentTask,
        maxRuns: Int
    ) {
        guard Self.isCacheable(status: task.status) else { return nil }
        taskID = task.id
        status = task.status
        revision = task.updatedAt
        createdAt = task.createdAt
        completedAt = task.completedAt
        self.maxRuns = maxRuns
    }

    private static func isCacheable(status: TaskStatus) -> Bool {
        switch status {
        case .running, .queued:
            return false
        default:
            return true
        }
    }
}

struct TaskThreadSnapshotCache {
    struct Stats: Equatable {
        var hitCount = 0
        var missCount = 0
        var entryCount = 0
    }

    private let maxEntries: Int
    private var entries: [TaskThreadSnapshotCacheKey: TaskThreadSnapshot] = [:]
    private var recentKeys: [TaskThreadSnapshotCacheKey] = []
    private(set) var stats = Stats()

    init(maxEntries: Int = 12) {
        self.maxEntries = max(1, maxEntries)
    }

    mutating func snapshot(for key: TaskThreadSnapshotCacheKey) -> TaskThreadSnapshot? {
        guard let snapshot = entries[key] else {
            stats.missCount += 1
            return nil
        }
        stats.hitCount += 1
        markRecentlyUsed(key)
        return snapshot
    }

    mutating func store(_ snapshot: TaskThreadSnapshot, for key: TaskThreadSnapshotCacheKey) {
        entries[key] = snapshot
        markRecentlyUsed(key)
        trimIfNeeded()
        stats.entryCount = entries.count
    }

    mutating func removeAll() {
        entries.removeAll()
        recentKeys.removeAll()
        stats = Stats()
    }

    private mutating func markRecentlyUsed(_ key: TaskThreadSnapshotCacheKey) {
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
    }

    private mutating func trimIfNeeded() {
        while recentKeys.count > maxEntries {
            let evicted = recentKeys.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }
}

struct TaskGeneratedFilesTrigger: Equatable {
    let taskID: UUID
    let taskFolder: String
    let latestRunID: UUID?
    let latestRunFileChangesLength: Int
    let artifactSignature: [String]
    let status: TaskStatus

    init(task: AgentTask, latestRun: TaskRunSnapshot?) {
        taskID = task.id
        taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        latestRunID = latestRun?.id
        latestRunFileChangesLength = latestRun?.fileChangesJSONLength ?? 0
        artifactSignature = task.artifacts
            .map { "\($0.path)#\($0.version)#\($0.isStale)" }
            .sorted()
        status = task.status
    }
}
