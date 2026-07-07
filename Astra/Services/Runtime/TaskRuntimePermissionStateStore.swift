import Foundation
import ASTRACore
import ASTRAModels

enum TaskRuntimePermissionOpenRequestStore {
    struct Entry: Codable, Equatable {
        var requestID: String?
        var providerID: AgentRuntimeID?
        var request: PermissionRequest?
        var grants: [PermissionGrant]
        var displayMessage: String
        var payload: String
        var requestedAt: Date
    }

    static func recordOpenRequest(payload: String, task: AgentTask, at date: Date = Date()) {
        var entries = typedEntries(for: task)
        let entry = entry(from: payload, requestedAt: date)
        let requestID = entry.requestID
        entries.removeAll { entry in
            guard let requestID else { return false }
            return entry.requestID == requestID
        }
        entries.append(entry)
        task.runtimePermissionOpenRequestsJSON = encode(entries)
    }

    static func resolveOpenRequest(requestID: String, task: AgentTask) {
        let trimmed = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entries = typedEntries(for: task).filter { entry in
            entry.requestID != trimmed
        }
        task.runtimePermissionOpenRequestsJSON = encode(entries)
    }

    static func closeAllOpenRequests(for task: AgentTask) {
        task.runtimePermissionOpenRequestsJSON = "[]"
    }

    static func state(for task: AgentTask) -> TaskRuntimePermissionState {
        if let latest = latestTypedEntry(for: task) {
            return TaskRuntimePermissionState(
                latestRequestPayload: latest.payload,
                hasOpenApprovalRequest: true,
                decision: RuntimePermissionDecisionPresentation(payload: latest.payload),
                taskScopedGrants: PermissionBroker.taskScopedApprovalGrants(for: latest.grants)
            )
        }
        guard let latestPayload = latestCompatibilityRequestEvent(for: task)?.payload else {
            return .empty
        }
        let grants = compatibilityApprovalGrants(from: latestPayload)
        return TaskRuntimePermissionState(
            latestRequestPayload: latestPayload,
            hasOpenApprovalRequest: hasOpenRequest(for: task),
            decision: RuntimePermissionDecisionPresentation(payload: latestPayload),
            taskScopedGrants: PermissionBroker.taskScopedApprovalGrants(for: grants)
        )
    }

    static func hasOpenRequest(for task: AgentTask) -> Bool {
        if !typedEntries(for: task).isEmpty {
            return true
        }
        return RuntimePermissionOpenState.hasOpenRequest(events: compatibilityEvents(for: task))
    }

    static func latestRequestPayload(for task: AgentTask) -> String? {
        if let typed = latestTypedEntry(for: task)?.payload {
            return typed
        }
        return latestCompatibilityRequestEvent(for: task)?.payload
    }

    static func latestApprovalGrants(for task: AgentTask) -> [PermissionGrant] {
        if let typed = latestTypedEntry(for: task) {
            return typed.grants
        }
        return latestCompatibilityRequestEvent(for: task)
            .map { compatibilityApprovalGrants(from: $0.payload) } ?? []
    }

    static func latestRequestedToolName(for task: AgentTask) -> String? {
        if let typed = latestTypedEntry(for: task) {
            return permissionToolName(from: typed)
        }
        return latestCompatibilityRequestEvent(for: task).flatMap {
            compatibilityPermissionToolName(from: $0.payload)
        }
    }

    private static func latestTypedEntry(for task: AgentTask) -> Entry? {
        typedEntries(for: task).last
    }

    private static func typedEntries(for task: AgentTask) -> [Entry] {
        guard let data = (task.runtimePermissionOpenRequestsJSON ?? "[]").data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.requestedAt < $1.requestedAt }
    }

    private static func encode(_ entries: [Entry]) -> String {
        let ordered = entries.sorted { $0.requestedAt < $1.requestedAt }
        return (try? JSONEncoder().encode(ordered))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
    }

    private static func entry(from payload: String, requestedAt: Date) -> Entry {
        if let decoded = PermissionApprovalEventPayload.decoded(from: payload) {
            let requestGrants = PermissionBroker.approvalGrants(for: decoded.request)
            let grants = requestGrants.isEmpty ? decoded.grants : requestGrants
            return Entry(
                requestID: decoded.requestID,
                providerID: decoded.providerID,
                request: decoded.request,
                grants: PermissionBroker.sanitizeApprovedGrants(grants),
                displayMessage: decoded.displayMessage,
                payload: payload,
                requestedAt: requestedAt
            )
        }

        return Entry(
            requestID: nil,
            providerID: nil,
            request: nil,
            grants: PermissionBroker.legacyApprovalGrants(from: payload),
            displayMessage: payload,
            payload: payload,
            requestedAt: requestedAt
        )
    }

    private static func compatibilityApprovalGrants(from payload: String) -> [PermissionGrant] {
        let structured = PermissionBroker.structuredApprovalGrants(from: payload)
        if !structured.isEmpty { return structured }
        return PermissionBroker.legacyApprovalGrants(from: payload)
    }

    private static func permissionToolName(from entry: Entry) -> String? {
        if let request = entry.request {
            return toolName(for: request)
        }
        return compatibilityPermissionToolName(from: entry.payload)
    }

    private static func compatibilityPermissionToolName(from payload: String) -> String? {
        if let decoded = PermissionApprovalEventPayload.decoded(from: payload) {
            return toolName(for: decoded.request)
        }
        let patterns = [
            #"Permission (?:denied|requested) for tool: ([^.\n]+)"#,
            #""tool"\s*:\s*"([^"]+)""#,
            #""toolName"\s*:\s*"([^"]+)""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: payload, range: NSRange(payload.startIndex..., in: payload)),
                  let range = Range(match.range(at: 1), in: payload) else {
                continue
            }
            let value = String(payload[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func toolName(for request: PermissionRequest) -> String {
        switch request {
        case .tool(let name, _), .providerNativePrompt(let name, _):
            return name
        case .shell(_, let toolName):
            return toolName ?? "Bash"
        case .fileWrite(_, let toolName):
            return toolName ?? "Write"
        case .network(_, let toolName):
            return toolName ?? "WebFetch"
        case .credential(let label):
            return label
        }
    }

    private static func latestCompatibilityRequestEvent(for task: AgentTask) -> TaskEvent? {
        task.events
            .filter { $0.type == "permission.denied" || $0.type == "permission.approval.requested" }
            .sorted { $0.timestamp < $1.timestamp }
            .last
    }

    private static func compatibilityEvents(for task: AgentTask) -> [RuntimePermissionOpenState.Event] {
        task.events.map {
            RuntimePermissionOpenState.Event(type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
        }
    }
}
