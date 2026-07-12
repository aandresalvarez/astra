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
        switch typedState(for: task) {
        case .available(let entries):
            guard let latest = entries.last else { return .empty }
            return state(from: latest)
        case .invalid:
            AppLogger.audit(.taskFailed, category: "RuntimePermissionState", taskID: task.id, fields: [
                "reason": "runtime_permission_open_requests_decode_failed",
                "result": "typed_state_treated_as_closed"
            ], level: .error)
            return .empty
        case .missing:
            break
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
        switch typedState(for: task) {
        case .available(let entries):
            return !entries.isEmpty
        case .invalid:
            return false
        case .missing:
            return RuntimePermissionOpenState.hasOpenRequest(events: compatibilityEvents(for: task))
        }
    }

    static func latestRequestPayload(for task: AgentTask) -> String? {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.last?.payload
        case .invalid:
            return nil
        case .missing:
            return latestCompatibilityRequestEvent(for: task)?.payload
        }
    }

    static func openRequestPayloads(for task: AgentTask) -> [String] {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.map(\.payload)
        case .invalid:
            return []
        case .missing:
            guard hasOpenRequest(for: task),
                  let payload = latestCompatibilityRequestEvent(for: task)?.payload else {
                return []
            }
            return [payload]
        }
    }

    static func latestApprovalGrants(for task: AgentTask) -> [PermissionGrant] {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.last?.grants ?? []
        case .invalid:
            return []
        case .missing:
            return latestCompatibilityRequestEvent(for: task)
                .map { compatibilityApprovalGrants(from: $0.payload) } ?? []
        }
    }

    static func latestRequestedToolName(for task: AgentTask) -> String? {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.last.flatMap { permissionToolName(from: $0) }
        case .invalid:
            return nil
        case .missing:
            return latestCompatibilityRequestEvent(for: task).flatMap {
                compatibilityPermissionToolName(from: $0.payload)
            }
        }
    }

    /// Auto authorizes provider-level requests, but it does not bypass the OS
    /// sandbox. Clear only requests whose enforcement tier Auto actually owns.
    @discardableResult
    static func closeRequestsAuthorizedByAutonomousPolicy(for task: AgentTask) -> Int {
        switch typedState(for: task) {
        case .available(let entries):
            let remaining = entries.filter(requiresExplicitSandboxApproval)
            let closedCount = entries.count - remaining.count
            guard closedCount > 0 else { return 0 }
            task.runtimePermissionOpenRequestsJSON = encode(remaining)
            return closedCount
        case .invalid:
            task.runtimePermissionOpenRequestsJSON = "[]"
            return 0
        case .missing:
            guard hasOpenRequest(for: task),
                  let latest = latestCompatibilityRequestEvent(for: task),
                  !requiresExplicitSandboxApproval(entry(from: latest.payload, requestedAt: latest.timestamp)) else {
                return 0
            }
            task.runtimePermissionOpenRequestsJSON = "[]"
            return 1
        }
    }

    private enum TypedState {
        case missing
        case invalid
        case available([Entry])
    }

    private static func typedEntries(for task: AgentTask) -> [Entry] {
        switch typedState(for: task) {
        case .available(let entries): entries
        case .missing, .invalid: []
        }
    }

    private static func typedState(for task: AgentTask) -> TypedState {
        guard let raw = task.runtimePermissionOpenRequestsJSON else { return .missing }
        guard let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return .invalid }
        return .available(entries.sorted { $0.requestedAt < $1.requestedAt })
    }

    private static func encode(_ entries: [Entry]) -> String {
        let ordered = entries.sorted { $0.requestedAt < $1.requestedAt }
        return (try? JSONEncoder().encode(ordered))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
    }

    private static func entry(from payload: String, requestedAt: Date) -> Entry {
        if let decoded = PermissionApprovalEventPayload.decoded(from: payload) {
            let grants = PermissionBroker.structuredApprovalGrants(from: payload)
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

    private static func state(from entry: Entry) -> TaskRuntimePermissionState {
        TaskRuntimePermissionState(
            latestRequestPayload: entry.payload,
            hasOpenApprovalRequest: true,
            decision: RuntimePermissionDecisionPresentation(payload: entry.payload),
            taskScopedGrants: PermissionBroker.taskScopedApprovalGrants(for: entry.grants)
        )
    }

    private static func requiresExplicitSandboxApproval(_ entry: Entry) -> Bool {
        guard let request = entry.request else { return false }
        if case .sandboxPath = request { return true }
        return false
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
        case .credential, .connectorCredentials:
            return "Connector credentials"
        case .sandboxPath(_, _, let toolName):
            return normalizedToolName(toolName) ?? "Local sandbox"
        }
    }

    private static func normalizedToolName(_ toolName: String?) -> String? {
        guard let trimmed = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
