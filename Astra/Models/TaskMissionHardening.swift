import Foundation

enum TaskMissionEventTypes {
    static let milestoneCreated = TaskEventTypes.Mission.milestoneCreated.rawValue
    static let milestoneCompleted = TaskEventTypes.Mission.milestoneCompleted.rawValue
    static let checkpointCreated = TaskEventTypes.Mission.checkpointCreated.rawValue
    static let auditBundleCreated = TaskEventTypes.Mission.auditBundleCreated.rawValue
}

struct TaskMissionCheckpointPayload: Codable, Equatable, Sendable {
    var version: Int = 1
    var checkpointID: UUID
    var runID: UUID?
    var taskStatus: String
    var runStatus: String?
    var elapsedSeconds: Int
    var tokensUsed: Int
    var costUSD: Double
    var contractStatus: String?
    var openBlockers: [String]
    var eventCount: Int
    var sourcePointers: [TaskContextState.SourcePointer]
}

struct TaskMissionAuditBundlePayload: Codable, Equatable, Sendable {
    var version: Int = 1
    var bundleID: UUID
    var path: String
    var taskID: UUID
    var eventCount: Int
    var checkpointCount: Int
    var validationEvidenceCount: Int
    var createdAt: Date
}

struct TaskMissionMilestonePayload: Codable, Equatable, Sendable {
    var version: Int = 1
    var milestoneID: String
    var title: String
    var status: String
    var planID: UUID?
    var stepID: String?
}
