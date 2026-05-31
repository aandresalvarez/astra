import Foundation

enum TaskMissionActionEventTypes {
    static let approved = "mission.action.approved"
    static let dismissed = "mission.action.dismissed"
    static let retryRequested = "mission.action.retry_requested"
    static let correctionCreated = "mission.action.correction_created"
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
