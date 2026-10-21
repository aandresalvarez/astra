import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin credential generations", .serialized)
struct PluginCredentialGenerationTests {
    @Test("A failed re-Add preserves the previous namespace and its cleanup intent")
    func failedAddDoesNotCleanBeforeCommit() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("old-value")
        let namespace = try #require(GenerationSecrets.namespace(holding: "old-value"))
        try env.removeLeavingLegacyMirror(namespace)
        #expect(throws: (any Error).self) {
            try env.installer.enable(env.package, in: env.workspace, modelContext: env.context,
                configInputs: ["API_TOKEN": "attempted-value"], persist: { _, _ in false })
        }
        #expect(GenerationSecrets.value(in: namespace) == "old-value")
        #expect(try env.outbox.pending().contains(namespace))
        #expect(!GenerationSecrets.deleted.contains(namespace))
        #expect(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace) == nil)
        #expect(old.id == PluginActivation.projectedID(workspaceID: env.workspace.id,
            pluginID: env.package.id, componentID: env.component))
    }

    @Test("Re-Add has stable runtime IDs and new credentials while a queued request keeps its old value")
    func queuedRequestKeepsOldCredentialGeneration() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try Fixture()
        defer { env.disk.disk.removeFiles() }
        let old = try env.enable("queued-value")
        let namespace = try #require(GenerationSecrets.namespace(holding: "queued-value"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        let frozen = PluginActivationRecord(activation)
        let task = AgentTask(title: "Queued generation", goal: "Use the accepted plugin", workspace: env.workspace)
        env.context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [env.package])
        env.context.insert(request)
        try env.context.save()
        let requestID = request.id
        try env.removeLeavingLegacyMirror(namespace)
        let current = try env.enable("current-value")
        #expect(current.id == old.id)
        #expect(current.environmentVariables["API_TOKEN"] == "current-value")
        #expect(GenerationSecrets.value(in: namespace) == "queued-value")
        #expect(GenerationSecrets.namespace(holding: "current-value") != namespace)
        let detached = Workspace(name: "Detached queue", primaryPath: "")
        WorkspaceCapabilityActivation.copyActivations([frozen], of: env.workspace, to: detached,
            accountsByID: [:], definitionsFrozen: true)
        let queued = try #require(PluginRuntimeProjection.project(workspace: detached, packages: [env.package]).skills.first)
        #expect(queued.id == old.id)
        #expect(queued.environmentVariables["API_TOKEN"] == "queued-value")
        let reopened = try env.disk.disk.reopen()
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext, outbox: env.outbox,
            secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: namespace) == "queued-value")
        #expect(try env.outbox.pending().contains(namespace))
        let savedRequest = try #require(try reopened.mainContext.fetch(FetchDescriptor<TaskTurnRequest>()).first { $0.id == requestID })
        savedRequest.state = .completed
        savedRequest.terminalAt = Date()
        try reopened.mainContext.save()
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext, outbox: env.outbox,
            secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: namespace) == nil)
        #expect(current.environmentVariables["API_TOKEN"] == "current-value")
        #expect(try env.outbox.entries().isEmpty)
    }

    @Test("Own-mirror recovery preserves the credential generation; a chosen file cannot borrow it")
    func recoveryAndChosenImportSeparateAuthority() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try Fixture()
        defer { env.disk.disk.removeFiles() }
        let original = try env.enable("local-private-value")
        let config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        #expect(config.installedPlugins?.first?.credentialNamespaceSeed?.isEmpty == false)
        let own = try makeContainer()
        let recovered = WorkspaceConfigManager.importWorkspaceResult(from: config,
            modelContext: own.mainContext, capabilityTrust: .preserveRecordedState).workspace
        let recoveredSkill = try #require(PluginRuntimeProjection.project(workspace: recovered, packages: [env.package]).skills.first)
        #expect(recoveredSkill.id == original.id)
        #expect(recoveredSkill.environmentVariables["API_TOKEN"] == "local-private-value")
        let selected = try makeContainer()
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(approvedPackageIDs: [env.package.id],
            installedPackageIDs: [env.package.id], availablePackIDs: [],
            declaredComponentIDs: [env.package.id: Set(PluginRuntimeProjection.componentIDs(of: env.package))],
            installedContentDigests: [env.package.id: PluginDefinitionDigest.content(of: env.package)])
        let imported = WorkspaceConfigManager.importWorkspaceResult(from: config,
            modelContext: selected.mainContext, capabilityTrust: .validate(verifier)).workspace
        let importedSkill = try #require(PluginRuntimeProjection.project(workspace: imported, packages: [env.package]).skills.first)
        #expect(importedSkill.environmentVariables["API_TOKEN"] == nil)
        #expect(importedSkill.secretNamespaceID != original.secretNamespaceID)
        withExtendedLifetime((own, selected)) {}
    }

    @Test("Legacy activation records keep their original credential namespace")
    func legacyRecordStillReadsLegacySecrets() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try Fixture()
        defer { env.disk.disk.removeFiles() }
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(env.package.id) }
        WorkspaceCapabilityActivation.recordAccepted(pluginID: env.package.id, version: env.package.version,
            digest: PluginDefinitionDigest.content(of: env.package), in: env.workspace)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        let legacyID = PluginRuntimeProjection.derivedID(of: activation, componentID: env.component)
        #expect(GenerationSecrets.saveSecretValue("legacy-value", key: "API_TOKEN", skillID: legacyID,
            skillName: "Legacy", allowUserInteraction: false))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PluginActivationRecord(activation))) as? [String: Any])
        json.removeValue(forKey: "credentialNamespaceSeed")
        let record = try JSONDecoder().decode(PluginActivationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        let target = Workspace(name: "Legacy launch", primaryPath: "")
        WorkspaceCapabilityActivation.copyActivations([record], of: env.workspace, to: target, accountsByID: [:], definitionsFrozen: true)
        let skill = try #require(PluginRuntimeProjection.project(workspace: target, packages: [env.package]).skills.first)
        #expect(skill.id == legacyID && skill.secretNamespaceID == legacyID)
        #expect(skill.environmentVariables["API_TOKEN"] == "legacy-value")
    }

    @Test("Stored skill references, frozen snapshots and mirrors keep their actual credential namespace")
    func authoredNamespaceReferenceIsDurable() throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try Fixture()
        defer { env.disk.disk.removeFiles() }
        let namespace = UUID()
        let skill = Skill(name: "Recovered explicit skill")
        skill.credentialNamespaceID = namespace
        skill.environmentKeys = ["API_TOKEN"]; skill.environmentValues = [""]
        skill.workspace = env.workspace
        env.context.insert(skill)
        #expect(GenerationSecrets.saveSecretValue("restored-value", key: "API_TOKEN", skillID: namespace,
            skillName: skill.name, allowUserInteraction: false))
        let task = AgentTask(title: "Frozen skill reference", goal: "Keep the secret reference", workspace: env.workspace)
        task.skills = [skill]
        task.skillSnapshots = [SkillSnapshotConfig(skill: skill)]
        env.context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
        env.context.insert(request)
        try env.context.save()
        let reopened = try env.disk.disk.reopen()
        let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).first { $0.id == skill.id })
        #expect(saved.secretNamespaceID == namespace)
        #expect(saved.environmentVariables["API_TOKEN"] == "restored-value")
        #expect(PendingTaskCredentialReferences.capture(modelContext: reopened.mainContext)?.holdsSkill(namespace, key: "API_TOKEN") == true)
        try env.outbox.write([namespace])
        try env.outbox.journal([.init(key: "API_TOKEN", skillID: namespace)])
        PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext, outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: namespace) == "restored-value")
        let config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        let own = try makeContainer()
        let recovered = WorkspaceConfigManager.importWorkspaceResult(from: config,
            modelContext: own.mainContext, capabilityTrust: .preserveRecordedState).workspace
        let recoveredSkill = try #require(recovered.skills.first)
        #expect(recoveredSkill.secretNamespaceID == namespace)
        #expect(recoveredSkill.environmentVariables["API_TOKEN"] == "restored-value")
        let selected = try makeContainer()
        let imported = WorkspaceConfigManager.importWorkspaceResult(from: config,
            modelContext: selected.mainContext, capabilityTrust: .validate(.init(approvedPackageIDs: [], installedPackageIDs: [], availablePackIDs: []))).workspace
        #expect(imported.skills.allSatisfy { $0.credentialNamespaceID == nil })
        #expect(imported.tasks.flatMap(\.skillSnapshots).allSatisfy { $0.credentialNamespaceID == nil })
        withExtendedLifetime((own, selected)) {}
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @MainActor
    struct Fixture {
        let disk: PluginAddCommitTests.Fixture
        let package: PluginPackage
        var workspace: Workspace { disk.workspace }
        var context: ModelContext { disk.context }
        var component: String { CapabilityResourceOrigin.componentID(for: package.skills[0]) }
        var outbox: PluginSecretCleanupOutbox { PluginSecretCleanupOutbox(for: context)! }
        var installer: CapabilityInstaller { .init(library: disk.disk.library, skillSecrets: GenerationSecrets.self) }
        init() throws {
            disk = try PluginAddCommitTests.Fixture(installed: false)
            GenerationSecrets.reset()
            var definition = PluginOperationsTests.package(version: "1.0.0")
            definition.id = disk.package.id
            definition.connectors = []; definition.localTools = []; definition.templates = []
            definition.skills[0].environmentKeys = ["API_TOKEN"]
            definition.skills[0].environmentValues = [""]
            definition.governance = .builtInApproved()
            package = definition
        }
        func enable(_ value: String) throws -> Skill {
            _ = try installer.enable(package, in: workspace, modelContext: context, configInputs: ["API_TOKEN": value])
            return try #require(PluginRuntimeProjection.project(workspace: workspace, packages: [package]).skills.first)
        }
        func removeLeavingLegacyMirror(_ namespace: UUID) throws {
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
            WorkspaceCapabilityActivation.retire(activation, in: workspace)
            WorkspaceCapabilityActivation.mutate(workspace) { $0 = WorkspaceCapabilityActivationState() }
            try context.save()
            // Legacy Remove's save landed, but neither its old mirror nor its
            // cleanup was completed. New Remove has its own receipt as well.
            try outbox.write([namespace])
        }
    }
}

enum GenerationSecrets: SkillSecretPersisting {
    private struct State { var values: [UUID: [String: String]] = [:]; var deleted: [UUID] = [] }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var deleted: [UUID] { state.withLock { $0.deleted } }
    static func reset() { state.withLock { $0 = State() } }
    static func namespace(holding value: String) -> UUID? { state.withLock { $0.values.first { $0.value["API_TOKEN"] == value }?.key } }
    static func value(in namespace: UUID) -> String? { state.withLock { $0.values[namespace]?["API_TOKEN"] } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { state.withLock { $0.values[skillID]?[key] } }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        state.withLock { $0.values[skillID, default: [:]][key] = value }; return true
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        state.withLock { $0.values[skillID]?[key] = nil; $0.deleted.append(skillID) }; return true
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { state.withLock { $0.values[skillID]?[key] != nil } }
    static func deleteAllSecrets(skillID: UUID) { state.withLock { $0.values[skillID] = nil; $0.deleted.append(skillID) } }
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { deleteAllSecrets(skillID: skillID); return true }
}
