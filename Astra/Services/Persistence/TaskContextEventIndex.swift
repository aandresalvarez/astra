import Foundation
import ASTRAModels

/// One pass over `task.events` for a context-state derive.
///
/// `updateDerivedFields` used to filter all of `task.events` once per helper,
/// about a dozen full scans per apply. On SwiftData models each `type` read is
/// a backing-store lookup, so on a task with thousands of events those scans
/// were most of the apply's main-actor time. The index reads every event's
/// type once and keeps each helper's candidates in their original order.
///
/// Every bucket is a superset of what its helper selects, in `task.events`
/// order, so a helper that filters and sorts a bucket sees exactly the
/// sequence it would have filtered out of `task.events` itself.
struct TaskContextEventIndex {
    var userMessages: [TaskEvent] = []
    var assistantReplies: [TaskEvent] = []
    var blocking: [TaskEvent] = []
    var validation: [TaskEvent] = []
    var deliverableVerification: [TaskEvent] = []
    var validationContract: [TaskEvent] = []
    var validationAssertions: [TaskEvent] = []
    var handoffs: [TaskEvent] = []
    var corrective: [TaskEvent] = []
    /// `TaskPendingTurnMessageVisibility.pendingMessageEventIDs`, fetched once
    /// instead of once per user-message scan.
    var pendingTurnMessageIDs: Set<UUID> = []

    static let blockingTypes: Set<String> = [
        "error", "permission.denied", "permission.approval.requested", "budget.exceeded"
    ]
    static let userMessageTypes: Set<String> = ["user.message", TaskPlanConversationEventTypes.userMessage]
    static let assistantReplyTypes: Set<String> = [TaskPlanConversationEventTypes.assistantMessage, "agent.response"]
    /// Types `isValidationEvent` can accept; it still checks payload markers.
    static let validationTypes: Set<String> = [
        TaskValidationEventTypes.contractPassed,
        TaskValidationEventTypes.contractFailed,
        TaskValidationEventTypes.contractOverridden,
        "task.completed",
        "error"
    ]
    static let deliverableVerificationTypes: Set<String> = [
        TaskDeliverableVerificationEventTypes.passed,
        TaskDeliverableVerificationEventTypes.reviewNeeded,
        TaskDeliverableVerificationEventTypes.failed
    ]
    static let validationContractTypes: Set<String> = [
        TaskValidationEventTypes.contractCreated,
        TaskValidationEventTypes.contractUpdated,
        TaskValidationEventTypes.contractPassed,
        TaskValidationEventTypes.contractFailed,
        TaskValidationEventTypes.contractOverridden
    ]
    static let validationAssertionTypes: Set<String> = [
        TaskValidationEventTypes.assertionDefined,
        TaskValidationEventTypes.assertionStarted,
        TaskValidationEventTypes.assertionPassed,
        TaskValidationEventTypes.assertionFailed,
        TaskValidationEventTypes.assertionSkipped,
        TaskValidationEventTypes.assertionReviewed
    ]
    static let handoffTypes: Set<String> = [TaskHandoffEventTypes.created, TaskHandoffEventTypes.updated]
    static let correctiveTypes: Set<String> = [
        TaskCorrectiveEventTypes.stepCreated,
        TaskCorrectiveEventTypes.stepApproved,
        TaskCorrectiveEventTypes.stepDismissed,
        TaskCorrectiveEventTypes.taskCreated
    ]

    @MainActor
    init(task: AgentTask) {
        self.init(events: task.events)
        pendingTurnMessageIDs = TaskPendingTurnMessageVisibility.pendingMessageEventIDs(for: task)
    }

    init(events: [TaskEvent]) {
        for event in events {
            guard let buckets = Self.bucketsByType[event.type] else { continue }
            for bucket in buckets {
                self[keyPath: bucket].append(event)
            }
        }
    }

    /// The reference the buckets must agree with: every bucket holds every
    /// event, which is exactly what each helper scanned before this index
    /// existed. Tests derive with both and require identical state.
    init(unbucketed events: [TaskEvent], pendingTurnMessageIDs: Set<UUID>) {
        for (_, bucket) in Self.bucketMembership {
            self[keyPath: bucket] = events
        }
        self.pendingTurnMessageIDs = pendingTurnMessageIDs
    }

    private typealias Bucket = WritableKeyPath<TaskContextEventIndex, [TaskEvent]>

    private static let bucketMembership: [(types: Set<String>, bucket: Bucket)] = [
        (userMessageTypes, \.userMessages),
        (assistantReplyTypes, \.assistantReplies),
        (blockingTypes, \.blocking),
        (validationTypes, \.validation),
        (deliverableVerificationTypes, \.deliverableVerification),
        (validationContractTypes, \.validationContract),
        (validationAssertionTypes, \.validationAssertions),
        (handoffTypes, \.handoffs),
        (correctiveTypes, \.corrective)
    ]

    /// Every bucket an event type belongs to, so the pass costs one `type`
    /// read and one lookup per event. An event can land in several buckets:
    /// `error` is both blocking and a validation candidate.
    private static let bucketsByType: [String: [Bucket]] = {
        var result: [String: [Bucket]] = [:]
        for (types, bucket) in bucketMembership {
            for type in types {
                result[type, default: []].append(bucket)
            }
        }
        return result
    }()
}
