import Foundation
import SwiftData
import ASTRACore

public enum WorkspaceAppDependencyBindingStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case mapped
    case optionalMissing
    case missingRequired
}

@Model
public final class WorkspaceAppDependencyBinding: Identifiable {
    public var id: UUID
    public var workspaceID: UUID
    public var appID: UUID
    public var appLogicalID: String
    public var requirementID: String
    public var contract: String
    public var operationsSummary: String
    public var optional: Bool
    public var statusRaw: String
    public var implementationID: String?
    public var provider: String?
    public var transportRaw: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        requirementID: String,
        contract: String,
        operations: [String],
        optional: Bool,
        status: WorkspaceAppDependencyBindingStatus,
        implementationID: String? = nil,
        provider: String? = nil,
        transport: WorkspaceAppContractTransport? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.appID = appID
        self.appLogicalID = appLogicalID
        self.requirementID = requirementID
        self.contract = contract
        self.operationsSummary = operations.joined(separator: ",")
        self.optional = optional
        self.statusRaw = status.rawValue
        self.implementationID = implementationID
        self.provider = provider
        self.transportRaw = transport?.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var status: WorkspaceAppDependencyBindingStatus {
        get { WorkspaceAppDependencyBindingStatus(rawValue: statusRaw) ?? .missingRequired }
        set { statusRaw = newValue.rawValue }
    }

    public var transport: WorkspaceAppContractTransport? {
        get {
            guard let transportRaw else { return nil }
            return WorkspaceAppContractTransport(rawValue: transportRaw)
        }
        set { transportRaw = newValue?.rawValue }
    }

    public var operations: [String] {
        operationsSummary
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
