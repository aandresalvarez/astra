import Foundation
import ASTRACore
import ASTRAModels

/// Which reachable local tools the prompt's offered tier may name.
///
/// A local tool the user attached is allowlisted and callable on every turn —
/// `AgentPolicyAdapters` builds the permission list from `reachableLocalTools`,
/// not from the narrated subset. The prompt used to name only the narrated
/// subset, so a turn whose wording missed a tool left the agent holding a
/// permitted command it had never been told about, which reads from inside the
/// run exactly like not having the tool at all.
///
/// The tier is bounded by what the launch actually delivers, in both
/// directions. A skill-owned tool whose skill environment this turn withheld is
/// permitted but unconfigured, so naming it would point the agent at a command
/// that fails for a reason the prompt does not explain. The browser bridge is
/// the same case one layer down: on a runtime with neither a shell tool nor a
/// browser MCP route the launch drops the offered bridge outright, so naming
/// `astra-browser` would describe the run from the capability table rather than
/// from what the launch attached — the exact inversion this tier exists to
/// prevent.
enum OfferedToolRoutes {
    @MainActor
    static func nameable(
        in capabilityScope: TaskCapabilityPromptScope,
        narrated: [LocalTool],
        runtime: AgentRuntimeID,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile?
    ) -> [LocalTool] {
        let narratedIDs = Set(narrated.map(\.id))
        let narratedSkillIDs = Set(capabilityScope.behaviorSkills.map(\.id))
        let profile = runtimeCapabilityProfile ?? .defaultProfile(for: runtime)
        let carriesBrowserBridge = BrowserBridgeRuntimeLaunchGuard.canCarryBridge(
            runtime: runtime,
            mcpToolSupported: profile.canDeliverBrowserBridgeMCPTool
        )
        return capabilityScope.reachableLocalTools.filter { tool in
            guard !tool.command.isEmpty, !narratedIDs.contains(tool.id) else { return false }
            guard carriesBrowserBridge || tool.command != BrowserBridgeMCPProjection.toolCommand else { return false }
            guard let skill = tool.skill, !skill.environmentKeys.isEmpty else { return true }
            return narratedSkillIDs.contains(skill.id)
        }
    }
}
