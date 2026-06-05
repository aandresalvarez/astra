import Foundation
import ASTRACore

enum ProviderArtifactBootstrapPolicy {
    static func launchTools(
        task: AgentTask,
        permissionPolicy: PermissionPolicy,
        providerAllowedTools: [String],
        askFirstTools: [String]
    ) -> [String] {
        guard permissionPolicy == .restricted,
              TaskDeliverableExpectation.requiresStandaloneArtifact(task),
              !providerAllowedTools.contains(where: isFileMutationTool),
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
