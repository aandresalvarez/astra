import Foundation
import ASTRACore

enum TaskConversationItem: Identifiable {
    case userMessage(text: String, timestamp: Date)
    case agentResponse(run: TaskRun)
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

struct TaskToolSummary: Identifiable, Hashable {
    let name: String
    let count: Int

    var id: String { name }
}

struct TaskRunActivity {
    let tools: [TaskToolSummary]
    let toolResults: [TaskEvent]
    let fileChanges: [StoredFileChange]

    static let empty = TaskRunActivity(tools: [], toolResults: [], fileChanges: [])
}

struct TaskProtocolTodoItem: Identifiable, Hashable {
    let id: String
    let text: String
    let status: AstraRunProtocolEvent.TodoStatus

    var isDone: Bool { status == .done }
}

struct TaskRunProtocolState: Equatable {
    var todoItems: [TaskProtocolTodoItem] = []
    var completionSummary: String?
    var verifiedBy: String?
    var invalidEventCount = 0

    static let empty = TaskRunProtocolState()

    var hasCompletion: Bool {
        completionSummary?.isEmpty == false
    }
}

struct TaskThreadSnapshot {
    let sortedEvents: [TaskEvent]
    let sortedRuns: [TaskRun]
    let latestRun: TaskRun?
    let conversationItems: [TaskConversationItem]
    let latestAgentPlanItems: [TaskProtocolTodoItem]

    private let activityByRunID: [UUID: TaskRunActivity]
    private let protocolByRunID: [UUID: TaskRunProtocolState]

    static let empty = TaskThreadSnapshot(
        goal: "",
        createdAt: Date(timeIntervalSince1970: 0),
        events: [],
        runs: []
    )

    init(task: AgentTask) {
        self.init(
            goal: task.goal,
            createdAt: task.createdAt,
            events: task.events,
            runs: task.runs
        )
    }

    init(goal: String, createdAt: Date, events: [TaskEvent], runs: [TaskRun]) {
        sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        sortedRuns = runs.sorted { $0.startedAt < $1.startedAt }
        latestRun = sortedRuns.max { $0.startedAt < $1.startedAt }

        var toolsByRunID: [UUID: [TaskEvent]] = [:]
        var resultsByRunID: [UUID: [TaskEvent]] = [:]
        var protocolStatesByRunID: [UUID: TaskRunProtocolState] = [:]
        var latestPlanItems: [TaskProtocolTodoItem] = []

        for event in sortedEvents {
            if let runID = event.run?.id {
                switch event.type {
                case "tool.use":
                    toolsByRunID[runID, default: []].append(event)
                case "tool.result" where !event.payload.isEmpty:
                    resultsByRunID[runID, default: []].append(event)
                default:
                    break
                }
            }

            if let runID = event.run?.id {
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
            protocolByRunID: protocolStatesByRunID
        )
    }

    func activity(for run: TaskRun) -> TaskRunActivity {
        activityByRunID[run.id] ?? .empty
    }

    func protocolState(for run: TaskRun) -> TaskRunProtocolState {
        protocolByRunID[run.id] ?? .empty
    }

    private static func summarizeToolEvents(_ events: [TaskEvent]) -> [TaskToolSummary] {
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
        events: [TaskEvent],
        runs: [TaskRun],
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
        var addedRunIDs = Set<UUID>()

        for event in conversationEvents {
            for run in runs where !addedRunIDs.contains(run.id) {
                if let completed = run.completedAt,
                   completed <= event.timestamp,
                   shouldShowAgentResponse(for: run, protocolByRunID: protocolByRunID) {
                    items.append(.agentResponse(run: run))
                    addedRunIDs.insert(run.id)
                }
            }

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

        for run in runs where !addedRunIDs.contains(run.id) && shouldShowAgentResponse(for: run, protocolByRunID: protocolByRunID) {
            items.append(.agentResponse(run: run))
        }

        return items
    }

    private static func shouldShowAgentResponse(
        for run: TaskRun,
        protocolByRunID: [UUID: TaskRunProtocolState]
    ) -> Bool {
        !run.output.isEmpty || protocolByRunID[run.id]?.hasCompletion == true
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

    init(task: AgentTask, latestRun: TaskRun?) {
        taskID = task.id
        taskFolder = task.taskFolder
        latestRunID = latestRun?.id
        latestRunFileChangesLength = latestRun?.fileChangesJSON.count ?? 0
        status = task.status
    }
}
