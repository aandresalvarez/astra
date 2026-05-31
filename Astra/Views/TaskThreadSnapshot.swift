import Foundation
import ASTRACore

enum TaskConversationItem: Identifiable, Sendable {
    case userMessage(text: String, timestamp: Date)
    case agentResponse(run: TaskRunSnapshot)
    case planUserMessage(text: String, timestamp: Date)
    case planAssistantMessage(text: String, timestamp: Date)
    case scheduleResult(text: String, timestamp: Date)
    case systemInfo(text: String, timestamp: Date)
    case recapResult(text: String, timestamp: Date)

    var id: String {
        switch self {
        case .userMessage(_, let timestamp): return "user-\(timestamp.timeIntervalSince1970)"
        case .agentResponse(let run): return "agent-\(run.id)"
        case .planUserMessage(_, let timestamp): return "plan-user-\(timestamp.timeIntervalSince1970)"
        case .planAssistantMessage(_, let timestamp): return "plan-assistant-\(timestamp.timeIntervalSince1970)"
        case .scheduleResult(_, let timestamp): return "schedule-\(timestamp.timeIntervalSince1970)"
        case .systemInfo(_, let timestamp): return "system-\(timestamp.timeIntervalSince1970)"
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
    let stopReason: String

    var completedWithoutUserFacingResult: Bool {
        status == .completed &&
            output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            fileChanges.isEmpty
    }

    init(input: TaskRunSnapshotInput) {
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
        output = AstraRunProtocolDisplaySanitizer.clean(input.output)
        hasVPNWarning = Self.outputContainsVPNWarning(input.output)
        costUSD = input.costUSD
        fileChangesJSONLength = input.fileChangesJSON.count
        fileChanges = Self.decodeFileChanges(input.fileChangesJSON)
        stopReason = input.stopReason
    }

    private static func decodeFileChanges(_ json: String) -> [StoredFileChange] {
        guard let data = json.data(using: .utf8),
              let changes = try? JSONDecoder().decode([StoredFileChange].self, from: data) else {
            return []
        }
        return changes
    }

    private static func outputContainsVPNWarning(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return output.contains("VPC_SERVICE_CONTROLS") ||
            output.contains("SECURITY_POLICY_VIOLATED") ||
            output.contains("Request is prohibited by organization's policy") ||
            normalized.contains("vpcservicecontrolsuniqueidentifier") ||
            normalized.contains("request is prohibited by organization's policy") ||
            normalized.contains("security_policy_violated")
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

    init(task: AgentTask) {
        let window = TaskThreadSnapshotWindow(events: task.events, runs: task.runs)
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

    private init(
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

private struct TaskThreadSnapshotWindow {
    private static let maxRuns = 80
    private static let maxEvents = 1_200
    private static let maxToolResultsPerRun = 12
    private static let runlessToolResultID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let events: [TaskEvent]
    let runs: [TaskRun]
    let totalEventCount: Int
    let omittedEventCount: Int
    let totalRunCount: Int
    let omittedRunCount: Int

    init(events allEvents: [TaskEvent], runs allRuns: [TaskRun]) {
        totalEventCount = allEvents.count
        totalRunCount = allRuns.count

        let sortedRuns = allRuns.sorted { $0.startedAt < $1.startedAt }
        runs = Array(sortedRuns.suffix(Self.maxRuns))
        let keptRunIDs = Set(runs.map(\.id))

        let sortedEvents = allEvents.sorted { $0.timestamp < $1.timestamp }
        let runFilteredEvents = sortedEvents.filter { event in
            guard let runID = event.run?.id else { return true }
            return keptRunIDs.contains(runID)
        }
        let cappedToolResults = Self.capToolResults(runFilteredEvents)
        events = Array(cappedToolResults.suffix(Self.maxEvents))

        omittedEventCount = max(0, totalEventCount - events.count)
        omittedRunCount = max(0, totalRunCount - runs.count)
    }

    private static func capToolResults(_ events: [TaskEvent]) -> [TaskEvent] {
        var keptToolResultsByRunID: [UUID: Int] = [:]
        var keepEventIDs = Set<UUID>()

        for event in events.reversed() where event.type == "tool.result" {
            let runID = event.run?.id ?? runlessToolResultID
            let count = keptToolResultsByRunID[runID, default: 0]
            guard count < maxToolResultsPerRun else { continue }
            keptToolResultsByRunID[runID] = count + 1
            keepEventIDs.insert(event.id)
        }

        return events.filter { event in
            event.type != "tool.result" || keepEventIDs.contains(event.id)
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

    init(run: TaskRunSnapshot, events: [TaskEventSnapshot]) {
        rawText = run.output

        let responseEvents = events.filter { event in
            event.type == "agent.response" &&
                !event.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if run.status == .running {
            displayText = ""
            progressMessages = Self.progressMessages(from: responseEvents)
            return
        }

        guard let latestWorkIndex = events.lastIndex(where: Self.isOutputBoundaryEvent) else {
            displayText = run.output
            progressMessages = []
            return
        }

        let finalResponseEvents = events
            .dropFirst(latestWorkIndex + 1)
            .filter { event in
                event.type == "agent.response" &&
                    !event.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

        guard !finalResponseEvents.isEmpty else {
            displayText = run.output
            progressMessages = []
            return
        }

        let finalText = Self.joinResponsePayloads(finalResponseEvents)
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            displayText = run.output
            progressMessages = []
            return
        }

        displayText = finalText
        progressMessages = Self.progressMessages(from: responseEvents.filter { event in
            !finalResponseEvents.contains(where: { $0.id == event.id })
        })
    }

    private static func isOutputBoundaryEvent(_ event: TaskEventSnapshot) -> Bool {
        switch event.type {
        case "tool.use", "tool.result", "permission.denied", "permission.approval.requested":
            return true
        default:
            return false
        }
    }

    private static func progressMessages(from events: [TaskEventSnapshot]) -> [TaskRunProgressMessage] {
        events.map {
            TaskRunProgressMessage(
                id: $0.id,
                text: $0.payload.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: $0.timestamp
            )
        }
        .filter { !$0.text.isEmpty }
    }

    private static func joinResponsePayloads(_ events: [TaskEventSnapshot]) -> String {
        events.map(\.payload).joined()
    }
}

struct TaskRunActivity: Sendable {
    let tools: [TaskToolSummary]
    let toolCalls: [TaskToolCall]
    let toolResults: [TaskToolResult]
    let notices: [TaskRunNotice]
    let fileChanges: [StoredFileChange]
    let permissionManifest: RunPermissionManifest?

    static let empty = TaskRunActivity(tools: [], toolCalls: [], toolResults: [], notices: [], fileChanges: [], permissionManifest: nil)

    var hasVisibleActivity: Bool {
        !tools.isEmpty || !toolResults.isEmpty || !notices.isEmpty || !fileChanges.isEmpty || permissionManifest != nil
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

    private let activityByRunID: [UUID: TaskRunActivity]
    private let protocolByRunID: [UUID: TaskRunProtocolState]
    private let outputPresentationByRunID: [UUID: TaskRunOutputPresentation]

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
        fields: [String: String]
    ) async -> TaskThreadSnapshot {
        await Task.detached(priority: .userInitiated) {
            PerformanceTelemetry.measure(
                "thread_snapshot_build",
                thresholdMilliseconds: 8,
                fields: fields
            ) {
                PerformanceSignposts.buildThreadSnapshot {
                    TaskThreadSnapshot(input: input)
                }
            }
        }.value
    }

    init(task: AgentTask) {
        self.init(input: TaskThreadSnapshotInput(task: task))
    }

    init(input: TaskThreadSnapshotInput) {
        self.init(
            goal: input.goal,
            createdAt: input.createdAt,
            events: input.events,
            runs: input.runs.map(TaskRunSnapshot.init),
            totalEventCount: input.totalEventCount,
            omittedEventCount: input.omittedEventCount,
            totalRunCount: input.totalRunCount,
            omittedRunCount: input.omittedRunCount
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
        sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        sortedRuns = runs.sorted { $0.startedAt < $1.startedAt }
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

        for event in sortedEvents {
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
        for run in sortedRuns {
            let toolCalls = (toolsByRunID[run.id] ?? []).map {
                TaskToolCall(id: $0.id, payload: $0.payload)
            }
            activity[run.id] = TaskRunActivity(
                tools: Self.summarizeToolCalls(toolCalls),
                toolCalls: toolCalls,
                toolResults: resultsByRunID[run.id] ?? [],
                notices: noticesByRunID[run.id] ?? [],
                fileChanges: run.fileChanges,
                permissionManifest: permissionManifestByRunID[run.id]
            )
        }
        activityByRunID = activity
        protocolByRunID = protocolStatesByRunID
        latestAgentPlanItems = latestPlanItems
        outputPresentationByRunID = sortedRuns.reduce(into: [UUID: TaskRunOutputPresentation]()) { result, run in
            result[run.id] = TaskRunOutputPresentation(run: run, events: eventsByRunID[run.id] ?? [])
        }

        conversationItems = Self.makeConversationItems(
            goal: goal,
            createdAt: createdAt,
            events: sortedEvents,
            runs: sortedRuns,
            activityByRunID: activity,
            protocolByRunID: protocolStatesByRunID
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
        protocolByRunID: [UUID: TaskRunProtocolState]
    ) -> [TaskConversationItem] {
        var items: [TaskConversationItem] = [
            .userMessage(text: goal, timestamp: createdAt)
        ]
        let conversationEvents = events.filter(Self.isVisibleConversationEvent)
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

        for event in conversationEvents {
            appendCompletedRuns(upTo: event.timestamp)

            switch event.type {
            case "user.message":
                items.append(.userMessage(text: event.payload, timestamp: event.timestamp))
            case "task.approved":
                items.append(.systemInfo(text: systemTimelineText(for: event), timestamp: event.timestamp))
            case TaskPlanConversationEventTypes.userMessage:
                items.append(.planUserMessage(text: event.payload, timestamp: event.timestamp))
            case TaskPlanConversationEventTypes.assistantMessage:
                items.append(.planAssistantMessage(text: event.payload, timestamp: event.timestamp))
            case let type where visibleSystemTimelineEventTypes.contains(type):
                items.append(.systemInfo(text: systemTimelineText(for: event), timestamp: event.timestamp))
            case "schedule.result":
                if isActionableScheduleResult(event.payload) {
                    items.append(.scheduleResult(text: event.payload, timestamp: event.timestamp))
                }
            case "system.info":
                if isVisibleSystemInfo(event.payload) {
                    items.append(.systemInfo(text: event.payload, timestamp: event.timestamp))
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

        return items
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

struct TaskThreadSnapshotTrigger: Equatable {
    private static let liveOutputBucketSize = 1_024
    private static let highFrequencyEventTypes: Set<String> = ["agent.response", "agent.thinking"]

    let taskID: UUID
    let eventCount: Int
    let visibleEventCount: Int
    let runCount: Int
    let status: TaskStatus
    let latestRunID: UUID?
    let latestRunStatus: RunStatus?
    let latestRunOutputBucket: Int
    let latestRunOutputCount: Int

    init(task: AgentTask) {
        let events = task.events
        let latestRun = task.runs.max { $0.startedAt < $1.startedAt }
        taskID = task.id
        eventCount = events.count
        visibleEventCount = events.reduce(0) { count, event in
            Self.highFrequencyEventTypes.contains(event.type) ? count : count + 1
        }
        runCount = task.runs.count
        status = task.status
        latestRunID = latestRun?.id
        latestRunStatus = latestRun?.status
        latestRunOutputCount = latestRun?.output.count ?? 0
        latestRunOutputBucket = Self.outputBucket(for: latestRunOutputCount)
    }

    static func == (lhs: TaskThreadSnapshotTrigger, rhs: TaskThreadSnapshotTrigger) -> Bool {
        lhs.taskID == rhs.taskID &&
            lhs.visibleEventCount == rhs.visibleEventCount &&
            lhs.runCount == rhs.runCount &&
            lhs.status == rhs.status &&
            lhs.latestRunID == rhs.latestRunID &&
            lhs.latestRunStatus == rhs.latestRunStatus &&
            lhs.latestRunOutputBucket == rhs.latestRunOutputBucket
    }

    private static func outputBucket(for characterCount: Int) -> Int {
        guard characterCount > 0 else { return 0 }
        return ((characterCount - 1) / liveOutputBucketSize) + 1
    }
}

struct TaskGeneratedFilesTrigger: Equatable {
    let taskID: UUID
    let taskFolder: String
    let latestRunID: UUID?
    let latestRunFileChangesLength: Int
    let status: TaskStatus

    init(task: AgentTask, latestRun: TaskRunSnapshot?) {
        taskID = task.id
        taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        latestRunID = latestRun?.id
        latestRunFileChangesLength = latestRun?.fileChangesJSONLength ?? 0
        status = task.status
    }
}
