import Foundation
import SwiftData

enum WorkspaceAppAutomationStateStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case disabled
    case enabled
    case blocked
}

@Model
final class WorkspaceAppAutomationState: Identifiable {
    var id: UUID
    var workspaceID: UUID
    var appID: UUID
    var appLogicalID: String
    var automationID: String
    var automationType: String
    var actionID: String?
    var isEnabled: Bool
    var statusRaw: String
    var lastRunAt: Date?
    var nextRunAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        automationID: String,
        automationType: String,
        actionID: String? = nil,
        isEnabled: Bool = false,
        status: WorkspaceAppAutomationStateStatus = .disabled,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.appID = appID
        self.appLogicalID = appLogicalID
        self.automationID = automationID
        self.automationType = automationType
        self.actionID = actionID
        self.isEnabled = isEnabled
        self.statusRaw = status.rawValue
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var status: WorkspaceAppAutomationStateStatus {
        get { WorkspaceAppAutomationStateStatus(rawValue: statusRaw) ?? .disabled }
        set { statusRaw = newValue.rawValue }
    }
}
