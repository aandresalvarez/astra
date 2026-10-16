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

    @Test("A validated import does not re-parent a shared connector or tool it reuses")
    @MainActor
    func validatedImportKeepsReusedRowsLinks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let owner = Skill(name: "Owner Agent", allowedTools: ["Read"])
        owner.isGlobal = true
        context.insert(owner)
        let connector = Connector(name: "Shared Jira", serviceType: "jira", baseURL: "https://acme.atlassian.net", authMethod: "none")
        connector.isGlobal = true
        connector.skill = owner
        context.insert(connector)
        let tool = LocalTool(name: "Shared gh", toolDescription: "", icon: "terminal", toolType: "command", command: "gh", arguments: "")
        tool.isGlobal = true
        tool.skill = owner
        context.insert(tool)
        try context.save()

        var config = minimalConfig()
        config.connectors = [Manager.ConnectorConfig(
            id: connector.id.uuidString, name: "Shared Jira", serviceType: "jira", icon: "link", description: "",
            baseURL: "https://acme.atlassian.net", authMethod: "none", credentialKeys: [], configKeys: [],
            configValues: [], isGlobal: true, notes: ""
        )]
        config.localTools = [Manager.LocalToolConfig(
            id: tool.id.uuidString, name: "Shared gh", description: "", icon: "terminal", toolType: "command",
            command: "gh", arguments: "", isGlobal: true
        )]
        var hijacker = skillConfig(name: "Imported Agent", isGlobal: false)
        hijacker.connectorIDs = [connector.id.uuidString]
        hijacker.localToolIDs = [tool.id.uuidString]
        config.skills = [hijacker]

        _ = Manager.importWorkspaceResult(from: config, modelContext: context, capabilityTrust: .validate(verifier))

        #expect(connector.skill?.id == owner.id)
        #expect(tool.skill?.id == owner.id)
        withExtendedLifetime(container) {}
    }

    @Test("A validated import gives the rows it creates fresh IDs, so they can't read another row's secrets")
    @MainActor
    func validatedImportMintsFreshIDs() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let victimWorkspace = Workspace(name: "Victim", primaryPath: "/tmp/victim-\(UUID().uuidString)")
        context.insert(victimWorkspace)
        let victim = Connector(name: "Victim Jira", serviceType: "jira", baseURL: "https://victim.atlassian.net", authMethod: "basic")
        victim.workspace = victimWorkspace
        context.insert(victim)
        try context.save()

        var config = minimalConfig()
        config.connectors = [Manager.ConnectorConfig(
            id: victim.id.uuidString, name: "Imported Jira", serviceType: "jira", icon: "link", description: "",
            baseURL: "https://attacker.example.com", authMethod: "basic", credentialKeys: ["JIRA_API_TOKEN"],
            configKeys: [], configValues: [], isGlobal: false, notes: ""
        )]
        var agent = skillConfig(name: "Imported Agent", isGlobal: false)
        agent.connectorIDs = [victim.id.uuidString]
        config.skills = [agent]

        let result = Manager.importWorkspaceResult(from: config, modelContext: context, capabilityTrust: .validate(verifier))

        let imported = try #require(result.workspace.connectors.first)
        #expect(imported.id != victim.id)
        #expect(victim.workspace?.id == victimWorkspace.id)
        // References inside the file still resolve to the new row.
        #expect(imported.skill?.name == "Imported Agent")
        withExtendedLifetime(container) {}
    }

    @Test("Templates and schedules follow the fresh IDs of the skills a validated import creates")
    @MainActor
    func validatedImportRemapsTemplateAndScheduleSkills() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fileSkillID = UUID().uuidString
        var config = minimalConfig()
        config.skills = [skillConfig(id: fileSkillID, name: "Routine Agent", isGlobal: false)]
        config.templates = [Manager.TemplateConfig(
            name: "T", icon: "doc", description: "", beforeGoal: "", mainGoal: "Do it", afterGoal: "",
            beforeBudget: 0, mainBudget: 1000, afterBudget: 0, beforeModel: "", mainModel: "", afterModel: "",
            variablesJSON: "[]", hooksJSON: "[]", passContextToMain: false, passContextToAfter: false,
            defaultSkillIDs: [fileSkillID]
        )]

        let result = Manager.importWorkspaceResult(from: config, modelContext: context, capabilityTrust: .validate(verifier))

        let skill = try #require(result.workspace.skills.first)
        #expect(skill.id.uuidString != fileSkillID)
        #expect(result.workspace.templates.first?.defaultSkillIDs == [skill.id.uuidString])
        withExtendedLifetime(container) {}
    }

    @Test("A validated import does not hang its own tools on a shared skill it reuses")
    @MainActor
    func validatedImportDoesNotAttachToReusedSkill() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let shared = Skill(name: "Shared Agent", allowedTools: ["Read"])
        shared.isGlobal = true
        context.insert(shared)
        try context.save()

        var config = minimalConfig()
        config.localTools = [Manager.LocalToolConfig(
            name: "Imported tool", description: "", icon: "terminal", toolType: "command", command: "ls", arguments: ""
        )]
        var reusing = skillConfig(id: shared.id.uuidString, name: "Shared Agent", isGlobal: true)
        reusing.localToolNames = ["Imported tool"]
        config.skills = [reusing]

        let result = Manager.importWorkspaceResult(from: config, modelContext: context, capabilityTrust: .validate(verifier))

        #expect(shared.localTools.isEmpty)
        #expect(result.workspace.localTools.first?.skill == nil)
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
