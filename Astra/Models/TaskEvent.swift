import Foundation
import SwiftData

@Model
final class TaskEvent {
    var id: UUID
    var task: AgentTask?
    var run: TaskRun?
    var type: String
    var payload: String
    var timestamp: Date
    // Agent Teams identity
    var agentName: String?    // e.g. "pro-agent", nil = lead/orchestrator
    var agentId: String?      // e.g. "pro-agent@rest-api-debate"
    var teamName: String?     // e.g. "rest-api-debate"
    var category: String       // "lifecycle", "conversation", "tool", "system", "team"

    init(task: AgentTask, type: String, payload: String = "", run: TaskRun? = nil,
         agentName: String? = nil, agentId: String? = nil, teamName: String? = nil) {
        self.id = UUID()
        self.task = task
        self.run = run
        self.type = type
        self.payload = payload
        self.timestamp = Date()
        self.agentName = agentName
        self.agentId = agentId
        self.teamName = teamName
        self.category = Self.categoryFor(type: type)
    }

    static func categoryFor(type: String) -> String {
        switch type {
        case "task.started", "task.completed", "task.cancelled", "task.interrupted", "task.retried",
             "task.resumed", "task.approved", "task.dismissed", "activity.compacted",
             "plan.created", "plan.updated", "plan.approved", "plan.cancelled",
             "plan.execution.started", "plan.execution.completed", "plan.execution.failed":
            return "lifecycle"
        case "user.message", "agent.response", "agent.thinking",
             "plan.user.message", "plan.assistant.message":
            return "conversation"
        case "tool.use", "permission.denied",
             "plan.step.started", "plan.step.completed", "plan.step.blocked",
             "plan.step.skipped":
            return "tool"
        case "error", "budget.exceeded", "budget.warning", "task.stats", "task.chained":
            return "system"
        case let t where t.hasPrefix("astra."):
            return "system"
        case let t where t.hasPrefix("team."):
            return "team"
        default:
            return "system"
        }
    }
}
