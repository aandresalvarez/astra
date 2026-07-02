import Foundation
import SwiftData
import ASTRACore

enum TaskRuntimePermissionGrants {
    static let eventType = TaskEventTypes.Tool.permissionGrantTask.rawValue

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
        recordTypedPayload(payload, task: task)
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
        let typed = typedPayloads(for: task)
        let decoded = typed.isEmpty ? compatibilityPayloads(for: task) : typed
        let grants = decoded
            .filter { payload in
                runtime.map { payload.providerID == $0 } ?? true
            }
            .flatMap(\.grants)
        return PermissionBroker.taskScopedApprovalGrants(for: grants)
    }

    private static func compatibilityPayloads(for task: AgentTask) -> [Payload] {
        task.events
            .filter { $0.type == eventType }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { decodePayload($0.payload) }
    }

    private static func typedPayloads(for task: AgentTask) -> [Payload] {
        guard let data = (task.runtimePermissionGrantsJSON ?? "[]").data(using: .utf8),
              let payloads = try? JSONDecoder().decode([Payload].self, from: data) else {
            return []
        }
        return payloads.sorted { $0.approvedAt < $1.approvedAt }
    }

    private static func recordTypedPayload(_ payload: Payload, task: AgentTask) {
        var payloads = typedPayloads(for: task)
        payloads.append(payload)
        task.runtimePermissionGrantsJSON = (try? JSONEncoder().encode(payloads))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
    }

    static func approvedCredentialLabels(
        for task: AgentTask,
        runtime: AgentRuntimeID? = nil,
        additionalGrants: [PermissionGrant] = []
    ) -> [String] {
        let taskGrants = approvedGrants(for: task, runtime: runtime)
        let oneRunGrants = PermissionBroker.sanitizeApprovedGrants(additionalGrants)
        return Array(Set((taskGrants + oneRunGrants).compactMap { grant in
            guard case .credential(let label) = grant else { return nil }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted()
    }

    static func decodePayload(_ payload: String) -> Payload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
