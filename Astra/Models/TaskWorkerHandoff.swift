import Foundation

enum TaskHandoffEventTypes {
    static let created = TaskEventTypes.Handoff.created.rawValue
    static let updated = TaskEventTypes.Handoff.updated.rawValue
    static let missing = TaskEventTypes.Handoff.missing.rawValue
}

struct TaskWorkerHandoffPayload: Codable, Sendable, Equatable {
    struct Command: Codable, Sendable, Equatable, Hashable {
        var summary: String
        var exitCode: Int?
    }

    var version: Int
    var runID: UUID
    var taskStatus: String
    var runStatus: String
    var completedWork: [String]
    var unfinishedWork: [String]
    var commands: [Command]
    var filesChanged: [String]
    var artifactsCreated: [String]
    var validationEvidence: [String]
    var blockers: [String]
    var risks: [String]
    var suggestedNextAction: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case runID
        case taskStatus
        case runStatus
        case completedWork
        case unfinishedWork
        case commands
        case filesChanged
        case artifactsCreated
        case validationEvidence
        case blockers
        case risks
        case suggestedNextAction
        case createdAt
    }
}
