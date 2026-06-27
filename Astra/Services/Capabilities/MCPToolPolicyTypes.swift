import Foundation
import ASTRACore

struct AnySendable: @unchecked Sendable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral {
    private let storage: any Sendable

    init(_ value: some Sendable) {
        storage = value
    }

    init(stringLiteral value: String) {
        storage = value
    }

    init(dictionaryLiteral elements: (String, AnySendable)...) {
        storage = Dictionary(uniqueKeysWithValues: elements)
    }

    var description: String { "[payload]" }

    func value<T>(as type: T.Type = T.self) -> T? {
        storage as? T
    }
}

enum MCPToolPolicyCaller: Sendable, Equatable {
    case nativeRuntime
    case generatedWorkspaceApp(appID: UUID)
}

struct MCPToolNativeApproval: Sendable, Equatable {
    var approvedBy: String
    var approvedAt: Date
    var reason: String

    static func approved(
        by approvedBy: String = "local-user",
        at approvedAt: Date = Date(),
        reason: String
    ) -> MCPToolNativeApproval {
        MCPToolNativeApproval(approvedBy: approvedBy, approvedAt: approvedAt, reason: reason)
    }
}

struct MCPToolPolicyWorkspaceContext: Sendable, Equatable {
    var id: UUID
    var enabledPackageIDs: Set<String>
    var installedPackageIDs: Set<String>

    init(id: UUID, enabledPackageIDs: Set<String>, installedPackageIDs: Set<String>) {
        self.id = id
        self.enabledPackageIDs = enabledPackageIDs
        self.installedPackageIDs = installedPackageIDs
    }

    init(workspace: Workspace) {
        self.init(
            id: workspace.id,
            enabledPackageIDs: Set(workspace.enabledCapabilityIDs),
            installedPackageIDs: workspace.installedPluginIDSet
        )
    }
}

enum MCPToolPolicyDenialReason: String, Sendable, Equatable {
    case workspaceNotEnabled = "workspace_not_enabled"
    case toolExcluded = "tool_excluded"
    case toolNotAllowed = "tool_not_allowed"
    case unclassifiedTool = "unclassified_tool"
    case missingScope = "missing_scope"
    case generatedAppWriteRequiresNativeApproval = "generated_app_write_requires_native_approval"
    case nativeApprovalRequired = "native_approval_required"
    case rateLimited = "rate_limited"
}

struct MCPToolPolicyDecision: Sendable, Equatable {
    var isAllowed: Bool
    var denialReason: MCPToolPolicyDenialReason?
    var access: MCPToolAccessLevel?
    var missingScopes: Set<MCPToolPolicyScope>

    static func allow(access: MCPToolAccessLevel) -> MCPToolPolicyDecision {
        MCPToolPolicyDecision(isAllowed: true, denialReason: nil, access: access, missingScopes: [])
    }

    static func deny(
        _ reason: MCPToolPolicyDenialReason,
        access: MCPToolAccessLevel? = nil,
        missingScopes: Set<MCPToolPolicyScope> = []
    ) -> MCPToolPolicyDecision {
        MCPToolPolicyDecision(isAllowed: false, denialReason: reason, access: access, missingScopes: missingScopes)
    }
}

struct MCPToolPolicyRequest {
    var workspaceContext: MCPToolPolicyWorkspaceContext?
    var packages: [PluginPackage]
    var approvalRecords: [CapabilityApprovalRecord]
    var serverID: String
    var toolName: String
    var caller: MCPToolPolicyCaller
    var grantedScopes: Set<MCPToolPolicyScope>
    var nativeApproval: MCPToolNativeApproval?
    var now: Date
    var arguments: [String: AnySendable]

    var forwardRequest: MCPToolForwardRequest {
        MCPToolForwardRequest(
            serverID: serverID,
            toolName: toolName,
            caller: caller,
            arguments: arguments
        )
    }

    init(
        workspace: Workspace?,
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord],
        serverID: String,
        toolName: String,
        caller: MCPToolPolicyCaller,
        grantedScopes: Set<MCPToolPolicyScope>,
        nativeApproval: MCPToolNativeApproval?,
        now: Date,
        arguments: [String: AnySendable] = [:]
    ) {
        self.workspaceContext = workspace.map(MCPToolPolicyWorkspaceContext.init)
        self.packages = packages
        self.approvalRecords = approvalRecords
        self.serverID = serverID
        self.toolName = toolName
        self.caller = caller
        self.grantedScopes = grantedScopes
        self.nativeApproval = nativeApproval
        self.now = now
        self.arguments = arguments
    }
}

struct MCPToolPolicyAuditRecord: Sendable, Equatable {
    var result: String
    var workspaceID: String
    var packageID: String
    var serverID: String
    var toolName: String
    var access: String
    var caller: String
    var grantedScopes: String
    var requiredScopes: String
    var missingScopes: String
    var denialReason: String
    var argumentSummary: String

    var fields: [String: String] {
        [
            "result": result,
            "workspace_id": workspaceID,
            "package_id": packageID,
            "server_id": serverID,
            "tool_name": toolName,
            "access": access,
            "caller": caller,
            "granted_scopes": grantedScopes,
            "required_scopes": requiredScopes,
            "missing_scopes": missingScopes,
            "denial_reason": denialReason,
            "argument_summary": argumentSummary
        ]
    }
}

protocol MCPToolPolicyAuditSink: Sendable {
    func record(_ record: MCPToolPolicyAuditRecord)
}

struct AppLoggerMCPToolPolicyAuditSink: MCPToolPolicyAuditSink {
    func record(_ record: MCPToolPolicyAuditRecord) {
        AppLogger.audit(
            record.result == "allowed" ? .mcpToolPolicyAllowed : .mcpToolPolicyDenied,
            category: "Capabilities",
            fields: record.fields,
            level: record.result == "allowed" ? .info : .warning,
            fieldMaxLength: 160
        )
    }
}

final class MCPToolCallRateLimiter: @unchecked Sendable {
    private let maxPerWindow: Int
    private let window: TimeInterval
    private let lock = NSLock()
    private var history: [String: [Date]] = [:]

    init(maxPerWindow: Int, window: TimeInterval) {
        self.maxPerWindow = max(1, maxPerWindow)
        self.window = max(1, window)
    }

    func admit(workspaceID: UUID?, serverID: String, toolName: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = [
            workspaceID?.uuidString ?? "none",
            serverID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: ":")
        let cutoff = now.addingTimeInterval(-window)
        var recent = (history[key] ?? []).filter { $0 > cutoff }
        guard recent.count < maxPerWindow else {
            history[key] = recent
            return false
        }
        recent.append(now)
        history[key] = recent
        return true
    }
}
