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
        var latestPlanItems: [TaskProtocolTodoItem] = []

        for event in sortedEvents {
            if let runID = event.runID {
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
        let conversationEvents = events.filter {
            $0.type == "user.message" ||
            $0.type == "agent.response" ||
            $0.type == TaskPlanConversationEventTypes.userMessage ||
            $0.type == TaskPlanConversationEventTypes.assistantMessage ||
            systemTimelineEventTypes.contains($0.type) ||
            $0.type == "schedule.result" ||
            $0.type == "system.info" ||
            $0.type == "recap.result"
        }
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
            case TaskPlanConversationEventTypes.userMessage:
                items.append(.planUserMessage(text: event.payload, timestamp: event.timestamp))
            case TaskPlanConversationEventTypes.assistantMessage:
                items.append(.planAssistantMessage(text: event.payload, timestamp: event.timestamp))
            case let type where systemTimelineEventTypes.contains(type):
                items.append(.systemInfo(text: systemTimelineText(for: event), timestamp: event.timestamp))
            case "schedule.result":
                items.append(.scheduleResult(text: event.payload, timestamp: event.timestamp))
            case "system.info":
                items.append(.systemInfo(text: event.payload, timestamp: event.timestamp))
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

    private static let systemTimelineEventTypes: Set<String> = [
        "task.started",
        "task.approved",
        TaskPlanEventTypes.approved,
        TaskPlanEventTypes.cancelled,
        TaskPlanEventTypes.executionStarted,
        TaskPlanEventTypes.executionCompleted,
        TaskPlanEventTypes.executionFailed
    ]

    private static func systemTimelineText(for event: TaskEventSnapshot) -> String {
        switch event.type {
        case "task.started":
            return event.payload.isEmpty ? "Task moved back to draft for editing." : event.payload
        case "task.approved":
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

    private static func shouldShowAgentResponse(
        for run: TaskRunSnapshot,
        activity: TaskRunActivity,
        protocolByRunID: [UUID: TaskRunProtocolState]
    ) -> Bool {
        !run.output.isEmpty
            || activity.hasVisibleActivity
            || protocolByRunID[run.id]?.hasCompletion == true
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

enum TaskGeneratedFileShelfDestination: Equatable {
    case browser
    case text
    case query

    var title: String {
        switch self {
        case .browser: "Open in Browser Shelf"
        case .text: "Open in Text Shelf"
        case .query: "Open in Query Shelf"
        }
    }

    var compactTitle: String {
        switch self {
        case .browser: "Browser"
        case .text: "Text"
        case .query: "Query"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: "globe"
        case .text: "doc.text"
        case .query: "cylinder.split.1x2"
        }
    }
}

enum TaskGeneratedFiles {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "qmd"]

    private static let textShelfExtensions: Set<String> = [
        "md", "markdown", "qmd", "txt", "text", "log",
        "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "xml", "plist",
        "swift", "py", "js", "jsx", "ts", "tsx", "css", "scss", "html", "htm",
        "sh", "bash", "zsh", "fish", "sql", "r", "rb", "go", "rs",
        "java", "kt", "kts", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm",
        "php", "pl", "lua", "env", "ini", "cfg", "conf"
    ]

    private static let textShelfFileNames: Set<String> = [
        ".env", ".gitignore", ".npmrc", ".zshrc", ".bashrc",
        "dockerfile", "makefile", "rakefile", "gemfile", "podfile",
        "readme", "license", "changelog"
    ]

    static func files(in folder: String, fileManager: FileManager = .default) -> [String] {
        guard !folder.isEmpty, fileManager.fileExists(atPath: folder) else { return [] }
        guard let enumerator = fileManager.enumerator(atPath: folder) else { return [] }

        var files: [String] = []
        while let rel = enumerator.nextObject() as? String {
            guard shouldDisplayTaskFolderFile(relativePath: rel) else { continue }
            let full = (folder as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: full, isDirectory: &isDir)
            if !isDir.boolValue {
                files.append(full)
            }
        }
        return files.sorted()
    }

    static func shouldDisplayTaskFolderFile(relativePath: String) -> Bool {
        let rel = relativePath.replacingOccurrences(of: "\\", with: "/")
        if rel == "session_history.md" || rel == "outputs" || rel.hasPrefix("outputs/") {
            return false
        }
        if rel == ".runtime-bin" || rel.hasPrefix(".runtime-bin/") {
            return false
        }
        return true
    }

    static func filesAsync(in folder: String) async -> [String] {
        await Task.detached(priority: .utility) {
            files(in: folder)
        }.value
    }

    static func markdownFiles(inInputs inputs: [String], fileManager: FileManager = .default) -> [String] {
        previewableFiles(inInputs: inputs, fileManager: fileManager, matches: isMarkdownFile)
    }

    static func sqlFiles(inInputs inputs: [String], fileManager: FileManager = .default) -> [String] {
        previewableFiles(inInputs: inputs, fileManager: fileManager, matches: isSQLFile)
    }

    private static func previewableFiles(
        inInputs inputs: [String],
        fileManager: FileManager,
        matches: (String) -> Bool
    ) -> [String] {
        var paths: [String] = []
        var seen: Set<String> = []

        for input in inputs {
            let path = (input as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }

            let candidates: [String]
            if isDirectory.boolValue {
                candidates = files(in: path, fileManager: fileManager).filter(matches)
            } else if matches(path) {
                candidates = [path]
            } else {
                candidates = []
            }

            for candidate in candidates where !seen.contains(candidate) {
                seen.insert(candidate)
                paths.append(candidate)
            }
        }

        return paths.sorted()
    }

    static func preferredHTMLFile(in paths: [String], taskFolder: String = "") -> String? {
        paths
            .filter(isHTMLFile)
            .sorted { lhs, rhs in
                htmlPreviewScore(for: lhs, taskFolder: taskFolder) < htmlPreviewScore(for: rhs, taskFolder: taskFolder)
            }
            .first
    }

    static func preferredMarkdownFile(in paths: [String], taskFolder: String = "") -> String? {
        paths
            .filter(isMarkdownFile)
            .sorted { lhs, rhs in
                markdownPreviewScore(for: lhs, taskFolder: taskFolder) < markdownPreviewScore(for: rhs, taskFolder: taskFolder)
            }
            .first
    }

    static func preferredSQLFile(in paths: [String], taskFolder: String = "") -> String? {
        paths
            .filter(isSQLFile)
            .sorted { lhs, rhs in
                markdownPreviewScore(for: lhs, taskFolder: taskFolder) < markdownPreviewScore(for: rhs, taskFolder: taskFolder)
            }
            .first
    }

    static func isHTMLFile(_ path: String) -> Bool {
        ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isMarkdownFile(_ path: String) -> Bool {
        markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isSQLFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "sql"
    }

    static func isTextShelfFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        return textShelfExtensions.contains(ext)
            || textShelfFileNames.contains(name)
            || name.hasPrefix(".env.")
    }

    static func shelfDestination(for path: String) -> TaskGeneratedFileShelfDestination? {
        if isHTMLFile(path) { return .browser }
        if isSQLFile(path) { return .query }
        if isTextShelfFile(path) { return .text }
        return nil
    }

    static func shouldAutoLoadHTMLPreview(currentBrowserURL: String, targetPath: String) -> Bool {
        let trimmed = currentBrowserURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != "about:blank" else {
            return true
        }

        guard let currentURL = URL(string: trimmed),
              currentURL.isFileURL else {
            return false
        }

        return currentURL.standardizedFileURL.path == URL(fileURLWithPath: targetPath).standardizedFileURL.path
    }

    static func htmlPreviewSignature(
        for path: String,
        taskID: UUID,
        fileManager: FileManager = .default
    ) -> String {
        previewSignature(for: path, taskID: taskID, fileManager: fileManager)
    }

    static func markdownPreviewSignature(
        for path: String,
        taskID: UUID,
        fileManager: FileManager = .default
    ) -> String {
        previewSignature(for: path, taskID: taskID, fileManager: fileManager)
    }

    private static func previewSignature(
        for path: String,
        taskID: UUID,
        fileManager: FileManager
    ) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = attributes?[.size] as? Int64 ?? 0
        return "\(taskID.uuidString)|\(path)|\(modifiedAt)|\(size)"
    }

    private static func htmlPreviewScore(for path: String, taskFolder: String) -> HTMLPreviewScore {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let relativePath = relativePath(for: path, taskFolder: taskFolder)
        return HTMLPreviewScore(
            namePriority: name == "index.html" || name == "index.htm" ? 0 : 1,
            depth: relativePath.split(separator: "/").count,
            relativePath: relativePath.lowercased()
        )
    }

    private static func markdownPreviewScore(for path: String, taskFolder: String) -> MarkdownPreviewScore {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let relativePath = relativePath(for: path, taskFolder: taskFolder)
        return MarkdownPreviewScore(
            namePriority: markdownNamePriority(name),
            depth: relativePath.split(separator: "/").count,
            relativePath: relativePath.lowercased()
        )
    }

    private static func markdownNamePriority(_ name: String) -> Int {
        switch name {
        case "readme.md", "readme.markdown", "index.md", "index.markdown":
            0
        default:
            1
        }
    }

    private static func relativePath(for path: String, taskFolder: String) -> String {
        guard !taskFolder.isEmpty else { return path }
        let prefix = taskFolder.hasSuffix("/") ? taskFolder : "\(taskFolder)/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    private struct HTMLPreviewScore: Comparable {
        let namePriority: Int
        let depth: Int
        let relativePath: String

        static func < (lhs: HTMLPreviewScore, rhs: HTMLPreviewScore) -> Bool {
            if lhs.namePriority != rhs.namePriority {
                return lhs.namePriority < rhs.namePriority
            }
            if lhs.depth != rhs.depth {
                return lhs.depth < rhs.depth
            }
            return lhs.relativePath < rhs.relativePath
        }
    }

    private struct MarkdownPreviewScore: Comparable {
        let namePriority: Int
        let depth: Int
        let relativePath: String

        static func < (lhs: MarkdownPreviewScore, rhs: MarkdownPreviewScore) -> Bool {
            if lhs.namePriority != rhs.namePriority {
                return lhs.namePriority < rhs.namePriority
            }
            if lhs.depth != rhs.depth {
                return lhs.depth < rhs.depth
            }
            return lhs.relativePath < rhs.relativePath
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
