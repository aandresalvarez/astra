import Foundation
import ASTRACore
import ASTRAModels

enum ProviderArtifactBootstrapPolicy {
    static func launchTools(
        task: AgentTask,
        followsUpDeliveredRequest: Bool,
        permissionPolicy: PermissionPolicy,
        providerAllowedTools: [String],
        askFirstTools: [String]
    ) -> [String] {
        guard permissionPolicy == .restricted,
              !followsUpDeliveredRequest,
              TaskDeliverableExpectation.requiresDeliverableArtifact(task),
              !providerAllowedTools.contains(where: isFileMutationTool),
              askFirstTools.contains(where: isFileMutationTool) else {
            return []
        }
        return ["Write"]
    }

    static func persistedLaunchTools(
        task: AgentTask,
        followsUpDeliveredRequest: Bool,
        permissionPolicy: PermissionPolicy,
        providerAllowedTools: [String],
        askFirstTools: [String]
    ) -> [String] {
        if !launchTools(
            task: task,
            followsUpDeliveredRequest: followsUpDeliveredRequest,
            permissionPolicy: permissionPolicy,
            providerAllowedTools: providerAllowedTools,
            askFirstTools: askFirstTools
        ).isEmpty {
            return ["Write"]
        }
        guard permissionPolicy == .restricted,
              !followsUpDeliveredRequest,
              TaskDeliverableExpectation.requiresDeliverableArtifact(task),
              providerAllowedTools.contains(where: { normalizedToolName($0) == "write" }),
              askFirstTools.contains(where: isFileMutationTool) else {
            return []
        }
        return ["Write"]
    }

    static func isFileMutationTool(_ tool: String) -> Bool {
        switch normalizedToolName(tool) {
        case "write", "create", "edit", "multiedit", "multi_edit":
            return true
        default:
            return false
        }
    }

    static func normalizedToolName(_ tool: String) -> String {
        tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
