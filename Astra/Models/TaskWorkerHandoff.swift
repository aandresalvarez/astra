import Foundation

public enum TaskHandoffEventTypes {
    public static let created = TaskEventTypes.Handoff.created.rawValue
    public static let updated = TaskEventTypes.Handoff.updated.rawValue
    public static let missing = TaskEventTypes.Handoff.missing.rawValue
}

public struct TaskWorkerHandoffPayload: Codable, Sendable, Equatable {
    public struct Command: Codable, Sendable, Equatable, Hashable {
        public init(summary: String, exitCode: Int? = nil) {
            self.summary = summary
            self.exitCode = exitCode
        }

        public var summary: String
        public var exitCode: Int?
    }

    public var version: Int
    public var runID: UUID
    public var taskStatus: String
    public var runStatus: String
    public var completedWork: [String]
    public var unfinishedWork: [String]
    public var commands: [Command]
    public var filesChanged: [String]
    public var artifactsCreated: [String]
    public var validationEvidence: [String]
    public var blockers: [String]
    public var risks: [String]
    public var suggestedNextAction: String?
    public var createdAt: String

    public init(
        version: Int,
        runID: UUID,
        taskStatus: String,
        runStatus: String,
        completedWork: [String],
        unfinishedWork: [String],
        commands: [Command],
        filesChanged: [String],
        artifactsCreated: [String],
        validationEvidence: [String],
        blockers: [String],
        risks: [String],
        suggestedNextAction: String? = nil,
        createdAt: String
    ) {
        self.version = version
        self.runID = runID
        self.taskStatus = taskStatus
        self.runStatus = runStatus
        self.completedWork = completedWork
        self.unfinishedWork = unfinishedWork
        self.commands = commands
        self.filesChanged = filesChanged
        self.artifactsCreated = artifactsCreated
        self.validationEvidence = validationEvidence
        self.blockers = blockers
        self.risks = risks
        self.suggestedNextAction = suggestedNextAction
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
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
