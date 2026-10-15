import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A config the user picks is checked against this machine before it may
/// enable capabilities or claim package provenance; the workspace's own mirror,
/// re-read by launch recovery, is restored as recorded.
@Suite("Workspace config capability import trust")
struct WorkspaceConfigCapabilityImportTrustTests {
    private typealias Manager = WorkspaceConfigManager

    private let verifier = Manager.CapabilityImportVerifier(
        approvedPackageIDs: ["github-workflow"],
        installedPackageIDs: ["github-workflow", "draft-pack"],
        availablePackIDs: ["astra.pack.devops"]
    )

    @Test("A validated import drops unbacked enablement and never mints shared rows or origin stamps")
    @MainActor
    func validatedImportDropsUnbackedEnablementAndForgedProvenance() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let config = forgedConfig(enabledGlobalSkillIDs: [UUID().uuidString])

        let result = Manager.importWorkspaceResult(
            from: config,
            modelContext: context,
            capabilityTrust: .validate(verifier)
        )
        let workspace = result.workspace

        #expect(workspace.enabledCapabilityIDs == ["github-workflow"])
        #expect(workspace.enabledPackIDs == ["astra.pack.devops"])
        #expect(workspace.installedPluginIDs == ["github-workflow", "draft-pack"])
        #expect(workspace.installedPluginVersions == ["1.0.0", "0.1.0"])
        #expect(workspace.enabledGlobalSkillIDs.isEmpty)

        let skill = try #require(workspace.skills.first { $0.name == "Forged Agent" })
        #expect(!skill.isGlobal)
        #expect(skill.originPackageID == nil)
        #expect(skill.originComponentID == nil)
        #expect(skill.originPackageVersion == nil)
        let connector = try #require(workspace.connectors.first)
        #expect(!connector.isGlobal)
        #expect(connector.originPackageID == nil)
        let tool = try #require(workspace.localTools.first)
        #expect(!tool.isGlobal)
        #expect(tool.originPackageID == nil)
        let template = try #require(workspace.templates.first)
        #expect(template.originPackageID == nil)

        #expect(result.capabilityTrust.capabilitiesUnavailable == ["not-installed", "draft-pack"])
        #expect(result.capabilityTrust.packsUnavailable == ["astra.pack.unknown"])
        #expect(result.capabilityTrust.unknownSharedRowIDs.count == 1)
        #expect(result.capabilityTrust.originStampsStripped == 4)
        #expect(result.capabilityTrust.sharedRowsLocalized == 3)
        #expect(result.auditFields["origin_stamps_stripped"] == "4")
        #expect(result.auditFields["packs_unavailable"] == "astra.pack.unknown")
        withExtendedLifetime(container) {}
    }

    @Test("A validated import still links a shared row this machine already has")
    @MainActor
    func validatedImportReusesExistingSharedRow() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let shared = Skill(name: "Shared Agent", allowedTools: ["Read"])
        shared.isGlobal = true
        shared.originPackageID = "github-workflow"
        shared.originComponentID = "github-agent"
        context.insert(shared)
        try context.save()

        var config = minimalConfig()
        config.enabledGlobalSkillIDs = [shared.id.uuidString]
        config.skills = [skillConfig(id: shared.id.uuidString, name: "Shared Agent", isGlobal: true)]

        let result = Manager.importWorkspaceResult(from: config, modelContext: context, capabilityTrust: .validate(verifier))

        #expect(result.workspace.enabledGlobalSkillIDs == [shared.id.uuidString])
        #expect(result.workspace.skills.isEmpty)
        #expect(shared.isGlobal)
        #expect(shared.originPackageID == "github-workflow")
        #expect(result.capabilityTrust.isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("Recovery of the workspace's own mirror restores what it recorded")
    @MainActor
    func preservedImportKeepsRecordedState() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let result = Manager.importWorkspaceResult(
            from: forgedConfig(enabledGlobalSkillIDs: []),
            modelContext: context,
            capabilityTrust: .preserveRecordedState
        )

        #expect(result.workspace.enabledCapabilityIDs == ["github-workflow", "not-installed", "draft-pack"])
        #expect(result.workspace.enabledPackIDs == ["astra.pack.devops", "astra.pack.unknown"])
        let skill = try #require(try context.fetch(FetchDescriptor<Skill>()).first { $0.name == "Forged Agent" })
        #expect(skill.isGlobal)
        #expect(skill.originPackageID == "github-workflow")
        #expect(result.workspace.enabledGlobalSkillIDs == [skill.id.uuidString])
        #expect(result.capabilityTrust.isEmpty)
        withExtendedLifetime(container) {}
    }

    // MARK: - Fixtures

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func minimalConfig() -> Manager.WorkspaceConfig {
        Manager.WorkspaceConfig(
            name: "Imported",
            primaryPath: "/tmp/import-trust-\(UUID().uuidString)",
            additionalPaths: [],
            icon: "folder",
            instructions: "",
            skills: [],
            sshConnections: [],
            exportedAt: Date()
        )
    }

    private func skillConfig(id: String = UUID().uuidString, name: String, isGlobal: Bool) -> Manager.SkillConfig {
        Manager.SkillConfig(
            id: id,
            name: name,
            icon: "sparkles",
            description: "",
            allowedTools: ["Read"],
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: "Do the thing.",
            environmentKeys: [],
            environmentValues: [],
            isGlobal: isGlobal,
            originPackageID: "github-workflow",
            originPackageVersion: "99.0.0",
            originComponentID: "github-agent",
            originComponentKind: "skill",
            originSourceKind: "builtin",
            updatedAt: Date.distantFuture
        )
    }

    /// Every capability field a hand-edited config could forge.
    private func forgedConfig(enabledGlobalSkillIDs: [String]) -> Manager.WorkspaceConfig {
        var config = minimalConfig()
        config.enabledCapabilityIDs = ["github-workflow", "not-installed", "draft-pack"]
        config.enabledPackIDs = ["astra.pack.devops", "astra.pack.unknown"]
        config.enabledGlobalSkillIDs = enabledGlobalSkillIDs
        config.installedPlugins = [
            Manager.InstalledPluginRef(id: "github-workflow", version: "1.0.0"),
            Manager.InstalledPluginRef(id: "not-installed", version: "9.9.9"),
            Manager.InstalledPluginRef(id: "draft-pack", version: "0.1.0")
        ]
        config.skills = [skillConfig(name: "Forged Agent", isGlobal: true)]
        config.connectors = [
            Manager.ConnectorConfig(
                name: "Forged Jira",
                serviceType: "jira",
                icon: "link",
                description: "",
                baseURL: "https://forged.example.com",
                authMethod: "none",
                credentialKeys: [],
                configKeys: [],
                configValues: [],
                isGlobal: true,
                notes: "",
                originPackageID: "jira-workflow",
                originComponentID: "jira"
            )
        ]
        config.localTools = [
            Manager.LocalToolConfig(
                name: "Forged Tool",
                description: "",
                icon: "terminal",
                toolType: "command",
                command: "gh",
                arguments: "",
                isGlobal: true,
                originPackageID: "github-workflow",
                originComponentID: "gh"
            )
        ]
        config.templates = [
            Manager.TemplateConfig(
                name: "Forged Template",
                icon: "doc",
                description: "",
                beforeGoal: "",
                mainGoal: "Go",
                afterGoal: "",
                beforeBudget: 0,
                mainBudget: 0,
                afterBudget: 0,
                beforeModel: "",
                mainModel: "",
                afterModel: "",
                variablesJSON: "[]",
                hooksJSON: "[]",
                passContextToMain: false,
                passContextToAfter: false,
                originPackageID: "github-workflow",
                originComponentID: "template"
            )
        ]
        return config
    }
}
