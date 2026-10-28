import Foundation
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Plugins 2.0 R3 review fixes: what a failed read, a retry, an automatic
/// pass or an earlier ASTRA's identities must not lose. Fixtures are
/// `PluginOperationsTests`'s.
@Suite("Plugin operations review fixes")
@MainActor
struct PluginOperationsReviewTests {
    typealias Fixtures = PluginOperationsTests

    @Test("Settings cannot create successor ownership before Update", arguments: [false, true])
    func successorSettingWaitsForUpdate(secret: Bool) throws {
        let env = try Fixtures.Environment()
        var initial = Fixtures.package(version: "1.0.0")
        initial.connectors = []
        initial.skills[0].environmentKeys = [secret ? "API_TOKEN" : "PROJECT"]
        initial.skills[0].environmentValues = [""]
        try env.install(initial)
        let before = WorkspaceCapabilityActivation.snapshot(env.workspace)
        var next = initial
        next.skills[0].id = "successor"
        next.skills[0].replaces = [CapabilityResourceOrigin.componentID(for: initial.skills[0])]
        #expect(throws: PluginOperations.OperationError.updateRequired) {
            try PluginOperations.setSetting(next.skills[0].environmentKeys[0], to: "new-setting-value", of: next.skills[0],
                package: next, in: env.workspace, modelContext: env.context)
        }
        #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == before)
        #expect(!env.context.hasChanges)
    }

    @Test("A delete confirmation whose workspaces can't be read offers no scope")
    func deleteScopeFailsClosed() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let account = try #require(env.workspace.connectors.first)
        #expect(throws: PluginOperations.OperationError.storeUnreadable) {
            try PluginOperations.workspacesUsing(account) { throw CocoaError(.fileReadUnknown) }
        }
        // A row with no store to read is no better.
        #expect(throws: PluginOperations.OperationError.storeUnreadable) {
            try PluginOperations.workspacesUsing(Connector(name: "Detached", serviceType: "tracker"))
        }
    }

    @Test("An import's snapshot of the installed copy is deleted once the import is kept or refused")
    func importSnapshotsAreDiscarded() throws {
        let env = try Fixtures.Environment()
        let temporary = env.root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let library = CapabilityLibrary(directory: env.library.directory, fileManager: ScopedTemporaryFileManager(temporary))
        func snapshots() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("astra-capability-snapshot-") }
        }
        try library.install(Fixtures.package(version: "1.0.0"), sourceMetadata: .localLibrary())
        let update = CapabilityPackageValidator.validate(
            package: Fixtures.package(version: "2.0.0"), installedPackages: library.installedPackages(), checkPrerequisites: false
        )
        try CapabilityPackageImporter(library: library).importValidatedPackage(update)
        #expect(library.installedPackage(id: "ops.report")?.version == "2.0.0")
        #expect(try snapshots().isEmpty)

        // Refused on the re-check against the library: another installed
        // plugin declares its MCP server.
        var holder = Fixtures.package(version: "1.0.0")
        holder.id = "ops.holder"
        holder.mcpServers = [PluginMCPServer(id: "tracker", displayName: "Tracker", transport: .stdio, command: "tracker-mcp")]
        try library.install(holder, sourceMetadata: .localLibrary())
        var incoming = Fixtures.package(version: "3.0.0")
        incoming.mcpServers = holder.mcpServers
        let stale = CapabilityPackageValidator.validate(package: incoming, installedPackages: [], checkPrerequisites: false)
        #expect(stale.canInstall)
        #expect(throws: CapabilityPackageImportError.self) {
            try CapabilityPackageImporter(library: library).importValidatedPackage(stale)
        }
        #expect(library.installedPackage(id: "ops.report")?.version == "2.0.0")
        #expect(try snapshots().isEmpty)
    }

    /// Puts snapshots in a folder of the test's own.
    final class ScopedTemporaryFileManager: FileManager, @unchecked Sendable {
        let scoped: URL
        init(_ scoped: URL) { self.scoped = scoped }
        override var temporaryDirectory: URL { scoped }
    }

    @Test("An automatic rename keeps a secret the successor stopped declaring until Update releases it")
    func automaticRenameKeepsUndeclaredSecret() throws {
        guard AstraSecureKeychainTestSupport.isAvailable else { return }
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: [])
        }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                let env = try Fixtures.Environment()
                var v1 = Fixtures.package(version: "1.0.0")
                v1.skills[0].environmentKeys = ["PROJECT", "API_TOKEN", "LEGACY_TOKEN"]
                v1.skills[0].environmentValues = ["default-project", "", ""]
                try env.install(v1)
                for (key, value) in [("API_TOKEN", "kept"), ("LEGACY_TOKEN", "legacy")] {
                    try PluginOperations.setSetting(key, to: value, of: v1.skills[0], package: v1, in: env.workspace, modelContext: env.context)
                }
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))

                var v2 = Fixtures.package(version: "2.0.0")
                v2.skills[0].id = "summary-agent"
                v2.skills[0].replaces = ["report-agent"]
                v2.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
                v2.skills[0].environmentValues = ["default-project", ""]
                try env.importUpdate(v2, mode: .automatic)
                // The old namespace was released and settled; both values
                // moved with the rename.
                #expect(activation.recordedVersion == "1.0.0")
                #expect(try PluginOperations.setting("API_TOKEN", of: v2.skills[0], in: activation) == "kept")
                #expect(try PluginOperations.setting("LEGACY_TOKEN", of: v2.skills[0], in: activation) == "legacy")
                #expect(activation.secretSettingKeys.contains("skill:summary-agent#LEGACY_TOKEN"))

                try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [v2], mode: .release, approvalRecords: PluginOperationsTests.approvals([v2]))
                #expect(activation.recordedVersion == "2.0.0")
                #expect(activation.secretSettingKeys == ["skill:summary-agent#API_TOKEN"])
                #expect(try PluginOperations.setting("LEGACY_TOKEN", of: v2.skills[0], in: activation).isEmpty)
                #expect(try PluginOperations.setting("API_TOKEN", of: v2.skills[0], in: activation) == "kept")
            }
        }
    }

    @Test("A credential an update stopped declaring stays on the plugin's account but never reaches a run")
    func undeclaredAccountCredentialIsNotProjected() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.connectors[0].credentialHints.append(.init(key: "LEGACY_TOKEN", hint: "Legacy"))
        try env.install(v1)
        let account = try #require(env.workspace.connectors.first { $0.originPackageID == v1.id })
        let store = MockSecretStore()
        for key in ["TRACKER_TOKEN", "LEGACY_TOKEN"] {
            #expect(account.saveCredential(key: key, value: "\(key)-value", store: store))
        }
        try env.context.save()
        func projectedCredentials(_ package: PluginPackage) -> [String] {
            let projection = PluginRuntimeProjection.project(workspace: env.workspace, packages: [package], connectorMode: .runtimeCopies)
            return ConnectorRuntimeProjection(connectors: projection.connectors, secretStore: store, credentialExposurePolicy: .allowAllCredentials)
                .environmentBindings().filter { $0.kind == .credential }.map(\.originalKey)
        }
        #expect(projectedCredentials(v1) == ["TRACKER_TOKEN", "LEGACY_TOKEN"])

        let v2 = Fixtures.package(version: "2.0.0")
        for mode in [PluginUpdateService.Mode.automatic, .release] {
            try env.importUpdate(v2, mode: mode)
            // The row keeps the key (an Update never deletes what the person
            // entered); the runtime sees only what v2 declares.
            #expect(account.credentialKeys == ["TRACKER_TOKEN", "LEGACY_TOKEN"])
            #expect(projectedCredentials(v2) == ["TRACKER_TOKEN"])
        }
    }

    @Test("A manifest an earlier ASTRA installed by name keeps its settings and accounts when its ids are adopted")
    func adoptedManifestIDsReplaceNameIdentities() throws {
        let env = try Fixtures.Environment()
        let v1 = Fixtures.package(version: "1.0.0")
        try env.install(v1)
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], package: v1, in: env.workspace, modelContext: env.context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        let account = try #require(activation.bindings.first?.account)

        var manifest = PluginManifestConverter.manifest(from: Fixtures.package(version: "2.0.0"))
        for index in manifest.components.indices {
            switch manifest.components[index].kind {
            case .skill: manifest.components[index].id = "custom-agent"
            case .connector: manifest.components[index].id = "custom-tracker"
            case .tool: manifest.components[index].id = "custom-cli"
            default: break
            }
        }
        let v2 = try PluginManifestConverter.checkedPackage(from: manifest)
        #expect(v2.skills[0].replaces == ["skill:report-agent"])
        #expect(v2.connectors[0].replaces == ["connector:tracker:tracker-api"])
        #expect(v2.localTools[0].replaces?.contains("tool:cli:report-cli:report-cli") == true)
        #expect(PluginUpdateService.replacesProblems(in: v2).isEmpty)
        // Converting back and again adds nothing.
        let again = try PluginManifestConverter.checkedPackage(from: PluginManifestConverter.manifest(from: v2))
        #expect(try CapabilityApprovalDigest.digest(for: again) == CapabilityApprovalDigest.digest(for: v2))

        try env.importUpdate(v2)
        #expect(activation.recordedVersion == "2.0.0")
        #expect(activation.configuration(forComponent: "skill:custom-agent") == ["PROJECT": "alpha"])
        #expect(activation.accounts(forComponent: "connector:tracker:custom-tracker").map(\.id) == [account.id])
    }

    @Test("A stamped account nothing owns stays in scope; a dropped component's account does not")
    func unboundStampedAccountIsAuthored() throws {
        let env = try Fixtures.Environment()
        // A row the migration couldn't bind: its plugin isn't added here.
        let legacy = Connector(name: "Legacy Tracker", serviceType: "tracker")
        legacy.originPackageID = "ops.gone"
        legacy.originComponentID = "connector:tracker:legacy-tracker"
        env.context.insert(legacy)
        legacy.workspace = env.workspace

        // An account Remove left stamped (its credentials couldn't move).
        let package = Fixtures.package(version: "1.0.0")
        try env.context.save()
        try env.install(package)
        let kept = try #require(env.workspace.connectors.first { $0.originPackageID == package.id })
        try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context)
        CapabilityResourceOrigin.stamp(kept, package: package, componentID: CapabilityResourceOrigin.componentID(for: package.connectors[0]))
        let task = AgentTask(title: "Report", goal: "Report", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()

        for connector in [legacy, kept] {
            #expect(!WorkspaceCapabilities.isPluginAccount(connector))
            #expect(WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: []).activeConnectors.contains { $0.id == connector.id })
            #expect(TaskCapabilityResolver(task: task).allConnectors.contains { $0.id == connector.id })
        }

        // Added again with the component gone: the plugin's row stays out.
        var v2 = Fixtures.package(version: "2.0.0")
        v2.connectors = []
        try env.install(v2)
        #expect(WorkspaceCapabilities.isPluginAccount(kept))
        #expect(!WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: [v2]).activeConnectors.contains { $0.id == kept.id })
    }

    @Test("A retried Remove that fails keeps the intent an earlier Remove recorded")
    func failedRetryKeepsEarlierRemoveIntent() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        let uninstaller = CapabilityUninstaller(library: env.library)

        // A Remove of its own that fails leaves nothing behind.
        #expect(throws: CapabilityUninstaller.UninstallError.self) {
            try uninstaller.remove(package, modelContext: env.context, persist: { _, _ in false }, removeJournal: journal)
        }
        #expect(try journal.pending().isEmpty)

        // An earlier Remove's intent survives this one's failure.
        #expect(try journal.begin(package.id))
        #expect(throws: CapabilityUninstaller.UninstallError.self) {
            try uninstaller.remove(package, modelContext: env.context, persist: { _, _ in false }, removeJournal: journal)
        }
        #expect(try journal.pending() == [package.id])
        #expect(try !journal.begin(package.id))
    }

    @Test("Remove keeps a plugin template the person edited, as their own, and deletes the unedited one")
    func removeKeepsEditedTemplates() throws {
        let env = try Fixtures.Environment()
        let folder = env.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        env.workspace.primaryPath = folder.path
        var package = Fixtures.package(version: "1.0.0")
        package.templates = [Fixtures.template("Weekly", goal: "Write it"), Fixtures.template("Daily", goal: "Note it")]
        try env.install(package)
        let weekly = try #require(env.workspace.templates.first { $0.name == "Weekly" })
        let daily = try #require(env.workspace.templates.first { $0.name == "Daily" })
        weekly.mainGoal = "Write it my way"
        try env.context.save()

        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        let result = try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context, removeJournal: journal)
        #expect(result.removedTemplateIDs == [daily.id])
        #expect(env.workspace.templates.filter { !$0.isDeleted }.map(\.id) == [weekly.id])
        #expect(weekly.mainGoal == "Write it my way")
        #expect(weekly.originPackageID == nil)
        #expect(weekly.originComponentID == nil)
    }

    @Test("Only a bundled plugin's own settings stay plain; one named like a credential is refused, any other plugin's is stored as one")
    func credentialNamedSettingsAreRefused() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let index = try #require(jira.connectors.firstIndex { !$0.configHints.isEmpty })
        func blocked(_ package: PluginPackage) -> Bool {
            CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)
                .blockers.contains { $0.title == "Credential stored as a setting" }
        }
        func adding(_ key: String, to package: PluginPackage) -> PluginPackage {
            var extended = package
            var hint = extended.connectors[index].configHints[0]
            hint.key = key
            extended.connectors[index].configHints.append(hint)
            return extended
        }
        #expect(!blocked(jira))
        // A bundled definition naming a setting like a credential is a mistake.
        #expect(blocked(adding("JIRA_API_TOKEN", to: jira)))
        // Any other key it doesn't declare isn't refused: it is stored as a
        // credential, whatever it is called.
        for key in ["PROJECT_KEY", "SITE", "TENANT", "VALUE"] {
            let extended = adding(key, to: jira)
            #expect(!blocked(extended), "\(key)")
            let stored = PluginConnectorFieldTrust.asStored(extended.connectors[index], in: extended)
            #expect(!stored.configHints.contains { $0.key == key } && stored.credentialHints.contains { $0.key == key }, "\(key)")
        }
        // Another plugin's settings are all credentials, so none is refused.
        var imported = adding("JIRA_API_TOKEN", to: jira)
        imported.id = "imported.jira-copy"
        #expect(!blocked(imported))
        #expect(PluginConnectorFieldTrust.asStored(imported.connectors[index], in: imported).configHints.isEmpty)
        // Every built-in's own settings are trusted.
        for builtIn in PluginCatalog.builtInPackages {
            for connector in builtIn.connectors {
                #expect(
                    PluginConnectorFieldTrust.trustedPlainSettingKeys(of: connector, in: builtIn) == Set(connector.configHints.map(\.key)),
                    "\(builtIn.id) \(connector.name)"
                )
            }
        }
    }
}
