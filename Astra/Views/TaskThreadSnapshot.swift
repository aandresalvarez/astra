import Foundation
import ASTRACore

enum TaskConversationItem: Identifiable, Sendable {
    case userMessage(text: String, timestamp: Date)
    case agentResponse(run: TaskRunSnapshot)
    case scheduleResult(text: String, timestamp: Date)
    case systemInfo(text: String, timestamp: Date)
    case recapResult(text: String, timestamp: Date)

    var id: String {
        switch self {
        case .userMessage(_, let timestamp): return "user-\(timestamp.timeIntervalSince1970)"
        case .agentResponse(let run): return "agent-\(run.id)"
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
        output = input.output
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

    init(task: AgentTask) {
        self.init(
            goal: task.goal,
            createdAt: task.createdAt,
            events: task.events.map(TaskEventSnapshot.init),
            runs: task.runs.map(TaskRunSnapshotInput.init)
        )
    }

    init(goal: String, createdAt: Date, events: [TaskEvent], runs: [TaskRun]) {
        self.init(
            goal: goal,
            createdAt: createdAt,
            events: events.map(TaskEventSnapshot.init),
            runs: runs.map(TaskRunSnapshotInput.init)
        )
    }

    private init(
        goal: String,
        createdAt: Date,
        events: [TaskEventSnapshot],
        runs: [TaskRunSnapshotInput]
    ) {
        self.goal = goal
        self.createdAt = createdAt
        self.events = events
        self.runs = runs
    }
}

struct TaskToolSummary: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int

    var id: String { name }
}

struct TaskToolResult: Identifiable, Hashable, Sendable {
    let id: UUID
    let payload: String
}

struct TaskRunActivity: Sendable {
    let tools: [TaskToolSummary]
    let toolResults: [TaskToolResult]
    let fileChanges: [StoredFileChange]

    static let empty = TaskRunActivity(tools: [], toolResults: [], fileChanges: [])

    var hasVisibleActivity: Bool {
        !tools.isEmpty || !toolResults.isEmpty || !fileChanges.isEmpty
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
                thresholdMilliseconds: 0,
                fields: fields
            ) {
                TaskThreadSnapshot(input: input)
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
            runs: input.runs.map(TaskRunSnapshot.init)
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

    init(goal: String, createdAt: Date, events: [TaskEventSnapshot], runs: [TaskRunSnapshot]) {
        sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        sortedRuns = runs.sorted { $0.startedAt < $1.startedAt }
        latestRun = sortedRuns.last

        var toolsByRunID: [UUID: [TaskEventSnapshot]] = [:]
        var resultsByRunID: [UUID: [TaskToolResult]] = [:]
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
            activity[run.id] = TaskRunActivity(
                tools: Self.summarizeToolEvents(toolsByRunID[run.id] ?? []),
                toolResults: resultsByRunID[run.id] ?? [],
                fileChanges: run.fileChanges
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

    private static func summarizeToolEvents(_ events: [TaskEventSnapshot]) -> [TaskToolSummary] {
        var seen: [String: Int] = [:]
        var order: [String] = []

        for event in events {
            let name = event.payload.replacingOccurrences(of: "Using tool: ", with: "")
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

enum TaskGeneratedFiles {
    static func files(in folder: String, fileManager: FileManager = .default) -> [String] {
        guard !folder.isEmpty, fileManager.fileExists(atPath: folder) else { return [] }
        guard let enumerator = fileManager.enumerator(atPath: folder) else { return [] }

        var files: [String] = []
        while let rel = enumerator.nextObject() as? String {
            if rel.hasPrefix("outputs/") || rel == "session_history.md" { continue }
            let full = (folder as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: full, isDirectory: &isDir)
            if !isDir.boolValue {
                files.append(full)
            }
        }
        return files.sorted()
    }

    static func filesAsync(in folder: String) async -> [String] {
        await Task.detached(priority: .utility) {
            files(in: folder)
        }.value
    }
}

struct TaskThreadSnapshotTrigger: Equatable {
    let taskID: UUID
    let eventCount: Int
    let runCount: Int
    let status: TaskStatus
    let updatedAt: Date

    init(task: AgentTask) {
        taskID = task.id
        eventCount = task.events.count
        runCount = task.runs.count
        status = task.status
        updatedAt = task.updatedAt
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
        taskFolder = task.taskFolder
        latestRunID = latestRun?.id
        latestRunFileChangesLength = latestRun?.fileChangesJSONLength ?? 0
        status = task.status
    }
}
