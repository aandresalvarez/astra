import Foundation
import ASTRACore

enum ProviderPathPersistenceState {
    static func persistedPath(
        for runtime: AgentRuntimeID,
        claudePath: String,
        copilotPath: String,
        providerPath: String
    ) -> String {
        switch runtime {
        case .claudeCode: claudePath
        case .copilotCLI: copilotPath
        default: providerPath
        }
    }

    static func hasUnsavedDraft(draft: String?, persisted: String) -> Bool {
        (draft ?? persisted) != persisted
    }
}
