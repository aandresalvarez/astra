import Foundation
import SwiftData
import ASTRACore

enum TaskRuntimePermissionGrants {
    static let eventType = "permission.grant.task"

    struct Payload: Codable, Equatable {
        var brokerVersion: Int
        var providerID: AgentRuntimeID
        var grants: [PermissionGrant]
        var approvedAt: Date
        var source: String
    }

    @MainActor
    static func record(
        grants: [PermissionGrant],
        providerID: AgentRuntimeID,
        task: AgentTask,
        modelContext: ModelContext,
        source: String
    ) -> [PermissionGrant] {
        let sanitized = PermissionBroker.taskScopedApprovalGrants(for: grants)
        guard !sanitized.isEmpty else { return [] }
        let payload = Payload(
            brokerVersion: PermissionBroker.brokerVersion,
            providerID: providerID,
            grants: sanitized,
            approvedAt: Date(),
            source: source
        )
        let encoded = (try? JSONEncoder().encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? sanitized.map(\.displayName).joined(separator: ", ")
        modelContext.insert(TaskEvent(
            task: task,
            type: eventType,
            payload: encoded
        ))
        return sanitized
    }

    static func approvedGrants(for task: AgentTask, runtime: AgentRuntimeID? = nil) -> [PermissionGrant] {
        let decoded = task.events
            .filter { $0.type == eventType }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { decodePayload($0.payload) }
            .filter { payload in
                runtime.map { payload.providerID == $0 } ?? true
            }
            .flatMap(\.grants)
        return PermissionBroker.taskScopedApprovalGrants(for: decoded)
    }

    static func decodePayload(_ payload: String) -> Payload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
