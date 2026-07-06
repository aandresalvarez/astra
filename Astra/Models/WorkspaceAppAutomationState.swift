import Foundation
import SwiftData

public enum WorkspaceAppAutomationStateStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case disabled
    case enabled
    case blocked
}

@Model
public final class WorkspaceAppAutomationState: Identifiable {
    public var id: UUID
    public var workspaceID: UUID
    public var appID: UUID
    public var appLogicalID: String
    public var automationID: String
    public var automationType: String
    public var actionID: String?
    public var isEnabled: Bool
    public var statusRaw: String
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
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

    public var status: WorkspaceAppAutomationStateStatus {
        get { WorkspaceAppAutomationStateStatus(rawValue: statusRaw) ?? .disabled }
        set { statusRaw = newValue.rawValue }
    }
}
