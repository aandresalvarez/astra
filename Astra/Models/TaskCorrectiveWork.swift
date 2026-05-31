import Foundation

enum TaskCorrectiveEventTypes {
    static let stepCreated = "corrective.step.created"
    static let stepApproved = "corrective.step.approved"
    static let stepDismissed = "corrective.step.dismissed"
    static let taskCreated = "corrective.task.created"
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
