import Foundation
import SwiftData

enum WorkspaceAppDependencyBindingStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case mapped
    case optionalMissing
    case missingRequired
}

@Model
final class WorkspaceAppDependencyBinding: Identifiable {
    var id: UUID
    var workspaceID: UUID
    var appID: UUID
    var appLogicalID: String
    var requirementID: String
    var contract: String
    var operationsSummary: String
    var optional: Bool
    var statusRaw: String
    var implementationID: String?
    var provider: String?
    var transportRaw: String?
    var createdAt: Date
    var updatedAt: Date

    init(
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

    var status: WorkspaceAppDependencyBindingStatus {
        get { WorkspaceAppDependencyBindingStatus(rawValue: statusRaw) ?? .missingRequired }
        set { statusRaw = newValue.rawValue }
    }

    var transport: WorkspaceAppContractTransport? {
        get {
            guard let transportRaw else { return nil }
            return WorkspaceAppContractTransport(rawValue: transportRaw)
        }
        set { transportRaw = newValue?.rawValue }
    }

    var operations: [String] {
        operationsSummary
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
