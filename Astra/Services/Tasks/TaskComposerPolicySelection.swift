import Foundation
import ASTRACore

enum TaskComposerPolicySelection {
    static func applyingComposerPolicy(
        _ level: AgentPolicyLevel,
        to selection: TaskRoleProfileSelection,
        source: String
    ) -> TaskRoleProfileSelection {
        var updated = selection
        let normalizedLevel = level.userFacingLevel
        let originalLevel = updated.profile.policyLevel
        updated.profile.policyLevelRaw = normalizedLevel.rawValue
        if originalLevel != normalizedLevel {
            updated.source = source
        }
        return updated
    }
}
