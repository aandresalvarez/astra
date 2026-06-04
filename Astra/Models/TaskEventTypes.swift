import Foundation

enum TaskEventCategory: String, Codable, Sendable, Equatable, Hashable {
    case lifecycle
    case conversation
    case tool
    case system
    case team
}

struct TaskEventType: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    let rawValue: String

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    var category: TaskEventCategory {
        TaskEventTypes.category(for: self)
    }
}

enum TaskEventPayloadDecodeError: Error, Equatable, CustomStringConvertible {
    case typeMismatch(expected: String, actual: String)
    case invalidUTF8
    case decodingFailed(String)

    var description: String {
        switch self {
        case .typeMismatch(let expected, let actual):
            "Expected event type '\(expected)', got '\(actual)'."
        case .invalidUTF8:
            "Event payload is not valid UTF-8."
        case .decodingFailed(let message):
            "Could not decode event payload: \(message)"
        }
    }
}

enum TaskEventTypes {
    enum Task {
        static let started: TaskEventType = "task.started"
        static let completed: TaskEventType = "task.completed"
        static let cancelled: TaskEventType = "task.cancelled"
        static let interrupted: TaskEventType = "task.interrupted"
        static let retried: TaskEventType = "task.retried"
        static let resumed: TaskEventType = "task.resumed"
        static let approved: TaskEventType = "task.approved"
        static let dismissed: TaskEventType = "task.dismissed"
        static let checkpoint: TaskEventType = "task.checkpoint"
        static let stats: TaskEventType = "task.stats"
        static let chained: TaskEventType = "task.chained"
    }

    enum Conversation {
        static let userMessage: TaskEventType = "user.message"
        static let agentResponse: TaskEventType = "agent.response"
        static let agentThinking: TaskEventType = "agent.thinking"
        static let planUserMessage: TaskEventType = "plan.user.message"
        static let planAssistantMessage: TaskEventType = "plan.assistant.message"
    }

    enum Tool {
        static let use: TaskEventType = "tool.use"
        static let result: TaskEventType = "tool.result"
        static let permissionDenied: TaskEventType = "permission.denied"
        static let permissionApprovalRequested: TaskEventType = "permission.approval.requested"
        static let permissionGrantTask: TaskEventType = "permission.grant.task"
    }

    enum Budget {
        static let warning: TaskEventType = "budget.warning"
        static let exceeded: TaskEventType = "budget.exceeded"
    }

    enum Activity {
        static let compacted: TaskEventType = "activity.compacted"
    }

    enum Plan {
        static let created: TaskEventType = "plan.created"
        static let updated: TaskEventType = "plan.updated"
        static let approved: TaskEventType = "plan.approved"
        static let cancelled: TaskEventType = "plan.cancelled"
        static let executionStarted: TaskEventType = "plan.execution.started"
        static let executionCompleted: TaskEventType = "plan.execution.completed"
        static let executionFailed: TaskEventType = "plan.execution.failed"
        static let userMessage: TaskEventType = "plan.user.message"
        static let assistantMessage: TaskEventType = "plan.assistant.message"
        static let stepStarted: TaskEventType = "plan.step.started"
        static let stepCompleted: TaskEventType = "plan.step.completed"
        static let stepBlocked: TaskEventType = "plan.step.blocked"
        static let stepSkipped: TaskEventType = "plan.step.skipped"
    }

    enum Validation {
        static let contractCreated: TaskEventType = "validation.contract.created"
        static let contractUpdated: TaskEventType = "validation.contract.updated"
        static let contractPassed: TaskEventType = "validation.contract.passed"
        static let contractFailed: TaskEventType = "validation.contract.failed"
        static let contractOverridden: TaskEventType = "validation.contract.override"
        static let assertionDefined: TaskEventType = "validation.assertion.defined"
        static let assertionStarted: TaskEventType = "validation.assertion.started"
        static let assertionPassed: TaskEventType = "validation.assertion.passed"
        static let assertionFailed: TaskEventType = "validation.assertion.failed"
        static let assertionSkipped: TaskEventType = "validation.assertion.skipped"
        static let assertionReviewed: TaskEventType = "validation.assertion.reviewed"
        static let evidence: TaskEventType = "validation.evidence"
        static let behaviorStarted: TaskEventType = "validation.behavior.started"
        static let behaviorPassed: TaskEventType = "validation.behavior.passed"
        static let behaviorFailed: TaskEventType = "validation.behavior.failed"
        static let behaviorEvidenceAttached: TaskEventType = "validation.behavior.evidence.attached"
    }

    enum Deliverable {
        static let verificationPassed: TaskEventType = "deliverable.verification.passed"
        static let verificationReviewNeeded: TaskEventType = "deliverable.verification.review_needed"
        static let verificationFailed: TaskEventType = "deliverable.verification.failed"
    }

    enum Verifier {
        static let started: TaskEventType = "verifier.started"
        static let completed: TaskEventType = "verifier.completed"
        static let failed: TaskEventType = "verifier.failed"
    }

    enum Handoff {
        static let created: TaskEventType = "handoff.created"
        static let updated: TaskEventType = "handoff.updated"
        static let missing: TaskEventType = "handoff.missing"
    }

    enum Corrective {
        static let stepCreated: TaskEventType = "corrective.step.created"
        static let stepApproved: TaskEventType = "corrective.step.approved"
        static let stepDismissed: TaskEventType = "corrective.step.dismissed"
        static let taskCreated: TaskEventType = "corrective.task.created"
    }

    enum ResourceLock {
        static let requested: TaskEventType = "resource.lock.requested"
        static let waiting: TaskEventType = "resource.lock.waiting"
        static let acquired: TaskEventType = "resource.lock.acquired"
        static let released: TaskEventType = "resource.lock.released"
    }

    enum Mission {
        static let actionApproved: TaskEventType = "mission.action.approved"
        static let actionDismissed: TaskEventType = "mission.action.dismissed"
        static let actionRetryRequested: TaskEventType = "mission.action.retry_requested"
        static let actionCorrectionCreated: TaskEventType = "mission.action.correction_created"
        static let milestoneCreated: TaskEventType = "mission.milestone.created"
        static let milestoneCompleted: TaskEventType = "mission.milestone.completed"
        static let checkpointCreated: TaskEventType = "mission.checkpoint.created"
        static let auditBundleCreated: TaskEventType = "mission.audit_bundle.created"
    }

    enum RoleProfile {
        static let selected: TaskEventType = "role.profile.selected"
        static let changed: TaskEventType = "role.profile.changed"
    }

    enum Team {
        static let agentStarted: TaskEventType = "team.agent.started"
        static let agentCompleted: TaskEventType = "team.agent.completed"
        static let created: TaskEventType = "team.created"
        static let deleted: TaskEventType = "team.deleted"
        static let message: TaskEventType = "team.message"
    }

    enum System {
        static let info: TaskEventType = "system.info"
        static let error: TaskEventType = "error"
        static let skillActive: TaskEventType = "skill.active"
        static let recapResult: TaskEventType = "recap.result"
        static let scheduleResult: TaskEventType = "schedule.result"
        static let astraArtifactPreflight: TaskEventType = "astra.artifact_preflight"
    }

    private static let lifecycleTypes: Set<TaskEventType> = [
        Task.started,
        Task.completed,
        Task.cancelled,
        Task.interrupted,
        Task.retried,
        Task.resumed,
        Task.approved,
        Task.dismissed,
        Task.checkpoint,
        Activity.compacted,
        Plan.created,
        Plan.updated,
        Plan.approved,
        Plan.cancelled,
        Plan.executionStarted,
        Plan.executionCompleted,
        Plan.executionFailed,
        Validation.contractCreated,
        Validation.contractUpdated,
        Validation.contractPassed,
        Validation.contractFailed,
        Validation.contractOverridden,
        Validation.behaviorStarted,
        Validation.behaviorPassed,
        Validation.behaviorFailed,
        Validation.behaviorEvidenceAttached,
        Deliverable.verificationPassed,
        Deliverable.verificationReviewNeeded,
        Deliverable.verificationFailed,
        Verifier.started,
        Verifier.completed,
        Verifier.failed,
        Handoff.created,
        Handoff.updated,
        Handoff.missing,
        Corrective.stepCreated,
        Corrective.stepApproved,
        Corrective.stepDismissed,
        Corrective.taskCreated,
        ResourceLock.requested,
        ResourceLock.waiting,
        ResourceLock.acquired,
        ResourceLock.released,
        Mission.actionApproved,
        Mission.actionDismissed,
        Mission.actionRetryRequested,
        Mission.actionCorrectionCreated,
        Mission.milestoneCreated,
        Mission.milestoneCompleted,
        Mission.checkpointCreated,
        Mission.auditBundleCreated,
        RoleProfile.selected,
        RoleProfile.changed
    ]

    private static let conversationTypes: Set<TaskEventType> = [
        Conversation.userMessage,
        Conversation.agentResponse,
        Conversation.agentThinking,
        Conversation.planUserMessage,
        Conversation.planAssistantMessage
    ]

    private static let toolTypes: Set<TaskEventType> = [
        Tool.use,
        Tool.result,
        Tool.permissionDenied,
        Plan.stepStarted,
        Plan.stepCompleted,
        Plan.stepBlocked,
        Plan.stepSkipped,
        Validation.assertionDefined,
        Validation.assertionStarted,
        Validation.assertionPassed,
        Validation.assertionFailed,
        Validation.assertionSkipped,
        Validation.assertionReviewed
    ]

    private static let systemTypes: Set<TaskEventType> = [
        System.error,
        System.info,
        Budget.exceeded,
        Budget.warning,
        Task.stats,
        Task.chained,
        Tool.permissionApprovalRequested,
        Tool.permissionGrantTask,
        System.skillActive,
        System.recapResult,
        System.scheduleResult
    ]

    static func category(for eventType: TaskEventType) -> TaskEventCategory {
        if lifecycleTypes.contains(eventType) { return .lifecycle }
        if conversationTypes.contains(eventType) { return .conversation }
        if toolTypes.contains(eventType) { return .tool }
        if systemTypes.contains(eventType) { return .system }
        if eventType.rawValue.hasPrefix("astra.") { return .system }
        if eventType.rawValue.hasPrefix("team.") { return .team }
        return .system
    }

    static func category(forRawValue rawValue: String) -> TaskEventCategory {
        guard let eventType = TaskEventType(rawValue: rawValue) else { return .system }
        return category(for: eventType)
    }
}
