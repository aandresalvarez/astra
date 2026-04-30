import Foundation
import SwiftData
import ASTRACore

enum RunStatus: String, Codable {
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
        self.output = ""
        self.costUSD = 0
        self.fileChangesJSON = "[]"
        self.stopReason = ""
    }

    /// Decoded file changes from JSON storage
    var fileChanges: [StoredFileChange] {
        guard let data = fileChangesJSON.data(using: .utf8),
              let changes = try? JSONDecoder().decode([StoredFileChange].self, from: data) else {
            return []
        }
        return changes
    }

    func appendFileChange(_ change: StoredFileChange) {
        var changes = fileChanges
        changes.append(change)
        if let data = try? JSONEncoder().encode(changes),
           let json = String(data: data, encoding: .utf8) {
            fileChangesJSON = json
        }
    }
}

/// Codable file change for JSON storage in TaskRun
struct StoredFileChange: Codable, Identifiable, Hashable {
    let id: UUID
    let path: String
    let changeType: String  // "Write" or "Edit"
    let content: String?
    let oldString: String?
    let newString: String?
    let timestamp: Date

    init(from fileChange: FileChange) {
        self.id = fileChange.id
        self.path = fileChange.path
        self.changeType = fileChange.changeType.rawValue
        self.content = fileChange.content
        self.oldString = fileChange.oldString
        self.newString = fileChange.newString
        self.timestamp = fileChange.timestamp
    }
}
