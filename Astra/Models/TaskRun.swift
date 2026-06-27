import Foundation
import SwiftData
import ASTRACore

enum RunStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case timeout
    case budgetExceeded = "budget_exceeded"
}

@Model
final class TaskRun {
    var id: UUID
    var task: AgentTask?
    var status: RunStatus
    var startedAt: Date
    var completedAt: Date?
    var tokensUsed: Int
    var inputTokens: Int         // Input tokens for this run (context window usage)
    var outputTokens: Int        // Output tokens for this run
    var runtimeID: String?
    var providerSessionId: String?
    var providerVersion: String?
    var executionEnvironmentSnapshotJSON: String?
    var exitCode: Int?
    var output: String
    var costUSD: Double
    var fileChangesJSON: String  // JSON array of file changes
    var stopReason: String       // "completed", "failed", "max_turns_reached", "max_budget_reached", "timeout", "cancelled", "repetition_detected"

    init(task: AgentTask) {
        self.id = UUID()
        self.task = task
        self.status = .running
        self.startedAt = Date()
        self.tokensUsed = 0
        self.inputTokens = 0
        self.outputTokens = 0
        self.runtimeID = task.runtimeID
        self.providerSessionId = task.sessionId
        self.providerVersion = nil
        let snapshot = task.executionEnvironmentSnapshotJSON
            ?? ExecutionEnvironmentStore.encodeSnapshot(
                ExecutionEnvironmentStore.decode(task.workspace?.activeExecutionEnvironmentJSON)
            )
        self.executionEnvironmentSnapshotJSON = snapshot
        if task.executionEnvironmentSnapshotJSON == nil {
            task.executionEnvironmentSnapshotJSON = snapshot
        }
        self.output = ""
        self.costUSD = 0
        self.fileChangesJSON = "[]"
        self.stopReason = ""
    }

    /// Decoded file changes from JSON storage
    var fileChanges: [StoredFileChange] {
        switch fileChangesDecodeResult {
        case .success(let changes):
            return changes
        case .failure:
            return []
        }
    }

    var fileChangesDecodeResult: Result<[StoredFileChange], TaskRunFileChangesDecodeError> {
        if fileChangesJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success([])
        }
        guard let data = fileChangesJSON.data(using: .utf8) else {
            return .failure(.invalidUTF8)
        }
        do {
            return .success(try TaskEventPayloadCodec.makeDecoder().decode([StoredFileChange].self, from: data))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
    }

    func appendFileChange(_ change: StoredFileChange) {
        var changes = fileChanges
        changes.append(change.translated(using: ExecutionEnvironmentStore.decode(executionEnvironmentSnapshotJSON)))
        fileChangesJSON = TaskEvent.payloadString(changes, fallback: fileChangesJSON)
    }
}

enum TaskRunFileChangesDecodeError: Error, Equatable, CustomStringConvertible {
    case invalidUTF8
    case decodingFailed(String)

    var description: String {
        switch self {
        case .invalidUTF8:
            "Run file changes payload is not valid UTF-8."
        case .decodingFailed(let message):
            "Could not decode run file changes: \(message)"
        }
    }
}

/// Codable file change for JSON storage in TaskRun
struct StoredFileChange: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let path: String
    let changeType: String  // "Write" or "Edit"
    let content: String?
    let oldString: String?
    let newString: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        path: String,
        changeType: String,
        content: String?,
        oldString: String?,
        newString: String?,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.changeType = changeType
        self.content = content
        self.oldString = oldString
        self.newString = newString
        self.timestamp = timestamp
    }

    init(from fileChange: FileChange) {
        self.id = fileChange.id
        self.path = fileChange.path
        self.changeType = StoredFileChangeKind(changeType: fileChange.changeType.rawValue).rawValue
        self.content = fileChange.content
        self.oldString = fileChange.oldString
        self.newString = fileChange.newString
        self.timestamp = fileChange.timestamp
    }

    var kind: StoredFileChangeKind {
        StoredFileChangeKind(changeType: changeType)
    }

    func translated(using environment: WorkspaceExecutionEnvironment) -> StoredFileChange {
        guard environment.isContainerized else { return self }
        let mapper = ExecutionEnvironmentPathMapper(mounts: environment.mounts)
        guard let hostPath = mapper.hostPath(forContainerPath: path),
              hostPath != path else {
            return self
        }
        return StoredFileChange(
            id: id,
            path: hostPath,
            changeType: changeType,
            content: content,
            oldString: oldString,
            newString: newString,
            timestamp: timestamp
        )
    }
}

enum StoredFileChangeKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case write = "Write"
    case edit = "Edit"
    case discovered = "discovered"
    case unknown = "unknown"

    init(changeType: String) {
        switch changeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "write":
            self = .write
        case "edit":
            self = .edit
        case "discovered":
            self = .discovered
        default:
            self = .unknown
        }
    }

    var sourceLabel: String {
        switch self {
        case .write:
            "created"
        case .edit:
            "edited"
        case .discovered:
            "output"
        case .unknown:
            "changed"
        }
    }
}
