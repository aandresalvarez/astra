import Foundation
import os
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Removal of legacy plugin rows", .serialized)
struct PluginRemovalOwnershipTests {
    @Test("A legacy skill's secret cleanup survives a failed mirror and a real store reopen")
    func legacyCleanupIsDurable() throws {
        let env = try PluginRemovalCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let skill = Skill(name: "Legacy owned skill")
        skill.isGlobal = true
        CapabilityResourceOrigin.stamp(skill, package: env.package, componentID: "skill:legacy")
        env.context.insert(skill)
        let skillID = skill.id
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.globalSkillIDs.append(skillID.uuidString) }
        try env.context.save()
        let outbox = PluginSecretCleanupOutbox(fileURL: env.disk.root.appendingPathComponent("cleanup.json"))
        RemovalSecrets.reset()
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Blocked recovery mirror".utf8).write(to: support)
        #expect(throws: PluginOperationProblem.self) {
            try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context,
                skillSecrets: RemovalSecrets.self, secretCleanupOutbox: outbox)
        }
        #expect(try outbox.pending().contains(skillID))
        #expect(RemovalSecrets.deleted.isEmpty)
        try FileManager.default.removeItem(at: support)
        let reopened = try env.disk.reopen()
        let recovered = PluginFileOperationRecovery(journal: env.journal).resumePending(modelContext: reopened.mainContext)
        #expect(recovered.completed == 1 && recovered.deferred == 0)
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext, outbox: outbox, secrets: RemovalSecrets.self)
        #expect(try outbox.pending().isEmpty)
        #expect(RemovalSecrets.deleted == [skillID])
    }

    @Test("Removal retains a creator only for surviving foreign bindings, including after reopen", arguments: [false, true], [false, true])
    func survivingBindingKeepsCreatorProvenance(otherWorkspace: Bool, boundConsumer: Bool) throws {
        let env = try PluginRemovalCommitTests.Fixture(activated: true)
        defer { env.disk.removeFiles() }
        var consumer = env.package
        consumer.id = "shared.account.consumer"
        consumer.name = "Shared account consumer"
        consumer.connectors[0].configHints = []
        try env.library.install(consumer, sourceMetadata: .localLibrary())
        let target: Workspace
        if otherWorkspace {
            let folder = env.disk.root.appendingPathComponent("Consumer")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            target = Workspace(name: "Consumer", primaryPath: folder.path)
            env.context.insert(target)
        } else { target = env.workspace }
        WorkspaceCapabilityActivation.mutate(target) { $0.enableCapability(consumer.id) }
        WorkspaceCapabilityActivation.recordAccepted(pluginID: consumer.id, version: consumer.version,
            digest: PluginDefinitionDigest.content(of: consumer), in: target)
        let surviving = try #require(WorkspaceCapabilityActivation.activation(for: consumer.id, in: target))
        WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: consumer), on: surviving)
        let creator = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        let component = CapabilityResourceOrigin.componentID(for: env.package.connectors[0])
        let account = Connector(name: "Shared account", serviceType: env.package.connectors[0].serviceType,
            baseURL: env.package.connectors[0].baseURL, authMethod: env.package.connectors[0].authMethod)
        account.isGlobal = true
        account.credentialNamespaceID = UUID()
        account.credentialKeys = ["TRACKER_TOKEN", "CREATOR_ONLY_TOKEN"]
        account.credentialValues = ["", ""]
        account.configKeys = ["CREATOR_ONLY_SETTING"]
        account.configValues = ["creator value"]
        CapabilityResourceOrigin.stamp(account, package: env.package, componentID: component)
        env.context.insert(account)
        WorkspaceCapabilityActivation.bind(account, toComponent: component, of: creator)
        if boundConsumer {
            WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: consumer.connectors[0]), of: surviving)
        }
        let targetID = target.id, accountID = account.id
        try env.context.save()
        _ = try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context)
        let expectedOrigin: String? = boundConsumer ? env.package.id : nil
        let expectedComponent: String? = boundConsumer ? component : nil
        #expect(account.originPackageID == expectedOrigin)
        #expect(account.originComponentID == expectedComponent)
        #expect(surviving.bindings.contains { $0.account?.id == accountID } == boundConsumer)
        #expect(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace) == nil)
        #expect(!WorkspaceCapabilityActivation.enabledPluginIDs(of: env.workspace).contains(env.package.id))
        #expect(env.library.installedPackage(id: env.package.id) == nil)
        let reopened = try env.disk.reopen()
        let context = reopened.mainContext
        let savedTarget = try #require(try context.fetch(FetchDescriptor<Workspace>()).first { $0.id == targetID })
        let savedAccount = try #require(try context.fetch(FetchDescriptor<Connector>()).first { $0.id == accountID })
        #expect(savedAccount.originPackageID == expectedOrigin)
        let runtime = PluginRuntimeProjection.project(workspace: savedTarget, packages: [consumer],
            connectorMode: .runtimeCopies, definitions: [consumer])
        if boundConsumer {
            let copy = try #require(runtime.connectors.first { $0.id == accountID })
            #expect(copy.credentialKeys.isEmpty)
            #expect(copy.configKeys.isEmpty)
        } else {
            #expect(!runtime.connectors.contains { $0.id == accountID })
        }
        #expect(savedAccount.credentialKeys.contains("CREATOR_ONLY_TOKEN"))
        #expect(savedAccount.configKeys.contains("CREATOR_ONLY_SETTING"))
    }

    @Test("A failed removal of fetched legacy rows preserves task, account and tool relationships")
    func failedRemovalRestoresFetchedGraph() throws {
        let env = try PluginRemovalCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let skill = Skill(name: "Legacy task skill")
        skill.isGlobal = true
        CapabilityResourceOrigin.stamp(skill, package: env.package, componentID: "skill:legacy")
        let account = Connector(name: "Kept account", serviceType: "legacy", baseURL: "https://example.test")
        account.isGlobal = true
        account.skill = skill
        CapabilityResourceOrigin.stamp(account, package: env.package, componentID: "connector:legacy:account")
        let tool = LocalTool(name: "Legacy tool", toolType: "cli", command: "echo", arguments: "test")
        tool.isGlobal = true
        tool.skill = skill
        CapabilityResourceOrigin.stamp(tool, package: env.package, componentID: "tool:legacy")
        let task = AgentTask(title: "References", goal: "Keep these references", workspace: env.workspace)
        task.skills = [skill]
        env.context.insert(skill)
        env.context.insert(account)
        env.context.insert(tool)
        env.context.insert(task)
        WorkspaceCapabilityActivation.mutate(env.workspace) {
            $0.globalSkillIDs.append(skill.id.uuidString)
            $0.globalConnectorIDs.append(account.id.uuidString)
            $0.globalToolIDs.append(tool.id.uuidString)
        }
        try env.context.save()
        let skillID = skill.id, accountID = account.id, toolID = tool.id, taskID = task.id
        let reopened = try env.disk.reopen()
        let context = reopened.mainContext
        context.autosaveEnabled = false
        #expect(throws: CapabilityUninstaller.UninstallError.self) {
            try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: context, persist: { _, _ in false })
        }
        let restored = try #require(try context.fetch(FetchDescriptor<Skill>()).first { $0.id == skillID })
        #expect(restored.tasks.map(\.id) == [taskID])
        #expect(restored.connectors.map(\.id) == [accountID])
        #expect(restored.localTools.map(\.id) == [toolID])
        #expect(try context.fetch(FetchDescriptor<AgentTask>()).first { $0.id == taskID }?.skills.map(\.id) == [skillID])
        #expect(try context.fetch(FetchDescriptor<Connector>()).first { $0.id == accountID }?.originPackageID == env.package.id)
        #expect(env.library.installedPackage(id: env.package.id) != nil)
    }
}

private enum RemovalSecrets: SkillSecretPersisting {
    private static let cleaned = OSAllocatedUnfairLock<[UUID]>(initialState: [])
    static var deleted: [UUID] { cleaned.withLock { $0 } }
    static func reset() { cleaned.withLock { $0 = [] } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { true }
    static func deleteAllSecrets(skillID: UUID) { cleaned.withLock { $0.append(skillID) } }
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { deleteAllSecrets(skillID: skillID); return true }
}
