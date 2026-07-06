import Foundation

public enum TaskCorrectiveEventTypes {
    public static let stepCreated = TaskEventTypes.Corrective.stepCreated.rawValue
    public static let stepApproved = TaskEventTypes.Corrective.stepApproved.rawValue
    public static let stepDismissed = TaskEventTypes.Corrective.stepDismissed.rawValue
    public static let taskCreated = TaskEventTypes.Corrective.taskCreated.rawValue
}

public struct TaskCorrectiveStepPayload: Codable, Sendable, Equatable {
    public init(version: Int, planID: UUID, sourceRunID: UUID?, correctiveStepID: String?, failedAssertionID: String, failureSummary: String, suggestedRepair: String, status: String, correctiveTaskID: UUID?, dismissedReason: String?, createdAt: String, updatedAt: String?) {
        self.version = version
        self.planID = planID
        self.sourceRunID = sourceRunID
        self.correctiveStepID = correctiveStepID
        self.failedAssertionID = failedAssertionID
        self.failureSummary = failureSummary
        self.suggestedRepair = suggestedRepair
        self.status = status
        self.correctiveTaskID = correctiveTaskID
        self.dismissedReason = dismissedReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var version: Int
    public var planID: UUID
    public var sourceRunID: UUID?
    public var correctiveStepID: String?
    public var failedAssertionID: String
    public var failureSummary: String
    public var suggestedRepair: String
    public var status: String
    public var correctiveTaskID: UUID?
    public var dismissedReason: String?
    public var createdAt: String
    public var updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case sourceRunID
        case correctiveStepID
        case failedAssertionID
        case failureSummary
        case suggestedRepair
        case status
        case correctiveTaskID
        case dismissedReason
        case createdAt
        case updatedAt
    }
}
