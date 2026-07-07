import Foundation

public enum TaskEventCategory: String, Codable, Sendable, Equatable, Hashable {
    case lifecycle
    case conversation
    case tool
    case system
    case team
}

public struct TaskEventType: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    public var category: TaskEventCategory {
        TaskEventTypes.category(for: self)
    }
}

public enum TaskEventPayloadDecodeError: Error, Equatable, CustomStringConvertible {
    case typeMismatch(expected: String, actual: String)
    case invalidUTF8
    case decodingFailed(String)

    public var description: String {
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

public enum TaskEventTypes {
    public enum Task {
        public static let started: TaskEventType = "task.started"
        public static let completed: TaskEventType = "task.completed"
        public static let cancelled: TaskEventType = "task.cancelled"
        public static let interrupted: TaskEventType = "task.interrupted"
        public static let retried: TaskEventType = "task.retried"
        public static let resumed: TaskEventType = "task.resumed"
        public static let approved: TaskEventType = "task.approved"
        public static let dismissed: TaskEventType = "task.dismissed"
        public static let checkpoint: TaskEventType = "task.checkpoint"
        public static let stats: TaskEventType = "task.stats"
        public static let chained: TaskEventType = "task.chained"
    }

    public enum Conversation {
        public static let userMessage: TaskEventType = "user.message"
        public static let agentResponse: TaskEventType = "agent.response"
        public static let agentThinking: TaskEventType = "agent.thinking"
        public static let planUserMessage: TaskEventType = "plan.user.message"
        public static let planAssistantMessage: TaskEventType = "plan.assistant.message"
    }

    public enum Tool {
        public static let use: TaskEventType = "tool.use"
        public static let result: TaskEventType = "tool.result"
        public static let permissionDenied: TaskEventType = "permission.denied"
        public static let permissionApprovalRequested: TaskEventType = "permission.approval.requested"
        /// Emitted when a live in-flight ask is answered (allow or deny) without
        /// a `task.approved` (the deny path, and any provider whose answer
        /// resolves the same running process). Closes the open-request card.
        public static let permissionRequestResolved: TaskEventType = "permission.request.resolved"
        public static let permissionGrantTask: TaskEventType = "permission.grant.task"
    }

    public enum Budget {
        public static let warning: TaskEventType = "budget.warning"
        public static let exceeded: TaskEventType = "budget.exceeded"
    }

    public enum Activity {
        public static let compacted: TaskEventType = "activity.compacted"
    }

    public enum Plan {
        public static let created: TaskEventType = "plan.created"
        public static let updated: TaskEventType = "plan.updated"
        public static let approved: TaskEventType = "plan.approved"
        public static let cancelled: TaskEventType = "plan.cancelled"
        public static let executionStarted: TaskEventType = "plan.execution.started"
        public static let executionCompleted: TaskEventType = "plan.execution.completed"
        public static let executionFailed: TaskEventType = "plan.execution.failed"
        public static let userMessage: TaskEventType = "plan.user.message"
        public static let assistantMessage: TaskEventType = "plan.assistant.message"
        public static let stepStarted: TaskEventType = "plan.step.started"
        public static let stepCompleted: TaskEventType = "plan.step.completed"
        public static let stepBlocked: TaskEventType = "plan.step.blocked"
        public static let stepSkipped: TaskEventType = "plan.step.skipped"
    }

    public enum Validation {
        public static let contractCreated: TaskEventType = "validation.contract.created"
        public static let contractUpdated: TaskEventType = "validation.contract.updated"
        public static let contractPassed: TaskEventType = "validation.contract.passed"
        public static let contractFailed: TaskEventType = "validation.contract.failed"
        public static let contractOverridden: TaskEventType = "validation.contract.override"
        public static let assertionDefined: TaskEventType = "validation.assertion.defined"
        public static let assertionStarted: TaskEventType = "validation.assertion.started"
        public static let assertionPassed: TaskEventType = "validation.assertion.passed"
        public static let assertionFailed: TaskEventType = "validation.assertion.failed"
        public static let assertionSkipped: TaskEventType = "validation.assertion.skipped"
        public static let assertionReviewed: TaskEventType = "validation.assertion.reviewed"
        public static let evidence: TaskEventType = "validation.evidence"
        public static let behaviorStarted: TaskEventType = "validation.behavior.started"
        public static let behaviorPassed: TaskEventType = "validation.behavior.passed"
        public static let behaviorFailed: TaskEventType = "validation.behavior.failed"
        public static let behaviorEvidenceAttached: TaskEventType = "validation.behavior.evidence.attached"
    }

    public enum Deliverable {
        public static let verificationPassed: TaskEventType = "deliverable.verification.passed"
        public static let verificationReviewNeeded: TaskEventType = "deliverable.verification.review_needed"
        public static let verificationFailed: TaskEventType = "deliverable.verification.failed"
    }

    public enum Verifier {
        public static let started: TaskEventType = "verifier.started"
        public static let completed: TaskEventType = "verifier.completed"
        public static let failed: TaskEventType = "verifier.failed"
    }

    public enum Handoff {
        public static let created: TaskEventType = "handoff.created"
        public static let updated: TaskEventType = "handoff.updated"
        public static let missing: TaskEventType = "handoff.missing"
    }

    public enum Corrective {
        public static let stepCreated: TaskEventType = "corrective.step.created"
        public static let stepApproved: TaskEventType = "corrective.step.approved"
        public static let stepDismissed: TaskEventType = "corrective.step.dismissed"
        public static let taskCreated: TaskEventType = "corrective.task.created"
    }

    public enum ResourceLock {
        public static let requested: TaskEventType = "resource.lock.requested"
        public static let waiting: TaskEventType = "resource.lock.waiting"
        public static let acquired: TaskEventType = "resource.lock.acquired"
        public static let released: TaskEventType = "resource.lock.released"
    }

    public enum Mission {
        public static let actionApproved: TaskEventType = "mission.action.approved"
        public static let actionDismissed: TaskEventType = "mission.action.dismissed"
        public static let actionRetryRequested: TaskEventType = "mission.action.retry_requested"
        public static let actionCorrectionCreated: TaskEventType = "mission.action.correction_created"
        public static let milestoneCreated: TaskEventType = "mission.milestone.created"
        public static let milestoneCompleted: TaskEventType = "mission.milestone.completed"
        public static let checkpointCreated: TaskEventType = "mission.checkpoint.created"
        public static let auditBundleCreated: TaskEventType = "mission.audit_bundle.created"
    }

    public enum RoleProfile {
        public static let selected: TaskEventType = "role.profile.selected"
        public static let changed: TaskEventType = "role.profile.changed"
    }

    public enum Team {
        public static let agentStarted: TaskEventType = "team.agent.started"
        public static let agentCompleted: TaskEventType = "team.agent.completed"
        public static let created: TaskEventType = "team.created"
        public static let deleted: TaskEventType = "team.deleted"
        public static let message: TaskEventType = "team.message"
    }

    public enum System {
        public static let info: TaskEventType = "system.info"
        public static let error: TaskEventType = "error"
        public static let skillActive: TaskEventType = "skill.active"
        public static let recapResult: TaskEventType = "recap.result"
        public static let scheduleResult: TaskEventType = "schedule.result"
        public static let astraArtifactPreflight: TaskEventType = "astra.artifact_preflight"
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

    public static func category(for eventType: TaskEventType) -> TaskEventCategory {
        if lifecycleTypes.contains(eventType) { return .lifecycle }
        if conversationTypes.contains(eventType) { return .conversation }
        if toolTypes.contains(eventType) { return .tool }
        if systemTypes.contains(eventType) { return .system }
        if eventType.rawValue.hasPrefix("astra.") { return .system }
        if eventType.rawValue.hasPrefix("team.") { return .team }
        return .system
    }

    public static func category(forRawValue rawValue: String) -> TaskEventCategory {
        guard let eventType = TaskEventType(rawValue: rawValue) else { return .system }
        return category(for: eventType)
    }
}
