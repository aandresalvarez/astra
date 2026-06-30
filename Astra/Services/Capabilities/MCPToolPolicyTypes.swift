import Foundation
import ASTRACore

struct AnySendable: Sendable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral {
    private let storageDescription: String

    init(_ value: some Sendable) {
        _ = value
        storageDescription = "[payload]"
    }

    init(stringLiteral value: String) {
        _ = value
        storageDescription = "[payload]"
    }

    init(dictionaryLiteral elements: (String, AnySendable)...) {
        _ = elements
        storageDescription = "[payload]"
    }

    var description: String { storageDescription }
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

enum MCPToolPolicyDenialReason: String, Sendable, Equatable {
    case workspaceNotEnabled = "workspace_not_enabled"
    case toolExcluded = "tool_excluded"
    case toolNotAllowed = "tool_not_allowed"
    case unclassifiedTool = "unclassified_tool"
    case missingScope = "missing_scope"
    case generatedAppWriteRequiresNativeApproval = "generated_app_write_requires_native_approval"
    case nativeApprovalRequired = "native_approval_required"
    case packPolicyNativeApprovalRequired = "pack_policy_native_approval_required"
    case rateLimited = "rate_limited"
}

struct MCPToolPolicyDecision: Sendable, Equatable {
    var isAllowed: Bool
    var denialReason: MCPToolPolicyDenialReason?
    var access: MCPToolAccessLevel?
    var missingScopes: Set<MCPToolPolicyScope>
    var policyEvidence: [PackPolicyEvidence]

    static func allow(
        access: MCPToolAccessLevel,
        policyEvidence: [PackPolicyEvidence] = []
    ) -> MCPToolPolicyDecision {
        MCPToolPolicyDecision(
            isAllowed: true,
            denialReason: nil,
            access: access,
            missingScopes: [],
            policyEvidence: policyEvidence
        )
    }

    static func deny(
        _ reason: MCPToolPolicyDenialReason,
        access: MCPToolAccessLevel? = nil,
        missingScopes: Set<MCPToolPolicyScope> = [],
        policyEvidence: [PackPolicyEvidence] = []
    ) -> MCPToolPolicyDecision {
        MCPToolPolicyDecision(
            isAllowed: false,
            denialReason: reason,
            access: access,
            missingScopes: missingScopes,
            policyEvidence: policyEvidence
        )
    }
}

struct MCPToolPolicyRequest: @unchecked Sendable {
    var workspace: Workspace?
    var packages: [PluginPackage]
    var approvalRecords: [CapabilityApprovalRecord]
    var serverID: String
    var toolName: String
    var caller: MCPToolPolicyCaller
    var grantedScopes: Set<MCPToolPolicyScope>
    var nativeApproval: MCPToolNativeApproval?
    var packPolicy: PackResolvedPolicy
    var now: Date
    var arguments: [String: AnySendable]

    init(
        workspace: Workspace?,
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord],
        serverID: String,
        toolName: String,
        caller: MCPToolPolicyCaller,
        grantedScopes: Set<MCPToolPolicyScope>,
        nativeApproval: MCPToolNativeApproval?,
        packPolicy: PackResolvedPolicy? = nil,
        packPolicyResolver: (Workspace?) -> PackResolvedPolicy = { PackWorkspacePolicyProvider.resolvedPolicy(for: $0) },
        now: Date,
        arguments: [String: AnySendable] = [:]
    ) {
        self.workspace = workspace
        self.packages = packages
        self.approvalRecords = approvalRecords
        self.serverID = serverID
        self.toolName = toolName
        self.caller = caller
        self.grantedScopes = grantedScopes
        self.nativeApproval = nativeApproval
        self.packPolicy = packPolicy ?? packPolicyResolver(workspace)
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
    var policyEvidence: String

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
            "policy_evidence": policyEvidence
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
