import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Existing-store plugin credential upgrade", .serialized)
struct PluginCredentialUpgradeTests {
    @Test("Startup export preserves unknown current keys and releases empty or retired generations",
        arguments: ["current", "empty", "removed", "replaced"])
    func existingStoreStartupExport(mode: String) async throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        let trust = WorkspaceRecoveryTrust.state, mirrors = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.set(trust); WorkspaceRecoveryTrust.recordLoadedMirrors(mirrors) }
        WorkspaceRecoveryTrust.recordLoadedMirrors([])
        let mirror = env.ownMirror, root = env.workspace.primaryPath
        var package = PluginPackage(id: "synthetic-upgrade-" + UUID().uuidString, name: "Upgrade", icon: "testtube.2",
            description: "Synthetic", author: "Tests", category: "Tests", tags: [], version: "1.0.0", skills: [],
            connectors: [], localTools: [], mcpServers: [], templates: [])
        if mode != "empty" {
            package.skills = [PluginSkill(name: "Agent", icon: "testtube.2", description: "Synthetic", allowedTools: [],
                disallowedTools: [], customTools: [], behaviorInstructions: "Fixture", environmentKeys: ["API_TOKEN"], environmentValues: [""])]
        }
        let packs = AstraPackCatalog()
        let inputs = CapabilityResolutionInputs(libraryDirectory: CapabilityLibrary().directory.standardizedFileURL,
            packageDefinitions: [package], approvalsDirectory: CapabilityApprovalStore().directory.standardizedFileURL,
            approvalRecords: [], packBuiltInDirectory: packs.builtInDirectory?.standardizedFileURL,
            packLocalStorageRoot: packs.localStorageRoot?.standardizedFileURL, packCatalog: .init(entries: [], diagnostics: []))
        try await CapabilityResolutionInputs.$pinned.withValue(inputs) {
            let activation = PluginActivation(pluginID: package.id, recordedVersion: package.version,
                recordedDigest: PluginDefinitionDigest.content(of: package))
            env.context.insert(activation)
            activation.workspace = env.workspace
            if mode != "empty" {
                WorkspaceCapabilityActivation.setConfigValue("synthetic-region", forKey: "skill:agent#REGION", on: activation)
            }
            try env.context.save()
            // A real migration seeds the pre-PR domain shape, without an
            // import creating new recovery evidence for this existing row.
            _ = try PluginActivationMigration.migrate(modelContext: env.context, packages: [package], secrets: UpgradeSecrets.self,
                sourceStore: PluginSourceStore(root: env.root.appendingPathComponent("sources")), persist: { try $0.save() },
                rewriteMirror: {
                    (try? WorkspaceConfigManager.exportToFile(workspace: $0, modelContext: env.context, url: mirror)) != nil
                }, vault: UpgradeInertVault())
            #expect(activation.knownComponentIDs == (mode == "empty" ? [] : ["skill:agent"]))
            #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation) == nil)
            var old = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
            // The pre-PR serializer omitted empty markers and had no derived
            // inventory/recovery fields. Preserve its actual on-disk shape.
            old.installedPlugins?[0].secretSettingKeys = nil
            old.installedPlugins?[0].credentialComponentIDs = nil
            old.installedPlugins?[0].credentialRecoveryEvidence = nil
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(old).write(to: mirror)
            let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent")
            let key = PluginUpdateService.StaleSecret(key: "API_TOKEN", skillID: namespace)
            let outbox = try #require(PluginSecretCleanupOutbox(for: env.context))
            try outbox.journal([key])
            // Already-saved explicit removal/replacement must not acquire an
            // obsolete generation merely because its old mirror still exists.
            if mode == "removed" { env.context.delete(activation) }
            if mode == "replaced" {
                WorkspaceCapabilityActivation.setCredentialNamespaceSeed("replacement-" + UUID().uuidString, on: activation)
            }
            try env.context.save()
            let reopened = try env.reopen()
            let saved = reopened.mainContext
            saved.autosaveEnabled = false
            var reimported = false, loaded = 0
            let recovered = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(modelContext: saved,
                extraRoots: [root], includeDefaultRoots: false, pendingCleanup: true, registeredFolders: [root],
                afterImport: { reimported = true }, loadedMirrors: {
                    loaded = $0.count
                    WorkspaceRecoveryTrust.recordLoadedMirrors($0.map(\.path))
                }, discover: { ([mirror], true) }).value
            #expect(recovered && loaded == 1 && !reimported)
            WorkspaceRecoveryTrust.set(.trusted)
            let before = try #require(PluginCredentialMirrorReferences.capture(modelContext: saved))
            #expect(before.holdsSkill(namespace, key: key.key) == (mode != "empty"))
            #expect(try WorkspaceConfigManager.loadConfig(from: mirror).installedPlugins?.first?.secretSettingKeys == nil)
            UpgradeSecrets.seed(namespace)
            let diagnostics = StartupCleanupAggregate()
            // No injected writer: this is the production background saved
            // projection, backup, file replacement, reread and outbox path.
            await WorkspacePersistenceWork.$cleanupJob.withValue(diagnostics) {
                await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: saved, secrets: UpgradeSecrets.self)
            }
            #expect((Int(diagnostics.fields()["copy_succeeded"] ?? "0") ?? 0) > 0)
            let after = try #require(PluginCredentialMirrorReferences.capture(modelContext: saved))
            let held = mode == "current"
            #expect(after.holdsSkill(namespace, key: key.key) == held)
            #expect(UpgradeSecrets.value(namespace) == (held ? "synthetic-token" : nil))
            #expect(try outbox.pendingKeys() == (held ? [key] : []))
            let exported = try WorkspaceConfigManager.loadConfig(from: mirror)
            if held { #expect(exported.installedPlugins?.first?.secretSettingKeys == nil) }
            if mode == "empty" { #expect(exported.installedPlugins?.first?.secretSettingKeys == []) }
        }
    }
}

private enum UpgradeSecrets: SkillSecretPersisting {
    private static let values = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])
    static func seed(_ id: UUID) { values.withLock { $0 = [id: "synthetic-token"] } }
    static func value(_ id: UUID) -> String? { values.withLock { $0[id] } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { value(skillID) }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        values.withLock { $0[skillID] = value }; return true
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { value(skillID) != nil }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { deleteAllSecretsReportingResult(skillID: skillID) }
    static func deleteAllSecrets(skillID: UUID) { _ = deleteAllSecretsReportingResult(skillID: skillID) }
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { values.withLock { $0[skillID] = nil }; return true }
}

private struct UpgradeInertVault: SecretStore {
    func load(key: String, entityID: String) -> String? { nil }
    func save(key: String, value: String, entityID: String, label: String?) -> Bool { false }
    func delete(key: String, entityID: String) -> Bool { false }
    func deleteAll(entityID: String) {}
    func exists(key: String, entityID: String) -> Bool { false }
}
