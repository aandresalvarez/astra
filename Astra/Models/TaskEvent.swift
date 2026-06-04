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
             "task.resumed", "task.approved", "task.dismissed", "task.checkpoint", "activity.compacted",
             "plan.created", "plan.updated", "plan.approved", "plan.cancelled",
             "plan.execution.started", "plan.execution.completed", "plan.execution.failed",
             "validation.contract.created", "validation.contract.updated",
             "validation.contract.passed", "validation.contract.failed", "validation.contract.override",
             "validation.behavior.started", "validation.behavior.passed",
             "validation.behavior.failed", "validation.behavior.evidence.attached",
             "deliverable.verification.passed", "deliverable.verification.review_needed",
             "deliverable.verification.failed",
             "verifier.started", "verifier.completed", "verifier.failed",
             "handoff.created", "handoff.updated", "handoff.missing",
             "corrective.step.created", "corrective.step.approved",
             "corrective.step.dismissed", "corrective.task.created",
             "resource.lock.requested", "resource.lock.waiting",
             "resource.lock.acquired", "resource.lock.released",
             "mission.action.approved", "mission.action.dismissed",
             "mission.action.retry_requested", "mission.action.correction_created",
             "mission.milestone.created", "mission.milestone.completed",
             "mission.checkpoint.created", "mission.audit_bundle.created",
             "role.profile.selected", "role.profile.changed":
            return "lifecycle"
        case "user.message", "agent.response", "agent.thinking",
             "plan.user.message", "plan.assistant.message":
            return "conversation"
        case "tool.use", "permission.denied",
             "plan.step.started", "plan.step.completed", "plan.step.blocked",
             "plan.step.skipped",
             "validation.assertion.defined", "validation.assertion.started",
             "validation.assertion.passed", "validation.assertion.failed",
             "validation.assertion.skipped", "validation.assertion.reviewed":
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
