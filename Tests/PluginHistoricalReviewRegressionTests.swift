import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Historical plugin review regressions", .serialized)
struct PluginHistoricalReviewRegressionTests {
    @Test("A binding's workspace alias wins over the same account on a pinned authored skill")
    func bindingAliasWinsPinnedAttachment() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(package.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let spec = try #require(package.connectors.first)
        let account = Connector(name: "Original shared account", serviceType: spec.serviceType,
            baseURL: spec.baseURL, authMethod: spec.authMethod)
        account.isGlobal = true
        let skill = Skill(name: "Authored support helper")
        skill.workspace = env.workspace
        let task = AgentTask(title: "Jira", goal: "Read Jira issues", workspace: env.workspace)
        for row in [account, skill, task] as [any PersistentModel] { env.context.insert(row) }
        account.skill = skill
        task.skills = [skill]
        WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: spec),
            of: activation, alias: "Workspace support")
        try env.context.save()
        let inventory = TaskCapabilityResolver(task: task, secretStore: MockSecretStore()).resourceInventory
        let resolved = try #require(inventory.connectors.first { $0.id == account.id })
        #expect(resolved.name == "Workspace support")
        #expect(resolved !== account)
        #expect(account.name == "Original shared account")
    }

    @Test("A deferred V19 migration preserves enabled skills and their local tools", arguments: [false, true])
    func deferredMigrationKeepsSkillAndTools(workspaceScopedRows: Bool) throws {
        let fixture = try PluginMigrationFixture(workspaceScopedRows: workspaceScopedRows)
        let originalSkill = try #require(try fixture.context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        let expectedToolIDs = Set(originalSkill.localTools.map(\.id))
        let expectedAccountIDs = Set(originalSkill.connectors.map(\.id))
        #expect(!expectedToolIDs.isEmpty)
        #expect(!expectedAccountIDs.isEmpty)
        try FileManager.default.createDirectory(at: fixture.storeDirectory.appendingPathComponent("PluginSecretCleanup.json", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(throws: PluginActivationMigration.MigrationError.cleanupUnrecordable) {
            try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        }
        let workspace = try fixture.workspace(fixture.aID)
        let skill = try #require(try fixture.context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        #expect(Set(skill.localTools.map(\.id)) == expectedToolIDs)
        #expect(Set(skill.connectors.map(\.id)) == expectedAccountIDs)
        #expect(try fixture.context.fetch(FetchDescriptor<Connector>()).filter { expectedAccountIDs.contains($0.id) }
            .allSatisfy { $0.skill?.id == fixture.gcloudSkillID })
        #expect(try fixture.context.fetch(FetchDescriptor<LocalTool>()).filter { expectedToolIDs.contains($0.id) }
            .allSatisfy { $0.skill?.id == fixture.gcloudSkillID })
        // Skill-only access: no enabled account may indirectly reintroduce
        // the skill and hide a missing legacy projection.
        workspace.enabledGlobalConnectorIDs.removeAll { $0 == fixture.sharedGCloudID.uuidString }
        let account = Connector(name: "Legacy own attachment", serviceType: "custom", authMethod: "none")
        account.workspace = workspace
        account.skill = skill
        fixture.context.insert(account)
        let task = AgentTask(title: "GCloud", goal: "Manage GCP resources", workspace: workspace)
        fixture.context.insert(task)
        for launch in [task, TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: task), from: task)] {
            let inventory = TaskCapabilityResolver(task: launch, secretStore: MockSecretStore()).resourceInventory
            #expect(inventory.behaviorSkills.contains { $0.id == fixture.gcloudSkillID })
            #expect(expectedToolIDs.isSubset(of: Set(inventory.localTools.map(\.id))))
            #expect(inventory.connectors.contains { $0.id == account.id })
        }
    }
    @Test("A shared override mirror follows runtime attachment visibility", arguments: [false, true])
    func mirrorKeepsOnlyVisibleAttachments(sharedSelected: Bool) throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(package.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let foreign = Workspace(name: "Other", primaryPath: env.root.appendingPathComponent("Other").path)
        let skill = Skill(name: "Shared authored override")
        skill.isGlobal = true
        env.context.insert(foreign)
        env.context.insert(skill)
        WorkspaceCapabilityActivation.setOverridden(true, componentID: CapabilityResourceOrigin.componentID(for: package.skills[0]),
            rowID: skill.id, on: activation)
        var accounts: [Connector] = []
        var tools: [LocalTool] = []
        for role in ["own", "foreign", "shared"] {
            let account = Connector(name: role, serviceType: "custom", authMethod: "none")
            let tool = LocalTool(name: role, toolType: "cli", command: "echo", arguments: role)
            if role == "shared" { account.isGlobal = true; tool.isGlobal = true }
            else { account.workspace = role == "own" ? env.workspace : foreign; tool.workspace = role == "own" ? env.workspace : foreign }
            env.context.insert(account)
            env.context.insert(tool)
            account.skill = skill
            tool.skill = skill
            accounts.append(account)
            tools.append(tool)
        }
        if sharedSelected {
            env.workspace.enabledGlobalConnectorIDs = [accounts[2].id.uuidString]
            env.workspace.enabledGlobalToolIDs = [tools[2].id.uuidString]
        }
        try env.context.save()
        let config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        let expectedAccounts = Set(([accounts[0]] + (sharedSelected ? [accounts[2]] : [])).map { $0.id.uuidString })
        // Shared tools attached to this chosen skill are reachable without
        // a separate standalone-tool selection; foreign local tools are not.
        let expectedTools = Set([tools[0], tools[2]].map { $0.id.uuidString })
        let runtime = PluginRuntimeProjection.project(workspace: env.workspace, packages: [package],
            connectorMode: .runtimeCopies, definitions: [package])
        let runtimeSkill = try #require(runtime.skills.first { $0.id == skill.id })
        #expect(Set(runtimeSkill.connectors.map { $0.id.uuidString }) == expectedAccounts)
        #expect(Set(runtimeSkill.localTools.filter { tool in tools.contains { $0.id == tool.id } }.map { $0.id.uuidString }) == expectedTools)
        #expect(Set((config.connectors ?? []).map(\.id)) == expectedAccounts)
        #expect(Set((config.localTools ?? []).map(\.id)) == expectedTools)
        let savedSkill = try #require(config.skills.first { $0.id == skill.id.uuidString })
        #expect(Set(savedSkill.connectorIDs ?? []) == expectedAccounts)
        #expect(Set(savedSkill.localToolIDs ?? []) == expectedTools)
    }

}
