import Foundation
import ASTRACore

struct MCPToolPolicyEngine: Sendable {
    var registry: MCPToolClassificationRegistry
    var rateLimiter: MCPToolCallRateLimiter
    var auditSink: MCPToolPolicyAuditSink

    init(
        registry: MCPToolClassificationRegistry,
        rateLimiter: MCPToolCallRateLimiter = MCPToolCallRateLimiter(maxPerWindow: 120, window: 60),
        auditSink: MCPToolPolicyAuditSink = AppLoggerMCPToolPolicyAuditSink()
    ) {
        self.registry = registry
        self.rateLimiter = rateLimiter
        self.auditSink = auditSink
    }

    func evaluate(_ request: MCPToolPolicyRequest) -> MCPToolPolicyDecision {
        let resolved = resolvedServer(for: request)
        guard let resolved else {
            return finish(.deny(.workspaceNotEnabled), request: request, resolved: nil, classification: nil)
        }

        let server = resolved.server
        let requestedTool = normalized(request.toolName)
        if server.excludedTools.map({ normalized($0) }).contains(requestedTool) {
            return finish(.deny(.toolExcluded), request: request, resolved: resolved, classification: nil)
        }
        if !server.allowedTools.isEmpty,
           !server.allowedTools.map({ normalized($0) }).contains(requestedTool) {
            return finish(.deny(.toolNotAllowed), request: request, resolved: resolved, classification: nil)
        }

        guard let classification = registry.classification(serverID: server.id, toolName: request.toolName) else {
            return finish(.deny(.unclassifiedTool), request: request, resolved: resolved, classification: nil)
        }

        let missingScopes = classification.requiredScopes.subtracting(request.grantedScopes)
        if !missingScopes.isEmpty {
            return finish(
                .deny(.missingScope, access: classification.access, missingScopes: missingScopes),
                request: request,
                resolved: resolved,
                classification: classification
            )
        }

        if classification.access.requiresNativeApproval {
            if case .generatedWorkspaceApp = request.caller {
                return finish(
                    .deny(.generatedAppWriteRequiresNativeApproval, access: classification.access),
                    request: request,
                    resolved: resolved,
                    classification: classification
                )
            }
            guard request.nativeApproval != nil else {
                return finish(
                    .deny(.nativeApprovalRequired, access: classification.access),
                    request: request,
                    resolved: resolved,
                    classification: classification
                )
            }
        }

        guard rateLimiter.admit(
            workspaceID: request.workspace?.id,
            serverID: request.serverID,
            toolName: request.toolName,
            now: request.now
        ) else {
            return finish(
                .deny(.rateLimited, access: classification.access),
                request: request,
                resolved: resolved,
                classification: classification
            )
        }

        return finish(.allow(access: classification.access), request: request, resolved: resolved, classification: classification)
    }

    private func resolvedServer(for request: MCPToolPolicyRequest) -> MCPRuntimeProjection.ResolvedServer? {
        MCPRuntimeProjection.enabledServers(
            for: request.workspace,
            packages: request.packages,
            approvalRecords: request.approvalRecords
        )
        .first { normalized($0.server.id) == normalized(request.serverID) }
    }

    private func finish(
        _ decision: MCPToolPolicyDecision,
        request: MCPToolPolicyRequest,
        resolved: MCPRuntimeProjection.ResolvedServer?,
        classification: MCPToolClassification?
    ) -> MCPToolPolicyDecision {
        auditSink.record(auditRecord(
            decision: decision,
            request: request,
            resolved: resolved,
            classification: classification
        ))
        return decision
    }

    private func auditRecord(
        decision: MCPToolPolicyDecision,
        request: MCPToolPolicyRequest,
        resolved: MCPRuntimeProjection.ResolvedServer?,
        classification: MCPToolClassification?
    ) -> MCPToolPolicyAuditRecord {
        let requiredScopes = classification?.requiredScopes ?? []
        let missingScopes = decision.missingScopes
        return MCPToolPolicyAuditRecord(
            result: decision.isAllowed ? "allowed" : "denied",
            workspaceID: request.workspace?.id.uuidString ?? "none",
            packageID: resolved?.packageID ?? "none",
            serverID: auditValue(request.serverID),
            toolName: auditValue(request.toolName),
            access: (classification?.access ?? decision.access)?.rawValue ?? "unknown",
            caller: callerName(request.caller),
            grantedScopes: scopeList(request.grantedScopes),
            requiredScopes: scopeList(requiredScopes),
            missingScopes: scopeList(missingScopes),
            denialReason: decision.denialReason?.rawValue ?? "none"
        )
    }

    private func scopeList(_ scopes: Set<MCPToolPolicyScope>) -> String {
        guard !scopes.isEmpty else { return "none" }
        return scopes.sorted().map(\.rawValue).joined(separator: ",")
    }

    private func callerName(_ caller: MCPToolPolicyCaller) -> String {
        switch caller {
        case .nativeRuntime:
            return "native_runtime"
        case .generatedWorkspaceApp:
            return "generated_workspace_app"
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func auditValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
