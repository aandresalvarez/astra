import Foundation

/// Pure event-type-name slice of `Astra/Services/Tasks/TaskPlanService.swift`
/// (the ~1,150-line plan-reconstruction engine, used throughout
/// Views/Runtime/Validation and too large/coupled to move), extracted for
/// Track A4 (`ASTRAPersistence`) so Persistence files that filter
/// `task.events` by plan-related event type don't need the rest of that
/// service.
public enum TaskPlanEventTypes {
    public static let created = TaskEventTypes.Plan.created.rawValue
    public static let updated = TaskEventTypes.Plan.updated.rawValue
    public static let approved = TaskEventTypes.Plan.approved.rawValue
    public static let cancelled = TaskEventTypes.Plan.cancelled.rawValue
    public static let executionStarted = TaskEventTypes.Plan.executionStarted.rawValue
    public static let executionCompleted = TaskEventTypes.Plan.executionCompleted.rawValue
    public static let executionFailed = TaskEventTypes.Plan.executionFailed.rawValue
    public static let userMessage = TaskEventTypes.Plan.userMessage.rawValue
    public static let assistantMessage = TaskEventTypes.Plan.assistantMessage.rawValue

    public static let stepStarted = TaskEventTypes.Plan.stepStarted.rawValue
    public static let stepCompleted = TaskEventTypes.Plan.stepCompleted.rawValue
    public static let stepBlocked = TaskEventTypes.Plan.stepBlocked.rawValue
    public static let stepSkipped = TaskEventTypes.Plan.stepSkipped.rawValue

    public static let stepEvents: Set<String> = [
        stepStarted,
        stepCompleted,
        stepBlocked,
        stepSkipped
    ]
}

public typealias TaskPlanEventType = TaskPlanEventTypes

public enum TaskPlanConversationEventTypes {
    public static let userMessage = TaskPlanEventTypes.userMessage
    public static let assistantMessage = TaskPlanEventTypes.assistantMessage
}
