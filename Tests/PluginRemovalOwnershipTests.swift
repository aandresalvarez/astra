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
