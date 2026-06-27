import Foundation

struct CapabilityMCPInstallReviewDraftState: Equatable {
    var draft: CapabilityMCPServerDraft
    var declaredEnvironmentKeys: Set<String>
}

enum CapabilityMCPInstallReviewDraftFactory {
    static func draftState(from intent: MCPInstallIntent) -> CapabilityMCPInstallReviewDraftState {
        if intent.serverSpecs.count == 1, let spec = intent.serverSpecs.first {
            return draftState(from: spec)
        }

        var draft = CapabilityMCPServerDraft()
        draft.serverID = intent.serverID ?? "mcp"
        draft.displayName = intent.displayName ?? intent.serverID ?? "MCP"
        draft.transport = intent.transport
        draft.command = intent.command ?? ""
        draft.argumentsText = intent.arguments.joined(separator: "\n")
        draft.urlText = intent.url?.absoluteString ?? ""
        draft.installSource = intent.installSource
        return CapabilityMCPInstallReviewDraftState(
            draft: draft,
            declaredEnvironmentKeys: []
        )
    }

    private static func draftState(from spec: MCPInstallServerSpec) -> CapabilityMCPInstallReviewDraftState {
        var draft = CapabilityMCPServerDraft()
        draft.serverID = spec.serverID
        draft.displayName = spec.displayName ?? spec.serverID
        draft.transport = spec.transport
        draft.command = spec.command ?? ""
        draft.argumentsText = spec.arguments.joined(separator: "\n")
        draft.urlText = spec.url?.absoluteString ?? ""
        draft.environmentKeysText = spec.environmentKeys.joined(separator: "\n")
        draft.installSource = spec.installSource
        return CapabilityMCPInstallReviewDraftState(
            draft: draft,
            declaredEnvironmentKeys: Set(spec.environmentKeys)
        )
    }
}
