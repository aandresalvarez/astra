import Foundation

enum TaskCorrectiveEventTypes {
    static let stepCreated = TaskEventTypes.Corrective.stepCreated.rawValue
    static let stepApproved = TaskEventTypes.Corrective.stepApproved.rawValue
    static let stepDismissed = TaskEventTypes.Corrective.stepDismissed.rawValue
    static let taskCreated = TaskEventTypes.Corrective.taskCreated.rawValue
}

struct TaskCorrectiveStepPayload: Codable, Sendable, Equatable {
    var version: Int
    var planID: UUID
    var sourceRunID: UUID?
    var correctiveStepID: String?
    var failedAssertionID: String
    var failureSummary: String
    var suggestedRepair: String
    var status: String
    var correctiveTaskID: UUID?
    var dismissedReason: String?
    var createdAt: String
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
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
