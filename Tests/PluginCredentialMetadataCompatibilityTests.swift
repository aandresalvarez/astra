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

    @Test("Proven-empty own and admitted exports clear only with matching definition evidence", arguments: [false, true])
    func provenEmptyExport(extra: Bool) throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        WorkspaceRecoveryTrust.recordLoadedMirrors([])
        let package = emptyPackage()
        addActivation(package, in: env)
        try env.context.save()
        try withDefinitions([package]) {
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context, url: env.ownMirror)
        }
        let config = try WorkspaceConfigManager.loadConfig(from: env.ownMirror)
        #expect(config.installedPlugins?.first?.credentialComponentIDs == [])
        #expect(config.installedPlugins?.first?.secretSettingKeys == [])
        if extra {
            let copy = env.root.appendingPathComponent("proven-empty-copy.json")
            try FileManager.default.copyItem(at: env.ownMirror, to: copy)
            WorkspaceRecoveryTrust.recordLoadedMirrors([copy.path])
        }
        let orphan = UUID()
        try env.outbox.write([orphan])
        MetadataFakeSecrets.seed([orphan])
        try withDefinitions([]) {
            #expect(PluginCredentialMirrorReferences.capture(modelContext: env.context) == nil)
            resume(env)
            #expect(MetadataFakeSecrets.value(orphan) == "synthetic-token")
            let pending = try env.outbox.pending()
            #expect(pending == [orphan])
        }
        try withDefinitions([package]) {
            let ownership = try #require(PluginCredentialMirrorReferences.capture(modelContext: env.context))
            #expect(!ownership.holdsSkill(orphan))
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

    @Test("Older omitted metadata is resolved only against its matching definition", arguments: [false, true])
    func matchingLegacyDefinition(approvalDigest: Bool) throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let package = emptyPackage()
        let digest = approvalDigest ? try CapabilityApprovalDigest.digest(for: package) : PluginDefinitionDigest.content(of: package)
        try write(["id": package.id, "version": package.version, "digest": digest],
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

    @Test("Legacy single-key ownership survives recovery, real export and outbox reread", arguments: [false, true], [false, true])
    func legacySingleKeyRoundTrip(override: Bool, matchingDefinition: Bool) throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        WorkspaceRecoveryTrust.recordLoadedMirrors([])
        let mirror = env.ownMirror
        let row = Skill(name: "Synthetic authored override")
        env.context.insert(row)
        row.workspace = env.workspace
        try env.context.save()
        var config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        let pluginID = "synthetic-unresolved-legacy"
        var package = emptyPackage()
        package.id = pluginID
        package.skills = [PluginSkill(name: "Agent", icon: "testtube.2", description: "Synthetic", allowedTools: [],
            disallowedTools: [], customTools: [], behaviorInstructions: "Fixture", environmentKeys: ["API_TOKEN"], environmentValues: [""])]
        config.installedPlugins = [.init(id: pluginID, version: matchingDefinition ? package.version : "legacy",
            settings: override ? nil : ["skill:agent#REGION": "synthetic-region"],
            overriddenComponentIDs: override ? ["skill:agent"] : nil,
            overridingRowIDs: override ? [row.id.uuidString] : nil,
            namespaceSeed: "legacy-runtime", credentialNamespaceSeed: "legacy-generation",
            digest: matchingDefinition ? PluginDefinitionDigest.content(of: package) : nil)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: mirror)
        let namespace = PluginActivation.credentialID(workspaceID: env.workspace.id, pluginID: pluginID,
            componentID: "skill:agent", runtimeSeed: "legacy-runtime", generation: "legacy-generation")
        let key = PluginUpdateService.StaleSecret(key: "API_TOKEN", skillID: namespace)
        try withDefinitions(matchingDefinition ? [package] : []) {
            // Negative control: the legacy file holds the individual key
            // before any rewrite. On the reviewed code the real rewrite
            // below loses this hold and the fake credential is deleted.
            let before = try #require(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []))
            #expect(before.holdsSkill(namespace, key: key.key))
            let loaded = try WorkspaceConfigManager.loadConfig(from: mirror)
            env.context.delete(env.workspace)
            try env.context.save()
            let restored = WorkspaceConfigManager.importWorkspace(from: loaded, modelContext: env.context,
                capabilityTrust: .preserveRecordedState)
            try env.context.save()
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: pluginID, in: restored))
            #expect(activation.knownComponentIDs.isEmpty && activation.secretSettingKeys.isEmpty)
            #expect(activation.recordedDigest.isEmpty == !matchingDefinition)
            try env.outbox.journal([key])
            MetadataFakeSecrets.seed([namespace])
            let settle = {
                PluginSecretCleanupOutbox.resumePending(modelContext: env.context, outbox: env.outbox,
                    secrets: MetadataFakeSecrets.self, rewriteMirror: {
                        (try? WorkspaceConfigManager.exportToFile(workspace: $0, modelContext: env.context, url: mirror)) != nil
                    })
            }
            settle()
            var rewritten = try WorkspaceConfigManager.loadConfig(from: mirror)
            #expect(rewritten.installedPlugins?.first?.secretSettingKeys == nil)
            #expect(rewritten.installedPlugins?.first?.credentialComponentIDs == (matchingDefinition ? ["skill:agent"] : nil))
            let after = try #require(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []))
            #expect(after.holdsSkill(namespace, key: key.key))
            #expect(MetadataFakeSecrets.value(namespace) == "synthetic-token")
            #expect(try env.outbox.pendingKeys() == [key])
            // Also tolerate files already rewritten with the old false [].
            rewritten.installedPlugins?[0].secretSettingKeys = []
            try encoder.encode(rewritten).write(to: mirror)
            let oldRewrite = try #require(PluginCredentialMirrorReferences.capture(modelContext: env.context, extraMirrors: []))
            #expect(oldRewrite.holdsSkill(namespace, key: key.key))
            resume(env)
            #expect(MetadataFakeSecrets.value(namespace) == "synthetic-token")
            #expect(try env.outbox.pendingKeys() == [key])
            // The hold is ownership, not a permanently blocked outbox.
            env.context.delete(activation)
            try env.context.save()
            settle()
            #expect(MetadataFakeSecrets.value(namespace) == nil)
            #expect(try env.outbox.entries().isEmpty)
        }
    }

    @Test("Partial or contradictory empty inventories in admitted files hold the real outbox", arguments: [
        "bare", "unverified", "missing-markers", "wrong-version", "wrong-digest", "override", "setting", "known", "secret", "account", "nonempty-definition"
    ])
    func inconsistentExtraEmptyInventory(evidence: String) throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture()
        defer { env.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        var package = emptyPackage()
        if evidence == "nonempty-definition" {
            package.skills = [PluginSkill(name: "Agent", icon: "testtube.2", description: "Synthetic", allowedTools: [],
                disallowedTools: [], customTools: [], behaviorInstructions: "Fixture", environmentKeys: [], environmentValues: [])]
        }
        var plugin: [String: Any] = ["id": package.id, "credentialComponentIDs": [String](),
            "version": package.version, "digest": PluginDefinitionDigest.content(of: package), "secretSettingKeys": [String]()]
        switch evidence {
        case "bare": plugin = ["id": package.id, "credentialComponentIDs": [String]()]
        case "unverified": plugin["digest"] = "unverified-legacy"
        case "missing-markers": plugin.removeValue(forKey: "secretSettingKeys")
        case "wrong-version": plugin["version"] = "0.0.0"
        case "wrong-digest": plugin["digest"] = "content-v1:other"
        case "override": plugin["overriddenComponentIDs"] = ["skill:agent"]
        case "setting": plugin["settings"] = ["skill:agent#REGION": "synthetic-region"]
        case "known": plugin["knownComponentIDs"] = ["skill:agent"]
        case "secret": plugin["secretSettingKeys"] = ["skill:agent#API_TOKEN"]
        case "account": plugin["accounts"] = [["componentID": "connector:rest_api:account", "connectorID": UUID().uuidString, "isDefault": true]]
        default: break
        }
        let extra = env.root.appendingPathComponent("ambiguous-extra.json")
        let extraWorkspaceID = UUID(), orphan = UUID()
        let namespace = PluginActivation.credentialID(workspaceID: extraWorkspaceID, pluginID: package.id, componentID: "skill:agent")
        let key = PluginUpdateService.StaleSecret(key: "API_TOKEN", skillID: namespace)
        try write(plugin, at: extra, workspaceID: extraWorkspaceID)
        WorkspaceRecoveryTrust.recordLoadedMirrors([extra.path])
        try env.outbox.write([orphan])
        try env.outbox.journal([key])
        MetadataFakeSecrets.seed([namespace, orphan])
        try withDefinitions([package]) {
            #expect(PluginCredentialMirrorReferences.capture(modelContext: env.context) == nil)
            resume(env)
            #expect(MetadataFakeSecrets.value(namespace) == "synthetic-token")
            #expect(MetadataFakeSecrets.value(orphan) == "synthetic-token")
            #expect(try env.outbox.pending() == [orphan])
            #expect(try env.outbox.pendingKeys() == [key])
            try FileManager.default.removeItem(at: extra)
            resume(env)
            #expect(MetadataFakeSecrets.value(namespace) == nil)
            #expect(MetadataFakeSecrets.value(orphan) == nil)
            #expect(try env.outbox.entries().isEmpty)
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
