import Foundation

enum TaskMissionActionEventTypes {
    static let approved = TaskEventTypes.Mission.actionApproved.rawValue
    static let dismissed = TaskEventTypes.Mission.actionDismissed.rawValue
    static let retryRequested = TaskEventTypes.Mission.actionRetryRequested.rawValue
    static let correctionCreated = TaskEventTypes.Mission.actionCorrectionCreated.rawValue
}

struct TaskMissionActionPayload: Codable, Sendable, Equatable {
    var version: Int
    var action: String
    var correctiveStepID: String?
    var correctiveTaskID: UUID?
    var reason: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case action
        case correctiveStepID
        case correctiveTaskID
        case reason
        case createdAt
    }
}
