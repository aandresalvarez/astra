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
    @Test("Prior mirror admission survives reopening, retries failed saves and reads only once")
    func durableAdmission() throws {
        enum Injected: Error { case save, unexpectedRead }
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        let activation = PluginActivation(pluginID: "synthetic-admission-" + UUID().uuidString, recordedVersion: "1.0.0")
        env.context.insert(activation)
        activation.workspace = env.workspace
        WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
        try env.context.save()
        var config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        config.installedPlugins = [.init(id: activation.pluginID, version: "1.0.0",
            settings: ["unparsed-legacy-field": "synthetic-private-value"],
            activationID: activation.id.uuidString, knownComponentIDs: ["skill:agent"])]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: env.ownMirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try encoder.encode(config)
        try bytes.write(to: env.ownMirror)
        let key = PluginUpdateService.StaleSecret(key: "API_TOKEN",
            skillID: PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent"))
        let outbox = try #require(PluginSecretCleanupOutbox(for: env.context))
        try outbox.journal([key])
        var reads = 0
        #expect(throws: Injected.self) {
            try PluginCredentialEvidenceUpgrade.admit(workspace: env.workspace, context: env.context,
                load: { _ in reads += 1; return config }, save: { _ in throw Injected.save })
        }
        #expect(try Data(contentsOf: env.ownMirror) == bytes)
        #expect(try outbox.pendingKeys() == [key])
        #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation) == nil)
        try env.context.save()
        try PluginCredentialEvidenceUpgrade.admit(workspace: env.workspace, context: env.context,
            load: { _ in reads += 1; return config })
        #expect(reads == 2)
        let reopened = try env.reopen()
        let context = reopened.mainContext
        context.autosaveEnabled = false
        let workspace = try #require(context.fetch(FetchDescriptor<Workspace>()).first)
        try PluginCredentialEvidenceUpgrade.admit(workspace: workspace, context: context,
            load: { _ in reads += 1; throw Injected.unexpectedRead })
        #expect(reads == 2)
        let projected = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let ref = try #require(projected.installedPlugins?.first)
        #expect(ref.credentialReferences() == nil)
        #expect(ref.settings?["unparsed-legacy-field"] == nil)
        #expect(!(try String(decoding: encoder.encode(projected), as: UTF8.self)).contains("synthetic-private-value"))
    }

    @Test("A failed admission keeps the prior file and committed export pending through drain and retry")
    func admissionFailureRetainsPending() async throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: env.context) }
        let activation = PluginActivation(pluginID: "synthetic-failed-admission-" + UUID().uuidString, recordedVersion: "1.0.0")
        env.context.insert(activation)
        activation.workspace = env.workspace
        WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
        try env.context.save()
        let config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        let invalid = Data("synthetic unreadable prior mirror".utf8)
        try FileManager.default.createDirectory(at: env.ownMirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try invalid.write(to: env.ownMirror)
        #expect(await WorkspacePersistenceCoordinator.exportSavedMirrorNow(workspace: env.workspace, modelContext: env.context) == false)
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 1)
        #expect(try Data(contentsOf: env.ownMirror) == invalid)
        #expect(WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: env.context) == 0)
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 1)
        #expect(try Data(contentsOf: env.ownMirror) == invalid)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: env.ownMirror)
        #expect(await WorkspacePersistenceCoordinator.exportSavedMirrorNow(workspace: env.workspace, modelContext: env.context))
        #expect(WorkspacePersistenceCoordinator.pendingExportWorkspaceCount == 0)
        let restored = try WorkspaceConfigManager.loadConfig(from: env.ownMirror)
        #expect(restored.installedPlugins?.first?.secretSettingKeys == nil)
    }

    @Test("Read-only export creates its first mirror without saving into the source store")
    func readOnlyFirstMirror() throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        let activation = PluginActivation(pluginID: "synthetic-read-only-" + UUID().uuidString, recordedVersion: "1.0.0")
        env.context.insert(activation)
        activation.workspace = env.workspace
        WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
        WorkspaceCapabilityActivation.setConfigValue("synthetic-private-value", forKey: "skill:agent#API_TOKEN", on: activation)
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:agent#OTHER_TOKEN", on: activation)
        try env.context.save()
        let store = try #require(env.context.container.configurations.first?.url)
        try #require(FileManager.default.fileExists(atPath: store.path), "Synthetic store must exist")
        let readOnly = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: store, allowsSave: false)])
        let context = ModelContext(readOnly)
        let workspace = try #require(context.fetch(FetchDescriptor<Workspace>()).first)
        let result = WorkspaceConfigManager.exportToFileResult(workspace: workspace, modelContext: context, url: env.ownMirror)
        try #require(result.didExport)
        let config = try WorkspaceConfigManager.loadConfig(from: env.ownMirror)
        let ref = try #require(config.installedPlugins?.first)
        #expect(ref.credentialReferences()?.secretSettingKeys.contains("skill:agent#API_TOKEN") == true)
        #expect(!(try String(contentsOf: env.ownMirror, encoding: .utf8)).contains("synthetic-private-value"))
        let reopened = try env.reopen()
        let saved = try #require(reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
        #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: saved) == nil)
    }

    @Test("Recovered or newer legacy copies cannot certify admission of the current own mirror",
        arguments: ["recovered-copy", "newer-legacy-copy"])
    func priorOwnMirrorStillNeedsAdmission(mode: String) async throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        let trust = WorkspaceRecoveryTrust.state, mirrors = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.set(trust); WorkspaceRecoveryTrust.recordLoadedMirrors(mirrors) }
        let activation = PluginActivation(pluginID: "synthetic-copy-" + UUID().uuidString, recordedVersion: "1.0.0")
        env.context.insert(activation)
        activation.workspace = env.workspace
        WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:agent#OTHER_TOKEN", on: activation)
        try env.context.save()
        var current = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        current.installedPlugins?[0].settings = ["unparsed-current-field": "synthetic-private-value"]
        current.exportedAt = Date(timeIntervalSinceReferenceDate: 100)
        var alternate = current
        alternate.installedPlugins?[0].settings = nil
        alternate.exportedAt = Date(timeIntervalSinceReferenceDate: 200)
        let localMarker = PluginCredentialRecoveryEvidence(namespaceSeed: "", credentialNamespaceSeed: "",
            admittedActivationID: activation.id.uuidString)
        alternate.installedPlugins?[0].credentialRecoveryEvidence = localMarker
        var retired = RetiredPluginActivation(pluginID: activation.pluginID, namespaceSeed: "",
            overriddenComponentIDs: [], overridingRowIDs: [])
        retired.credentialRecoveryEvidence = localMarker
        alternate.retiredPlugins = [retired]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: env.ownMirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(current).write(to: env.ownMirror)
        let workspace: Workspace
        let pluginID = activation.pluginID
        if mode == "recovered-copy" {
            env.context.delete(env.workspace)
            try env.context.save()
            workspace = WorkspaceConfigManager.importWorkspace(from: alternate, modelContext: env.context,
                capabilityTrust: .preserveRecordedState)
            try env.context.save()
            let restored = try #require(WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace))
            #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: restored)?.hasAdmittedMirror(for: restored) != true)
        } else {
            workspace = env.workspace
            let legacy = URL(fileURLWithPath: WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspace.primaryPath))
            try encoder.encode(alternate).write(to: legacy)
            var loaded = 0, reimported = false
            let discoveredMirrors = [env.ownMirror, legacy]
            let recovered = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(modelContext: env.context,
                extraRoots: [workspace.primaryPath], includeDefaultRoots: false, pendingCleanup: true,
                registeredFolders: [workspace.primaryPath], afterImport: { reimported = true },
                loadedMirrors: { loaded = $0.count }, discover: { (discoveredMirrors, true) }).value
            #expect(recovered && loaded == 2 && !reimported)
        }
        #expect(await WorkspacePersistenceCoordinator.exportSavedMirrorNow(workspace: workspace, modelContext: env.context))
        let written = try WorkspaceConfigManager.loadConfig(from: env.ownMirror)
        let ref = try #require(written.installedPlugins?.first)
        #expect(ref.credentialReferences() == nil)
        #expect(ref.credentialRecoveryEvidence?.admittedActivationID == nil)
        #expect(written.retiredPlugins?.allSatisfy { $0.credentialRecoveryEvidence?.admittedActivationID == nil } != false)
        #expect(!(try String(contentsOf: env.ownMirror, encoding: .utf8)).contains("synthetic-private-value"))
    }

    @Test("First admission rereads a replaced scan file and compares UUID identities",
        arguments: ["changed", "lowercase", "control", "invalid", "different", "read-once"])
    func firstAdmissionBoundary(mode: String) async throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: env.context) }
        let trust = WorkspaceRecoveryTrust.state, mirrors = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.set(trust); WorkspaceRecoveryTrust.recordLoadedMirrors(mirrors) }
        let mirror = env.ownMirror, root = env.workspace.primaryPath
        let package = PluginPackage(id: "synthetic-admission-boundary-" + UUID().uuidString, name: "Admission", icon: "testtube.2",
            description: "Synthetic", author: "Tests", category: "Tests", tags: [], version: "1.0.0", skills: [],
            connectors: [], localTools: [], mcpServers: [], templates: [])
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
            try env.context.save()
            var config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
            #expect(config.installedPlugins?.first?.credentialComponentIDs == [])
            #expect(config.installedPlugins?.first?.secretSettingKeys == [])
            if mode == "lowercase" { config.id = config.id?.lowercased() }
            if mode == "invalid" { config.id = "invalid-workspace-id" }
            if mode == "different" { config.id = UUID().uuidString }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let original = try encoder.encode(config)
            var replacement = config
            replacement.installedPlugins?[0].settings = ["unresolved-legacy-key": "synthetic-private-value"]
            replacement.installedPlugins?[0].credentialComponentIDs = nil
            replacement.installedPlugins?[0].secretSettingKeys = nil
            let replaced = try encoder.encode(replacement)
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: mirror, options: .atomic)
            let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent")
            let key = PluginUpdateService.StaleSecret(key: "API_TOKEN", skillID: namespace)
            let outbox = try #require(PluginSecretCleanupOutbox(for: env.context))
            try outbox.journal([key])
            var loaded = 0, reimported = false, replacementFailed = false
            let recovered = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(modelContext: env.context,
                extraRoots: [root], includeDefaultRoots: false, pendingCleanup: true, registeredFolders: [root],
                afterImport: { reimported = true }, loadedMirrors: { files in
                    loaded = files.count
                    WorkspaceRecoveryTrust.recordLoadedMirrors(files.map(\.path))
                    if mode == "changed" {
                        do { try replaced.write(to: mirror, options: .atomic) }
                        catch { replacementFailed = true }
                    }
                }, discover: { ([mirror], true) }).value
            #expect(recovered && loaded == 1 && !reimported && !replacementFailed)
            WorkspaceRecoveryTrust.set(.trusted)
            if mode == "changed" { #expect(PluginCredentialMirrorReferences.capture(modelContext: env.context) == nil) }
            if mode == "read-once" {
                // A completed admission belongs to the durable store. Future
                // saved projections can repair a damaged cache without trying
                // to admit it again or losing their committed obligation.
                try #require(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation)?.hasAdmittedMirror(for: activation) == true)
                try Data("synthetic damaged cache after admission".utf8).write(to: mirror, options: .atomic)
            }
            UpgradeSecrets.seed(namespace)
            let diagnostics = StartupCleanupAggregate()
            await WorkspacePersistenceWork.$cleanupJob.withValue(diagnostics) {
                await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context, secrets: UpgradeSecrets.self)
            }
            let rejected = ["invalid", "different"].contains(mode)
            let held = mode == "changed" || rejected
            #expect(UpgradeSecrets.value(namespace) == (held ? "synthetic-token" : nil))
            #expect(try outbox.pendingKeys() == (held ? [key] : []))
            #expect(((Int(diagnostics.fields()["copy_succeeded"] ?? "0") ?? 0) > 0) == !rejected)
            let direct = WorkspaceConfigManager.exportToFileResult(workspace: env.workspace, modelContext: env.context, url: mirror)
            #expect(direct.didExport == !rejected)
            if rejected {
                #expect(try Data(contentsOf: mirror) == original)
                #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation)?.hasAdmittedMirror(for: activation) != true)
                // Repairing the header retries the ordinary writer/outbox;
                // the failed admission neither committed proof nor stranded it.
                var repaired = config
                repaired.id = env.workspace.id.uuidString
                try encoder.encode(repaired).write(to: mirror, options: .atomic)
                #expect(await WorkspacePersistenceCoordinator.exportSavedMirrorNow(workspace: env.workspace, modelContext: env.context))
                await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context, secrets: UpgradeSecrets.self)
                #expect(UpgradeSecrets.value(namespace) == nil)
                #expect(try outbox.pendingKeys().isEmpty)
                #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation)?.hasAdmittedMirror(for: activation) == true)
            } else {
                #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation)?.hasAdmittedMirror(for: activation) == true)
                let written = try WorkspaceConfigManager.loadConfig(from: mirror)
                if mode == "changed" { #expect(written.installedPlugins?.first?.credentialReferences() == nil) }
                #expect(!(try String(contentsOf: mirror, encoding: .utf8)).contains("synthetic-private-value"))
            }
        }
    }

    @Test("Recovered evidence follows its credential generation through rollback and replacement",
        arguments: ["inventory", "ambiguous", "unresolved-account", "unresolved-setting"])
    func recoveredGenerationReplacement(evidence: String) async throws {
        let env = try PluginRecoveryMirrorCredentialTests.Fixture(onDisk: true)
        defer { env.removeFiles() }
        let trust = WorkspaceRecoveryTrust.state, mirrors = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.set(trust); WorkspaceRecoveryTrust.recordLoadedMirrors(mirrors) }
        WorkspaceRecoveryTrust.recordLoadedMirrors([])
        let mirror = env.ownMirror
        let package = PluginPackage(id: "synthetic-generation-" + UUID().uuidString, name: "Generation", icon: "testtube.2",
            description: "Synthetic", author: "Tests", category: "Tests", tags: [], version: "1.0.0", skills: [],
            connectors: [], localTools: [], mcpServers: [], templates: [])
        let packs = AstraPackCatalog()
        let inputs = CapabilityResolutionInputs(libraryDirectory: CapabilityLibrary().directory.standardizedFileURL,
            packageDefinitions: [package], approvalsDirectory: CapabilityApprovalStore().directory.standardizedFileURL,
            approvalRecords: [], packBuiltInDirectory: packs.builtInDirectory?.standardizedFileURL,
            packLocalStorageRoot: packs.localStorageRoot?.standardizedFileURL, packCatalog: .init(entries: [], diagnostics: []))
        try await CapabilityResolutionInputs.$pinned.withValue(inputs) {
            var config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
            config.installedPlugins = [.init(id: package.id, version: package.version,
                settings: evidence == "unresolved-setting" ? ["unparsed-setting": "synthetic-private-value"] : nil,
                accounts: evidence == "unresolved-account" ? [.init(componentID: "connector:rest_api:missing", connectorID: UUID().uuidString, isDefault: true)] : nil,
                credentialComponentIDs: evidence == "inventory" ? ["skill:agent"] : [], digest: PluginDefinitionDigest.content(of: package))]
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(config).write(to: mirror)
            let loaded = try WorkspaceConfigManager.loadConfig(from: mirror)
            env.context.delete(env.workspace)
            try env.context.save()
            let workspace = WorkspaceConfigManager.importWorkspace(from: loaded, modelContext: env.context,
                capabilityTrust: .preserveRecordedState)
            try env.context.save()
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
            let oldNamespace = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent")
            let oldKey = PluginUpdateService.StaleSecret(key: "API_TOKEN", skillID: oldNamespace)
            let outbox = try #require(PluginSecretCleanupOutbox(for: env.context))
            try outbox.journal([oldKey])
            UpgradeSecrets.seed(oldNamespace)
            WorkspaceRecoveryTrust.set(.trusted)
            let settle = {
                await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context, secrets: UpgradeSecrets.self)
            }
            await settle()
            #expect(UpgradeSecrets.value(oldNamespace) == "synthetic-token")
            #expect(try outbox.pendingKeys() == [oldKey])
            let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
            WorkspaceCapabilityActivation.setCredentialNamespaceSeed("staged-replacement", on: activation)
            WorkspaceCapabilityActivation.restore(snapshot, to: workspace)
            try env.context.save()
            await settle()
            #expect(UpgradeSecrets.value(oldNamespace) == "synthetic-token")
            #expect(try outbox.pendingKeys() == [oldKey])
            WorkspaceCapabilityActivation.setCredentialNamespaceSeed("published-replacement", on: activation)
            try env.context.save()
            let newNamespace = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:agent")
            try #require(newNamespace != oldNamespace)
            // This accepted definition has no namespaces. Old retained
            // references must not turn its new empty generation into an owner.
            UpgradeSecrets.seed([oldNamespace, newNamespace])
            try outbox.journal([.init(key: "API_TOKEN", skillID: newNamespace)])
            await settle()
            let unresolved = evidence.hasPrefix("unresolved-")
            #expect(UpgradeSecrets.value(oldNamespace) == (unresolved ? "synthetic-token" : nil))
            #expect(UpgradeSecrets.value(newNamespace) == (unresolved ? "synthetic-token" : nil))
            #expect(try outbox.entries().count == (unresolved ? 2 : 0))
            let exported = try WorkspaceConfigManager.loadConfig(from: mirror)
            if unresolved {
                #expect(exported.installedPlugins?.first?.credentialComponentIDs == nil)
                #expect(exported.installedPlugins?.first?.secretSettingKeys == nil)
                WorkspaceCapabilityActivation.retire(activation, in: workspace)
                env.context.delete(activation)
                try env.context.save()
                await settle()
                #expect(UpgradeSecrets.value(oldNamespace) == nil)
                #expect(UpgradeSecrets.value(newNamespace) == nil)
                #expect(try outbox.entries().isEmpty)
            } else {
                #expect(exported.installedPlugins?.first?.credentialComponentIDs == [])
                #expect(exported.installedPlugins?.first?.secretSettingKeys == [])
            }
        }
    }

    @Test("Startup export preserves unknown current keys and releases empty or retired generations",
        arguments: ["current", "positive", "raw-positive", "unparsed", "empty", "removed", "replaced"])
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
        if !["empty", "unparsed"].contains(mode) {
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
            if ["positive", "raw-positive"].contains(mode) {
                WorkspaceCapabilityActivation.setConfigValue("synthetic-private-value", forKey: "skill:agent#API_TOKEN", on: activation)
                WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:agent#OTHER_TOKEN", on: activation)
            } else if !["empty", "unparsed"].contains(mode) {
                WorkspaceCapabilityActivation.setConfigValue("synthetic-region", forKey: "skill:agent#REGION", on: activation)
            }
            // Seed the historical persisted result of pre-PR recovery and
            // migration, which had no credential-evidence record. Current
            // import/export code must not manufacture the upgrade fixture.
            WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: package), on: activation)
            try env.context.save()
            #expect(activation.knownComponentIDs == (["empty", "unparsed"].contains(mode) ? [] : ["skill:agent"]))
            #expect(WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation) == nil)
            var old = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
            // The pre-PR serializer omitted empty markers and had no derived
            // inventory/recovery fields. Preserve its actual on-disk shape.
            old.installedPlugins?[0].secretSettingKeys = ["positive", "raw-positive"].contains(mode) ? ["skill:agent#OTHER_TOKEN"] : nil
            old.installedPlugins?[0].credentialComponentIDs = nil
            old.installedPlugins?[0].credentialRecoveryEvidence = nil
            if mode == "positive" {
                old.installedPlugins?[0].settings = ["skill:agent#API_TOKEN": "synthetic-private-value"]
                old.installedPlugins?[0].activationID = nil
            }
            if mode == "unparsed" {
                old.installedPlugins?[0].settings = ["unresolved-legacy-key": "synthetic-private-value"]
                old.installedPlugins?[0].activationID = nil
            }
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
            let before = PluginCredentialMirrorReferences.capture(modelContext: saved)
            if mode == "unparsed" { #expect(before == nil) }
            else { #expect(before?.holdsSkill(namespace, key: key.key) == (!["empty", "raw-positive"].contains(mode))) }
            UpgradeSecrets.seed(namespace)
            let diagnostics = StartupCleanupAggregate()
            // No injected writer: this is the production background saved
            // projection, backup, file replacement, reread and outbox path.
            await WorkspacePersistenceWork.$cleanupJob.withValue(diagnostics) {
                await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: saved, secrets: UpgradeSecrets.self)
            }
            #expect((Int(diagnostics.fields()["copy_succeeded"] ?? "0") ?? 0) > 0)
            let after = PluginCredentialMirrorReferences.capture(modelContext: saved)
            let held = ["current", "positive", "raw-positive", "unparsed"].contains(mode)
            if mode == "unparsed" { #expect(after == nil) }
            else { #expect(after?.holdsSkill(namespace, key: key.key) == held) }
            #expect(UpgradeSecrets.value(namespace) == (held ? "synthetic-token" : nil))
            #expect(try outbox.pendingKeys() == (held ? [key] : []))
            let exported = try WorkspaceConfigManager.loadConfig(from: mirror)
            if ["current", "unparsed"].contains(mode) { #expect(exported.installedPlugins?.first?.secretSettingKeys == nil) }
            if ["positive", "raw-positive"].contains(mode) {
                #expect(exported.installedPlugins?.first?.secretSettingKeys == ["skill:agent#OTHER_TOKEN"])
                #expect(exported.installedPlugins?.first?.settings?["skill:agent#API_TOKEN"] == nil)
            }
            #expect(!(try String(contentsOf: mirror, encoding: .utf8)).contains("synthetic-private-value"))
            if mode == "empty" { #expect(exported.installedPlugins?.first?.secretSettingKeys == []) }
        }
    }
}

private enum UpgradeSecrets: SkillSecretPersisting {
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
