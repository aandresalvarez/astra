import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Plugin credential metadata compatibility", .serialized)
@MainActor
struct PluginCredentialMetadataCompatibilityTests {
    @Test("Only the accepted definition and version can prove an empty inventory")
    func definitionEvidence() throws {
        let package = emptyPackage()
        let digest = PluginDefinitionDigest.content(of: package)
        #expect(PluginCredentialComponentInventory.componentIDs(in: package, version: package.version, digest: digest) == [])
        #expect(PluginCredentialComponentInventory.componentIDs(in: package, version: package.version,
            digest: try CapabilityApprovalDigest.digest(for: package)) == [])
        for untrusted in ["", "old-unverified-digest", "content-v1:other"] {
            #expect(PluginCredentialComponentInventory.componentIDs(in: package, version: package.version, digest: untrusted) == nil)
        }
        #expect(PluginCredentialComponentInventory.componentIDs(in: package, version: "0.0.0", digest: digest) == nil)
        var changed = package
        changed.skills = [PluginSkill(name: "Agent", icon: "testtube.2", description: "Synthetic", allowedTools: [],
            disallowedTools: [], customTools: [], behaviorInstructions: "Fixture", environmentKeys: [], environmentValues: [])]
        #expect(PluginCredentialComponentInventory.componentIDs(in: changed, version: changed.version, digest: digest) == nil)
    }

    @Test("A current proven-empty export clears an orphan even after the definition is unavailable")
    func provenEmptyExport() throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let package = emptyPackage()
        addActivation(package, in: env)
        try env.context.save()
        try withDefinitions([package]) {
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context, url: env.ownMirror)
        }
        let config = try WorkspaceConfigManager.loadConfig(from: env.ownMirror)
        #expect(config.installedPlugins?.first?.credentialComponentIDs == [])
        #expect(config.installedPlugins?.first?.secretSettingKeys == [])
        try withDefinitions([]) {
            let ownership = try #require(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []))
            let orphan = UUID()
            #expect(!ownership.holdsSkill(orphan))
            try env.outbox.write([orphan])
            MetadataFakeSecrets.seed([orphan])
            resume(env)
            #expect(MetadataFakeSecrets.value(orphan) == nil)
            #expect(try env.outbox.entries().isEmpty)
        }
    }

    @Test("Missing and explicit-empty legacy arrays remain unknown without matching definition evidence", arguments: [false, true], [false, true])
    func ambiguousLegacyRecord(explicitArrays: Bool, unparsedSetting: Bool) throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let package = emptyPackage()
        var plugin: [String: Any] = ["id": package.id, "version": package.version, "digest": "unverified-legacy"]
        if unparsedSetting { plugin["settings"] = ["unresolved-legacy-key": "synthetic-private-value"] }
        if explicitArrays { plugin["knownComponentIDs"] = [String](); plugin["secretSettingKeys"] = [String]() }
        try write(plugin, at: env.ownMirror, workspaceID: env.workspace.id)
        let orphan = UUID()
        try env.outbox.write([orphan])
        MetadataFakeSecrets.seed([orphan])
        withDefinitions([package]) {
            #expect(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []) == nil)
            resume(env)
        }
        AppLogger.flushForTesting()
        let diagnostic = try #require(AppLogger.entries.last { $0.message.contains("ambiguous_plugin_credential_metadata") })
        #expect(diagnostic.message.contains(package.id))
        #expect(diagnostic.message.contains(env.workspace.id.uuidString))
        #expect(!diagnostic.message.contains("synthetic-private-value"))
        #expect(!diagnostic.message.contains("unresolved-legacy-key"))
        #expect(MetadataFakeSecrets.value(orphan) == "synthetic-token")
        #expect(try env.outbox.pending() == [orphan])
    }

    @Test("Older omitted metadata is resolved only against its matching definition")
    func matchingLegacyDefinition() throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let package = emptyPackage()
        try write(["id": package.id, "version": package.version, "digest": PluginDefinitionDigest.content(of: package)],
            at: env.ownMirror, workspaceID: env.workspace.id)
        withDefinitions([package]) {
            #expect(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []) != nil)
        }
        withDefinitions([]) {
            #expect(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []) == nil)
        }
    }

    @Test("Rewriting an unreconciled activation does not manufacture empty evidence")
    func rewrittenAmbiguousActivation() throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let package = emptyPackage()
        let activation = PluginActivation(pluginID: package.id, recordedVersion: package.version)
        env.context.insert(activation)
        activation.workspace = env.workspace
        try env.context.save()
        try withDefinitions([package]) {
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context, url: env.ownMirror)
            let config = try WorkspaceConfigManager.loadConfig(from: env.ownMirror)
            #expect(config.installedPlugins?.first?.credentialComponentIDs == nil)
            #expect(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []) == nil)
        }
    }

    @Test("Nine saved task snapshots in two workspaces retain their namespace while an unrelated orphan clears")
    func savedTasksAcrossWorkspaces() throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let other = Workspace(name: "Other", primaryPath: env.root.appendingPathComponent("other").path)
        env.context.insert(other)
        let package = emptyPackage()
        addActivation(package, in: env)
        let otherActivation = PluginActivation(pluginID: package.id, recordedVersion: package.version,
            recordedDigest: PluginDefinitionDigest.content(of: package))
        env.context.insert(otherActivation)
        otherActivation.workspace = other
        let held = UUID(), orphan = UUID()
        let skill = Skill(name: "Synthetic frozen skill")
        skill.credentialNamespaceID = held
        skill.environmentKeys = ["API_TOKEN"]; skill.environmentValues = [""]
        for index in 0..<9 {
            let task = AgentTask(title: "Saved \(index)", goal: "Synthetic", workspace: index < 5 ? env.workspace : other)
            task.skillSnapshots = [SkillSnapshotConfig(skill: skill)]
            task.status = .completed
            env.context.insert(task)
        }
        try env.context.save()
        try env.outbox.write([held, orphan])
        MetadataFakeSecrets.seed([held, orphan])
        let rewrite: (Workspace) -> Bool = {
            (try? WorkspaceConfigManager.exportToFile(workspace: $0, modelContext: env.context,
                url: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: $0.primaryPath)))) != nil
        }
        let settle = {
            withDefinitions([package]) {
                PluginSecretCleanupOutbox.resumePending(modelContext: env.context, outbox: env.outbox,
                    secrets: MetadataFakeSecrets.self, rewriteMirror: rewrite)
            }
        }
        settle()
        #expect(MetadataFakeSecrets.value(orphan) == nil)
        #expect(MetadataFakeSecrets.value(held) == "synthetic-token")
        #expect(try env.outbox.pending() == [held])
        let tasks = try env.context.fetch(FetchDescriptor<AgentTask>())
        for task in tasks where task.workspace?.id == env.workspace.id { env.context.delete(task) }
        try env.context.save()
        settle()
        #expect(MetadataFakeSecrets.value(held) == "synthetic-token")
        #expect(try env.outbox.pending() == [held])
        for task in try env.context.fetch(FetchDescriptor<AgentTask>()) { env.context.delete(task) }
        try env.context.save()
        settle()
        #expect(MetadataFakeSecrets.value(held) == nil)
        #expect(try env.outbox.entries().isEmpty)
    }

    private func emptyPackage() -> PluginPackage {
        PluginPackage(id: "synthetic-empty-credentials", name: "Empty", icon: "testtube.2", description: "Synthetic",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0", skills: [], connectors: [], localTools: [],
            mcpServers: [PluginMCPServer(id: "synthetic-server", displayName: "Synthetic MCP", transport: .http,
                url: URL(string: "https://mcp.example.invalid")!)], templates: [])
    }

    private func addActivation(_ package: PluginPackage, in env: PluginRecoveryMirrorCredentialTests.Fixture) {
        let activation = PluginActivation(pluginID: package.id, recordedVersion: package.version,
            recordedDigest: PluginDefinitionDigest.content(of: package))
        env.context.insert(activation)
        activation.workspace = env.workspace
    }

    private func write(_ plugin: [String: Any], at url: URL, workspaceID: UUID) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": workspaceID.uuidString, "installedPlugins": [plugin]]).write(to: url)
    }

    private func resume(_ env: PluginRecoveryMirrorCredentialTests.Fixture) {
        PluginSecretCleanupOutbox.resumePending(modelContext: env.context, outbox: env.outbox,
            secrets: MetadataFakeSecrets.self, rewriteMirror: { _ in true })
    }

    private func withDefinitions<T>(_ packages: [PluginPackage], _ body: () throws -> T) rethrows -> T {
        let packs = AstraPackCatalog()
        let inputs = CapabilityResolutionInputs(libraryDirectory: CapabilityLibrary().directory.standardizedFileURL,
            packageDefinitions: packages, approvalsDirectory: CapabilityApprovalStore().directory.standardizedFileURL,
            approvalRecords: [], packBuiltInDirectory: packs.builtInDirectory?.standardizedFileURL,
            packLocalStorageRoot: packs.localStorageRoot?.standardizedFileURL, packCatalog: .init(entries: [], diagnostics: []))
        return try CapabilityResolutionInputs.$pinned.withValue(inputs, operation: body)
    }
}

private enum MetadataFakeSecrets: SkillSecretPersisting {
    private static let values = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])
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
