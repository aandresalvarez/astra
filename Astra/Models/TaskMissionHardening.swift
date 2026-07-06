import Foundation
import ASTRACore

public enum TaskMissionEventTypes {
    public static let milestoneCreated = TaskEventTypes.Mission.milestoneCreated.rawValue
    public static let milestoneCompleted = TaskEventTypes.Mission.milestoneCompleted.rawValue
    public static let checkpointCreated = TaskEventTypes.Mission.checkpointCreated.rawValue
    public static let auditBundleCreated = TaskEventTypes.Mission.auditBundleCreated.rawValue
}

public struct TaskMissionCheckpointPayload: Codable, Equatable, Sendable {
    public init(version: Int = 1, checkpointID: UUID, runID: UUID?, taskStatus: String, runStatus: String?, elapsedSeconds: Int, tokensUsed: Int, costUSD: Double, contractStatus: String?, openBlockers: [String], eventCount: Int, sourcePointers: [TaskContextSourcePointer]) {
        self.version = version
        self.checkpointID = checkpointID
        self.runID = runID
        self.taskStatus = taskStatus
        self.runStatus = runStatus
        self.elapsedSeconds = elapsedSeconds
        self.tokensUsed = tokensUsed
        self.costUSD = costUSD
        self.contractStatus = contractStatus
        self.openBlockers = openBlockers
        self.eventCount = eventCount
        self.sourcePointers = sourcePointers
    }

    public var version: Int = 1
    public var checkpointID: UUID
    public var runID: UUID?
    public var taskStatus: String
    public var runStatus: String?
    public var elapsedSeconds: Int
    public var tokensUsed: Int
    public var costUSD: Double
    public var contractStatus: String?
    public var openBlockers: [String]
    public var eventCount: Int
    public var sourcePointers: [TaskContextSourcePointer]
}

public struct TaskMissionAuditBundlePayload: Codable, Equatable, Sendable {
    public init(version: Int = 1, bundleID: UUID, path: String, taskID: UUID, eventCount: Int, checkpointCount: Int, validationEvidenceCount: Int, createdAt: Date) {
        self.version = version
        self.bundleID = bundleID
        self.path = path
        self.taskID = taskID
        self.eventCount = eventCount
        self.checkpointCount = checkpointCount
        self.validationEvidenceCount = validationEvidenceCount
        self.createdAt = createdAt
    }

    public var version: Int = 1
    public var bundleID: UUID
    public var path: String
    public var taskID: UUID
    public var eventCount: Int
    public var checkpointCount: Int
    public var validationEvidenceCount: Int
    public var createdAt: Date
}

public struct TaskMissionMilestonePayload: Codable, Equatable, Sendable {
    public init(version: Int = 1, milestoneID: String, title: String, status: String, planID: UUID?, stepID: String?) {
        self.version = version
        self.milestoneID = milestoneID
        self.title = title
        self.status = status
        self.planID = planID
        self.stepID = stepID
    }

    public var version: Int = 1
    public var milestoneID: String
    public var title: String
    public var status: String
    public var planID: UUID?
    public var stepID: String?
}
