import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// The workspace home's Capabilities tab lists what the right rail lists.
@Suite("Workspace home capability rows")
@MainActor
struct WorkspaceHomeCapabilityRowsTests {
    /// Retained for the process: a released container traps a later suite.
    private static var retained: [ModelContainer] = []

    private static func makeWorkspace(enabled: [String]) throws -> Workspace {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        retained.append(container)
        let workspace = Workspace(name: "Home Rows", primaryPath: "/tmp/home-capability-rows")
        container.mainContext.insert(workspace)
        workspace.testEnabledCapabilityIDs = enabled
        return workspace
    }

    private static func skillOnlyPackage(id: String, name: String) -> PluginPackage {
        PluginPackage(
            id: id,
            name: name,
            icon: "chevron.left.forwardslash.chevron.right",
            description: "A plugin whose only component is a skill",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [PluginSkill(
                name: "\(name) Agent",
                icon: "sparkles",
                description: "Skill",
                allowedTools: ["Read"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Help.",
                environmentKeys: [],
                environmentValues: []
            )],
            connectors: [],
            localTools: [],
            templates: []
        )
    }

    @Test("An enabled plugin with no Skill, Connector or Tool row of its own is listed, as the rail lists it")
    func skillOnlyPluginIsListed() throws {
        let github = Self.skillOnlyPackage(id: "github-workflow", name: "GitHub")
        let other = Self.skillOnlyPackage(id: "other-workflow", name: "Other")
        let workspace = try Self.makeWorkspace(enabled: [github.id])
        // The bug: the tab read only these rows, and this plugin saves none.
        #expect(workspace.skills.isEmpty && workspace.connectors.isEmpty && workspace.localTools.isEmpty)

        let catalog = ApprovedCapabilitiesSnapshot(packages: [github, other], records: [], packPolicy: .empty)
        let rows = WorkspaceHomeCapabilityRow.rows(
            workspace: workspace, globalSkills: [], globalConnectors: [], globalTools: [], catalog: catalog
        )

        #expect(rows.map(\.id) == [github.id])
        #expect(rows.first?.name == "GitHub")
        #expect(rows.first?.summary == "1 skill")

        // The rail's input, from the same rule.
        let capabilities = WorkspaceCapabilities(
            workspace: workspace, packageDefinitions: catalog.packages, packPolicy: catalog.packPolicy
        )
        let railEntries = WorkspaceActiveCapabilities.entries(
            workspace: workspace,
            capabilities: capabilities,
            catalogPackages: catalog.packages,
            policyContext: CapabilityCatalogPolicyContext.currentUser(
                workspace: workspace, approvalRecords: [], packPolicy: .empty
            )
        )
        #expect(Set(railEntries.map(\.package.id)) == Set(rows.map(\.id)))
    }

    @Test("A workspace's own skill is listed, its universal skills and their restored copies are not")
    func ownSkillListedUniversalSkillsNot() throws {
        let workspace = try Self.makeWorkspace(enabled: [])
        for name in ["Read-Only", "Safe Bash", "Test Runner", "Read-Only (Restored)", "Local Analyst"] {
            Skill(name: name, allowedTools: ["Read"]).workspace = workspace
        }

        let rows = WorkspaceHomeCapabilityRow.rows(
            workspace: workspace, globalSkills: [], globalConnectors: [], globalTools: [],
            catalog: ApprovedCapabilitiesSnapshot(packages: [], records: [], packPolicy: .empty)
        )

        #expect(rows.map(\.name) == ["Local Analyst"])
    }

    @Test("Rows are ordered by name and drop the restored suffix")
    func rowsAreOrderedByDisplayName() throws {
        let zeta = Self.skillOnlyPackage(id: "zeta-workflow", name: "Zeta")
        let alpha = Self.skillOnlyPackage(id: "alpha-workflow", name: "Alpha (Restored)")
        let workspace = try Self.makeWorkspace(enabled: [zeta.id, alpha.id])

        let rows = WorkspaceHomeCapabilityRow.rows(
            workspace: workspace, globalSkills: [], globalConnectors: [], globalTools: [],
            catalog: ApprovedCapabilitiesSnapshot(packages: [zeta, alpha], records: [], packPolicy: .empty)
        )

        #expect(rows.map(\.name) == ["Alpha", "Zeta"])
    }
}
