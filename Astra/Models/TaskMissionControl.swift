import Foundation

public enum TaskMissionActionEventTypes {
    public static let approved = TaskEventTypes.Mission.actionApproved.rawValue
    public static let dismissed = TaskEventTypes.Mission.actionDismissed.rawValue
    public static let retryRequested = TaskEventTypes.Mission.actionRetryRequested.rawValue
    public static let correctionCreated = TaskEventTypes.Mission.actionCorrectionCreated.rawValue
}

public struct TaskMissionActionPayload: Codable, Sendable, Equatable {
    public init(version: Int, action: String, correctiveStepID: String?, correctiveTaskID: UUID?, reason: String?, createdAt: String) {
        self.version = version
        self.action = action
        self.correctiveStepID = correctiveStepID
        self.correctiveTaskID = correctiveTaskID
        self.reason = reason
        self.createdAt = createdAt
    }

    public var version: Int
    public var action: String
    public var correctiveStepID: String?
    public var correctiveTaskID: UUID?
    public var reason: String?
    public var createdAt: String

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case action
        case correctiveStepID
        case correctiveTaskID
        case reason
        case createdAt
    }
}
