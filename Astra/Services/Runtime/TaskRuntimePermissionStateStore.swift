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

    /// Resolve only the card the user approved, preserving independent asks.
    static func resolveRequest(payload: String, task: AgentTask) {
        if case .missing = typedState(for: task) {
            // Materialize the legacy event-backed request before resolving it.
            task.runtimePermissionOpenRequestsJSON = encode(unresolvedCompatibilityEntries(for: task))
        }
        let requestID = PermissionApprovalEventPayload.decoded(from: payload)?.requestID
        task.runtimePermissionOpenRequestsJSON = encode(typedEntries(for: task).filter {
            if let requestID { return $0.requestID != requestID }
            return $0.payload != payload
        })
    }

    static func state(for task: AgentTask) -> TaskRuntimePermissionState {
        switch typedState(for: task) {
        case .available(let entries):
            guard let latest = entries.last else { return .empty }
            return state(from: latest, task: task)
        case .invalid:
            AppLogger.audit(.taskFailed, category: "RuntimePermissionState", taskID: task.id, fields: [
                "reason": "runtime_permission_open_requests_decode_failed",
                "result": "typed_state_treated_as_closed"
            ], level: .error)
            return .empty
        case .missing:
            break
        }
        guard let latest = unresolvedCompatibilityEntries(for: task).last else { return .empty }
        return state(from: latest, task: task)
    }

    static func hasOpenRequest(for task: AgentTask) -> Bool {
        switch typedState(for: task) {
        case .available(let entries):
            return !entries.isEmpty
        case .invalid:
            return false
        case .missing:
            return !unresolvedCompatibilityEntries(for: task).isEmpty
        }
    }

    static func latestRequestPayload(for task: AgentTask) -> String? {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.last?.payload
        case .invalid:
            return nil
        case .missing:
            return unresolvedCompatibilityEntries(for: task).last?.payload
        }
    }

    static func openRequestPayloads(for task: AgentTask) -> [String] {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.map(\.payload)
        case .invalid:
            return []
        case .missing:
            return unresolvedCompatibilityEntries(for: task).map(\.payload)
        }
    }

    static func latestApprovalGrants(for task: AgentTask) -> [PermissionGrant] {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.last?.grants ?? []
        case .invalid:
            return []
        case .missing:
            return unresolvedCompatibilityEntries(for: task).last?.grants ?? []
        }
    }

    static func latestRequestedToolName(for task: AgentTask) -> String? {
        switch typedState(for: task) {
        case .available(let entries):
            return entries.last.flatMap { permissionToolName(from: $0) }
        case .invalid:
            return nil
        case .missing:
            return unresolvedCompatibilityEntries(for: task).last.flatMap(permissionToolName(from:))
        }
    }

    /// Auto authorizes provider-level requests, but it does not bypass the OS
    /// sandbox. Clear only requests whose enforcement tier Auto actually owns.
    @discardableResult
    /// The connector credential offers still open, with their grants: Auto
    /// grants these before it supersedes them, so switching a task to Auto
    /// answers the user's pending decision instead of dropping it.
    static func openConnectorCredentialOffers(for task: AgentTask) -> [(displayName: String, grants: [PermissionGrant])] {
        typedEntries(for: task).compactMap { entry in
            guard case .connectorCredentials(_, let displayName, _)? = entry.request else { return nil }
            let grants = entry.grants.filter { if case .credential = $0 { return true } else { return false } }
            return grants.isEmpty ? nil : (displayName, grants)
        }
    }

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
            let entries = unresolvedCompatibilityEntries(for: task)
            let remaining = entries.filter(requiresExplicitSandboxApproval)
            let closedCount = entries.count - remaining.count
            guard closedCount > 0 else { return 0 }
            task.runtimePermissionOpenRequestsJSON = encode(remaining)
            return closedCount
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
        case .missing: unresolvedCompatibilityEntries(for: task)
        case .invalid: []
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

    private static func state(from entry: Entry, task: AgentTask) -> TaskRuntimePermissionState {
        TaskRuntimePermissionState(
            latestRequestPayload: entry.payload,
            hasOpenApprovalRequest: true,
            decision: RuntimePermissionDecisionPresentation(payload: entry.payload,
                isFutureUse: TaskPermissionContinuation.isFutureUse(payload: entry.payload, task: task)),
            taskScopedGrants: PermissionBroker.taskScopedApprovalGrants(for: entry.grants)
        )
    }

    private static func requiresExplicitSandboxApproval(_ entry: Entry) -> Bool {
        guard let request = entry.request else { return false }
        if case .sandboxPath = request { return true }
        return false
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
        case .gitPublish:
            return "GitHub draft publication"
        case .connectorMutation(let authorization):
            return "\(authorization.serviceType.capitalized) \(authorization.operation)"
        }
    }

    private static func normalizedToolName(_ toolName: String?) -> String? {
        guard let trimmed = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func unresolvedCompatibilityEntries(for task: AgentTask) -> [Entry] {
        let events = task.events.filter { !$0.isDeleted }
        var entries: [Entry] = []
        for event in events.filter({ $0.type == "permission.approval.requested" })
            .sorted(by: { $0.timestamp < $1.timestamp }) {
            let candidate = entry(from: event.payload, requestedAt: event.timestamp)
            let resolved = events.contains { closure in
                guard closure.timestamp >= event.timestamp else { return false }
                if let id = candidate.requestID {
                    return closure.type == "permission.request.resolved"
                        && PermissionRequestResolution.decode(from: closure.payload)?.requestID == id
                }
                return closure.type == "task.approved"
            }
            guard !resolved else { continue }
            if let id = candidate.requestID { entries.removeAll { $0.requestID == id } }
            entries.append(candidate)
        }
        return entries
    }

}
