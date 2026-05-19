import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeCapabilityActivationDisablerContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("CapabilityActivationDisablerTests")
@MainActor
struct CapabilityActivationDisablerTests {
    @Test("disabling package uses origin metadata before legacy name matching")
    func disablingPackageUsesOriginMetadataBeforeLegacyNameMatching() throws {
        let container = try makeCapabilityActivationDisablerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Disable Origin", primaryPath: "/tmp/disable-origin-dedicated")
        context.insert(workspace)

        let legacySkill = Skill(name: "Jira Agent", allowedTools: ["Read"])
        legacySkill.isGlobal = true
        context.insert(legacySkill)

        let ownedSkill = Skill(name: "Jira Agent Copy", allowedTools: ["Read"])
        ownedSkill.isGlobal = true
        ownedSkill.originPackageID = "jira-workflow"
        ownedSkill.originComponentID = "skill:jira-agent"
        ownedSkill.originComponentKind = "skill"
        context.insert(ownedSkill)

        let package = PluginPackage(
            id: "jira-workflow",
            name: "Jira Workflow",
            icon: "list.clipboard",
            description: "Jira workflow",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [
                PluginSkill(
                    name: "Jira Agent",
                    icon: "list.clipboard",
                    description: "Jira behavior",
                    allowedTools: ["Read"],
                    disallowedTools: [],
                    customTools: [],
                    behaviorInstructions: "Use Jira.",
                    environmentKeys: [],
                    environmentValues: []
                )
            ],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .builtInApproved(riskLevel: .medium)
        )
        workspace.enabledCapabilityIDs = [package.id]
        workspace.enabledGlobalSkillIDs = [legacySkill.id.uuidString, ownedSkill.id.uuidString]

        let result = CapabilityActivationDisabler().disable(
            package,
            in: workspace,
            capabilities: WorkspaceCapabilities(workspace: workspace, globalSkills: [legacySkill, ownedSkill]),
            modelContext: context,
            availablePackages: [package]
        )

        #expect(result.disabledSkillIDs == [ownedSkill.id])
        #expect(workspace.enabledGlobalSkillIDs == [legacySkill.id.uuidString])
        #expect(workspace.enabledCapabilityIDs.isEmpty)
    }
}
