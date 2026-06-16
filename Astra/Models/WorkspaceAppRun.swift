import Foundation
import SwiftData

enum WorkspaceAppRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case completed
    case failed
    case blocked
    case cancelled
}

enum WorkspaceAppRunTrigger: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case automation
    case importReview
    case test
}

@Model
final class WorkspaceAppRun: Identifiable {
    var id: UUID
    var workspaceID: UUID
    var appID: UUID
    var appLogicalID: String
    var actionID: String
    var triggerRaw: String
    var statusRaw: String
    var startedAt: Date
    var completedAt: Date?
    var inputSummary: String
    var outputSummary: String
    var errorMessage: String?
    var linkedTaskID: UUID?
    var linkedArtifactPath: String?

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        actionID: String,
        trigger: WorkspaceAppRunTrigger = .user,
        status: WorkspaceAppRunStatus = .running,
        startedAt: Date = Date(),
        inputSummary: String = "",
        outputSummary: String = "",
        errorMessage: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.appID = appID
        self.appLogicalID = appLogicalID
        self.actionID = actionID
        self.triggerRaw = trigger.rawValue
        self.statusRaw = status.rawValue
        self.startedAt = startedAt
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.errorMessage = errorMessage
    }

    var status: WorkspaceAppRunStatus {
        get { WorkspaceAppRunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var trigger: WorkspaceAppRunTrigger {
        get { WorkspaceAppRunTrigger(rawValue: triggerRaw) ?? .user }
        set { triggerRaw = newValue.rawValue }
    }
}

@Model
final class WorkspaceAppRunEvent: Identifiable {
    var id: UUID
    var runID: UUID
    var workspaceID: UUID
    var appID: UUID
    var actionID: String
    var type: String
    var payload: String
    var timestamp: Date

    init(
        id: UUID = UUID(),
        runID: UUID,
        workspaceID: UUID,
        appID: UUID,
        actionID: String,
        type: String,
        payload: String = "{}",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.workspaceID = workspaceID
        self.appID = appID
        self.actionID = actionID
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }
}
