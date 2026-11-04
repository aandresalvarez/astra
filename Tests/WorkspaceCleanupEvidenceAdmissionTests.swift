import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Startup batch prior-mirror evidence admission", .serialized)
struct WorkspaceCleanupEvidenceAdmissionTests {
    @Test("All workspace admissions precede one backup, preserve caller edits and fence subsequent saves", arguments: [false, true])
    func multipleAdmissions(concurrentCommit: Bool) async throws {
        let env = try WorkspaceCleanupMirrorBatchTests.Fixture(count: 3)
        defer { env.removeFiles() }
        let trust = WorkspaceRecoveryTrust.state, mirrors = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.set(trust); WorkspaceRecoveryTrust.recordLoadedMirrors(mirrors) }
        WorkspaceRecoveryTrust.set(.trusted)
        WorkspaceRecoveryTrust.recordLoadedMirrors([])
        var keys: [PluginUpdateService.StaleSecret] = []
        var priorFiles: [UUID: Data] = [:]
        for workspace in env.workspaces {
            let activation = PluginActivation(pluginID: "synthetic-batch-" + UUID().uuidString, recordedVersion: "1.0.0")
            env.context.insert(activation)
            activation.workspace = workspace
            try env.context.save()
            var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: env.context))
            config.installedPlugins = [.init(id: activation.pluginID, version: "1.0.0",
                activationID: activation.id.uuidString, knownComponentIDs: ["skill:agent"])]
            let mirror = env.mirror(workspace)
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try canonical(config)
            try data.write(to: mirror)
            priorFiles[workspace.id] = data
            keys.append(.init(key: "API_TOKEN", skillID: PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent")))
        }
        let outbox = try #require(PluginSecretCleanupOutbox(for: env.context))
        try outbox.journal(keys)
        AdmissionSecrets.seed(keys.map(\.skillID))
        env.workspaces[0].name = "Pending UI edit"
        let observed = OSAllocatedUnfairLock(initialState: (copies: 0, bytes: Int64(0)))
        let totals = StartupCleanupAggregate()
        let copy = WorkspaceExportFileIO.copySnapshot
        let container = env.container
        await WorkspaceExportFileIO.$copySnapshot.withValue({ source, destination in
            try copy(source, destination)
            let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            observed.withLock { $0.copies += 1; $0.bytes += size?.int64Value ?? 0 }
            if concurrentCommit {
                let other = ModelContext(container)
                other.autosaveEnabled = false
                let workspace = try #require(other.fetch(FetchDescriptor<Workspace>()).first)
                workspace.name = "New commit after admission and capture"
                try other.save()
            }
        }) {
            await WorkspacePersistenceWork.$cleanupJob.withValue(totals) {
                await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context, secrets: AdmissionSecrets.self)
            }
        }
        #expect(env.context.hasChanges)
        #expect(env.workspaces[0].name == "Pending UI edit")
        #expect(Set(try outbox.pendingKeys()) == Set(keys))
        #expect(keys.allSatisfy { AdmissionSecrets.value($0.skillID) == "synthetic-token" })
        let fields = totals.fields()
        #expect(fields["pass_count"] == "1")
        #expect(fields["copy_succeeded"] == "1")
        #expect(fields["json_write_succeeded"] == (concurrentCommit ? "0" : "3"))
        #expect(observed.withLock { $0.copies } == 1)
        #expect(fields["logical_snapshot_bytes"] == String(observed.withLock { $0.bytes }))
        let saved = ModelContext(env.container)
        var jsonBytes = 0
        for workspace in try saved.fetch(FetchDescriptor<Workspace>()) {
            #expect(workspace.name != "Pending UI edit")
            let activation = try #require(WorkspaceCapabilityActivation.activations(of: workspace).first)
            #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation)?.hasAdmittedMirror(for: activation) == true)
            let mirror = env.mirror(workspace)
            jsonBytes += try Data(contentsOf: mirror).count
            if concurrentCommit {
                #expect(try Data(contentsOf: mirror) == priorFiles[workspace.id])
            } else {
                let written = try WorkspaceConfigManager.loadConfig(from: mirror)
                let expected = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: saved))
                #expect(try canonical(written) == canonical(expected))
            }
        }
        #expect(fields["json_written_bytes"] == (concurrentCommit ? "0" : String(jsonBytes)))
        #expect(try env.snapshotDirectories().isEmpty)
        if !concurrentCommit {
            print("CLEANUP_ADMISSION_MEASUREMENT workspaces=3 backup_successes=\(observed.withLock { $0.copies }) logical_snapshot_bytes=\(observed.withLock { $0.bytes }) json_written_bytes=\(jsonBytes)")
        }
    }

    @Test("The real async outbox admits a saved legacy store's current own mirror before replacing it",
          arguments: ["positive", "ambiguous", "contradictory-empty", "unsupported-empty", "unreadable", "mismatched", "proved-empty"])
    func existingStoreWithoutRecoveryScan(mode: String) async throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        let trust = WorkspaceRecoveryTrust.state, mirrors = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.set(trust); WorkspaceRecoveryTrust.recordLoadedMirrors(mirrors) }
        WorkspaceRecoveryTrust.set(.trusted)
        WorkspaceRecoveryTrust.recordLoadedMirrors([])
        let package = PluginPackage(id: "synthetic-batch-admission-" + UUID().uuidString,
            name: "Empty accepted definition", icon: "testtube.2", description: "Synthetic", author: "Tests",
            category: "Tests", tags: [], version: "1.0.0", skills: [], connectors: [], localTools: [], mcpServers: [], templates: [])
        let packs = AstraPackCatalog()
        let inputs = CapabilityResolutionInputs(libraryDirectory: CapabilityLibrary().directory.standardizedFileURL,
            packageDefinitions: [package], approvalsDirectory: CapabilityApprovalStore().directory.standardizedFileURL,
            approvalRecords: [], packBuiltInDirectory: packs.builtInDirectory?.standardizedFileURL,
            packLocalStorageRoot: packs.localStorageRoot?.standardizedFileURL, packCatalog: .init(entries: [], diagnostics: []))
        try await CapabilityResolutionInputs.$pinned.withValue(inputs) {
            // Persist the pre-upgrade shape directly: no recovery import,
            // admission, file writer, or startup discovery prepares this store.
            let activation = PluginActivation(pluginID: package.id, recordedVersion: package.version,
                recordedDigest: PluginDefinitionDigest.content(of: package))
            env.context.insert(activation)
            activation.workspace = env.workspace
            try env.context.save()
            #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation) == nil)
            var config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
            var ref = WorkspaceConfigManager.InstalledPluginRef(id: package.id, version: package.version,
                activationID: activation.id.uuidString, credentialComponentIDs: [], secretSettingKeys: [],
                digest: PluginDefinitionDigest.content(of: package))
            if mode == "positive" {
                ref.credentialComponentIDs = ["skill:agent"]
                ref.secretSettingKeys = ["skill:agent#API_TOKEN"]
            }
            if mode == "ambiguous" {
                ref.settings = ["unresolved-legacy-key": "synthetic-private-value"]
                ref.credentialComponentIDs = nil
                ref.secretSettingKeys = nil
            }
            if mode == "contradictory-empty" { ref.settings = ["skill:agent#API_TOKEN": "synthetic-private-value"] }
            if mode == "unsupported-empty" { ref.digest = "unverified-legacy-digest" }
            config.installedPlugins = [ref]
            if mode == "mismatched" { config.id = UUID().uuidString }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let original = mode == "unreadable" ? Data("synthetic undecodable prior file".utf8) : try encoder.encode(config)
            try FileManager.default.createDirectory(at: env.ownMirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: env.ownMirror)
            let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent")
            let key = PluginUpdateService.StaleSecret(key: "API_TOKEN", skillID: namespace)
            let outbox = try #require(PluginSecretCleanupOutbox(for: env.context))
            try outbox.journal([key])
            AdmissionSecrets.seed(namespace)
            let reopened = try env.reopen()
            let saved = reopened.mainContext
            saved.autosaveEnabled = false
            let owner = try #require(saved.fetch(FetchDescriptor<Workspace>()).first)
            let before = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: owner))
            #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: before) == nil)
            let totals = StartupCleanupAggregate()
            await WorkspacePersistenceWork.$cleanupJob.withValue(totals) {
                await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: saved, secrets: AdmissionSecrets.self)
            }
            let rejected = ["unreadable", "mismatched"].contains(mode)
            let held = mode != "proved-empty"
            #expect(AdmissionSecrets.value(namespace) == (held ? "synthetic-token" : nil))
            #expect(try outbox.pendingKeys() == (held ? [key] : []))
            let current = ModelContext(reopened)
            let stored = try #require(current.fetch(FetchDescriptor<PluginActivation>()).first)
            #expect((WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: stored)?.hasAdmittedMirror(for: stored) == true) == !rejected)
            if rejected {
                #expect(try Data(contentsOf: env.ownMirror) == original)
                #expect(totals.fields()["copy_attempts"] == "0")
                #expect(totals.fields()["json_write_succeeded"] == "0")
            } else {
                #expect(totals.fields()["copy_succeeded"] == "1")
                let written = try WorkspaceConfigManager.loadConfig(from: env.ownMirror)
                let refs = written.installedPlugins?.first?.credentialReferences()
                if ["ambiguous", "contradictory-empty", "unsupported-empty"].contains(mode) { #expect(refs == nil) }
                if mode == "positive" { #expect(refs?.secretSettingKeys == ["skill:agent#API_TOKEN"]) }
                if mode == "proved-empty" { #expect(refs?.componentIDs == []) }
                #expect(!(try String(contentsOf: env.ownMirror, encoding: .utf8)).contains("synthetic-private-value"))
            }
        }
    }

    private func canonical(_ value: WorkspaceConfigManager.WorkspaceConfig) throws -> Data {
        var config = value
        config.exportedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(config)
    }
}

private enum AdmissionSecrets: SkillSecretPersisting {
    private static let values = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])
    static func seed(_ id: UUID) { seed([id]) }
    static func seed(_ ids: [UUID]) { values.withLock { $0 = Dictionary(uniqueKeysWithValues: ids.map { ($0, "synthetic-token") }) } }
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
