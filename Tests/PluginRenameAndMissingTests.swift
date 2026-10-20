import Foundation
import os
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// A rename never merges two components an activation holds, and an
/// activation whose plugin the library lost can be removed through the
/// normal Remove. Fixtures are `PluginOperationsTests`'s.
@Suite("Plugin renames into known components and missing plugins")
@MainActor
struct PluginRenameAndMissingTests {
    typealias Fixtures = PluginOperationsTests

    /// v1 with skills A (report-agent) and B (summary-agent) and connectors
    /// X (tracker-api) and Y (tracker2), each with state of its own.
    static func twoOfEach() -> PluginPackage {
        var package = Fixtures.package(version: "1.0.0")
        package.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        package.skills[0].environmentValues = ["default-project", ""]
        var second = package.skills[0]
        second.id = "summary-agent"
        second.name = "Summary Agent"
        package.skills.append(second)
        var y = package.connectors[0]
        y.id = "tracker2"
        y.name = "Tracker Two"
        package.connectors.append(y)
        return package
    }

    @Test("A rename into a component the activation already holds moves nothing and awaits Update with a reason")
    func renameIntoKnownComponentIsRefused() throws {
        let env = try Fixtures.Environment()
        let v1 = Self.twoOfEach()
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)
        let secretKey = PluginActivation.settingKey(componentID: "skill:report-agent", key: "API_TOKEN")
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: secretKey, on: activation)
        let x = CapabilityResourceOrigin.componentID(for: v1.connectors[0])
        let y = CapabilityResourceOrigin.componentID(for: v1.connectors[1])
        let xAccounts = activation.accounts(forComponent: x).map(\.id)
        let yAccounts = activation.accounts(forComponent: y).map(\.id)
        #expect(!xAccounts.isEmpty && xAccounts != yAccounts)
        try env.context.save()

        // v2 keeps B and Y, each declaring it takes over A and X.
        var v2 = v1
        v2.version = "2.0.0"
        v2.skills.removeFirst()
        v2.skills[0].replaces = ["report-agent"]
        v2.connectors.removeFirst()
        v2.connectors[0].replaces = [x]
        #expect(PluginUpdateService.replacesProblems(in: v2).isEmpty)

        func unchanged() {
            #expect(activation.recordedVersion == "1.0.0")
            #expect(activation.configuration(forComponent: "skill:report-agent") == ["PROJECT": "alpha"])
            #expect(activation.secretSettingKeys.contains(secretKey))
            #expect(activation.accounts(forComponent: x).map(\.id) == xAccounts)
            #expect(activation.accounts(forComponent: y).map(\.id) == yAccounts)
            #expect(RecordingCleanup.deleted.isEmpty)
        }
        RecordingCleanup.reset()
        // The first collision, by predecessor ID, is the one named.
        #expect(throws: PluginUpdateService.UpdateError.renameIntoKnownComponent(component: y, predecessor: x)) {
            try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [v2], mode: .release, secrets: RecordingCleanup.self)
        }
        unchanged()
        try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [v2], mode: .automatic, secrets: RecordingCleanup.self)
        unchanged()
        #expect(activation.awaitingUpdate)

        // The validator names it against the installed version, and only then.
        let report = CapabilityPackageValidator.validate(package: v2, installedPackages: [v1], checkPrerequisites: false)
        #expect(report.issues.contains { $0.title == "Rename into an existing component" && $0.component == "skill:summary-agent" })
        #expect(report.issues.contains { $0.title == "Rename into an existing component" && $0.component == CapabilityResourceOrigin.componentID(for: v2.connectors[0]) })
        var onlyA = v1
        onlyA.skills.removeLast()
        onlyA.connectors.removeLast()
        #expect(!CapabilityPackageValidator.validate(package: v2, installedPackages: [onlyA], checkPrerequisites: false)
            .issues.contains { $0.title == "Rename into an existing component" })
    }

    @Test("A plugin the library lost is removed through Remove: secrets journaled then cleaned, mirror rewritten")
    func missingPluginIsForgotten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-missing-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))]
        )
        Fixtures.Environment.retained.append(container)
        let context = container.mainContext
        let workspace = Workspace(name: "Ops", primaryPath: folder.path)
        context.insert(workspace)
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
        var package = Fixtures.package(version: "1.0.0")
        package.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        package.skills[0].environmentValues = ["default-project", ""]
        try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            .install(package, into: workspace, modelContext: context, announceCatalogMutation: false)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        WorkspaceCapabilityActivation.setSecretRecorded(
            true, forKey: PluginActivation.settingKey(componentID: "skill:report-agent", key: "API_TOKEN"), on: activation
        )
        try context.save()
        let account = try #require(workspace.connectors.first)
        let namespace = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:report-agent")

        // The library loses it: the row lists it as missing, with Remove.
        _ = try library.removePackage(id: package.id)
        #expect(library.installedPackage(id: package.id) == nil)
        let row = try #require(PluginsSurfacePresentation.makeState(
            [PluginsSurfacePresentation.missingInput(pluginID: package.id, isEnabled: true)], query: ""
        ).actionNeeded.first)
        #expect(row.isMissing && row.isRemovable && row.verb == nil)
        #expect(row.subtitle == PluginsSurfacePresentation.missingMessage)

        let outbox = try #require(PluginSecretCleanupOutbox(for: context))
        let journal = PluginRemoveJournal(fileURL: root.appendingPathComponent("PluginRemoveIntents.json"))
        RecordingCleanup.reset()
        RecordingCleanup.onClean = { RecordingCleanup.pendingAtClean = (try? outbox.pending()) ?? [] }
        try CapabilityUninstaller(library: library).forgetMissing(
            pluginID: package.id, modelContext: context, removeJournal: journal, skillSecrets: RecordingCleanup.self
        )
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) == nil)
        #expect(RecordingCleanup.pendingAtClean.contains(namespace))
        #expect(RecordingCleanup.cleaned.contains(namespace))
        #expect(try outbox.pending().isEmpty)
        #expect(try journal.pending().isEmpty)
        // Its account stays, no longer the plugin's, as any Remove leaves it.
        #expect(workspace.connectors.contains { $0.id == account.id })
        #expect(account.originPackageID == nil)
        let mirror = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path)))
        #expect(!(mirror.installedPlugins ?? []).contains { $0.id == package.id })
        // A bundled plugin is never forgotten.
        let bundled = try #require(PluginCatalog.builtInPackages.first)
        #expect(throws: CapabilityLibrary.RemovalError.builtInPackage(bundled.id)) {
            try CapabilityUninstaller(library: library).forgetMissing(pluginID: bundled.id, modelContext: context)
        }
    }
}

/// Round 22 review: a re-added plugin's Remove intent and an unreadable
/// entry's are settled only once what they owe is done.
@Suite("Remove intents for re-added and unreadable plugins")
@MainActor
struct PluginRound22ReviewTests {
    typealias Fixtures = PluginOperationsTests

    @Test("A Remove intent a re-added activation clears rewrites its mirrors first and keeps the new entry")
    func reAddedIntentRewritesMirrorsFirst() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        try journal.begin(package.id, affecting: [env.workspace.id])

        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal) { _ in false }
        #expect(try journal.pending() == [package.id])
        var rewritten: [UUID] = []
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal) {
            rewritten.append($0.id)
            return true
        }
        #expect(rewritten == [env.workspace.id])
        #expect(try journal.pending().isEmpty)
        #expect(env.library.installedPackage(id: package.id) != nil)
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace) != nil)
    }

    @Test("An unreadable definition is preserved until quarantine can be prepared, then removed recoverably")
    func unreadableEntryIsQuarantined() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let original = Data("not a package".utf8)
        try original.write(to: env.library.packageURL(for: package.id))
        try Data().write(to: env.library.quarantineDirectory)
        #expect(throws: (any Error).self) {
            try CapabilityUninstaller(library: env.library).forgetMissing(pluginID: package.id, modelContext: env.context)
        }
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace) != nil)
        #expect(try Data(contentsOf: env.library.packageURL(for: package.id)) == original)
        try FileManager.default.removeItem(at: env.library.quarantineDirectory)
        try CapabilityUninstaller(library: env.library).forgetMissing(pluginID: package.id, modelContext: env.context)
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace) == nil)
        #expect(!env.library.holdsUnreadableEntry(id: package.id))
        let quarantined = try FileManager.default.contentsOfDirectory(at: env.library.quarantineDirectory, includingPropertiesForKeys: nil)
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: #require(quarantined.first)) == original)
    }

}

/// Round 21 review: every save that releases secrets writes its mirrors
/// first, a startup move keeps its Keychain copies until its undo is saved,
/// and credential keys compare in their stored spelling.
@Suite("Mirror-first Add, durable migration undo, canonical credential keys")
@MainActor
struct PluginRound21ReviewTests {
    typealias Fixtures = PluginOperationsTests

    @Test("Add again writes every mirror before it cleans what it released, and keeps the cleanup when it can't")
    func addWritesMirrorsBeforeCleaning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-add-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))]
        )
        Fixtures.Environment.retained.append(container)
        let context = container.mainContext
        let workspace = Workspace(name: "Ops", primaryPath: root.appendingPathComponent("workspace").path)
        context.insert(workspace)
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
        var v1 = Fixtures.package(version: "1.0.0")
        var second = v1.skills[0]
        second.id = "summary-agent"
        second.name = "Summary Agent"
        v1.skills.append(second)
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        try installer.install(v1, into: workspace, modelContext: context, announceCatalogMutation: false)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))
        let released = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:summary-agent")
        let outbox = try #require(PluginSecretCleanupOutbox(for: context))

        var v2 = v1
        v2.version = "2.0.0"
        v2.skills.removeLast()
        var rewritten: [UUID] = []
        var owedDuringRewrite = false
        try installer.enable(v2, in: workspace, modelContext: context, rewriteMirror: { written in
            rewritten.append(written.id)
            owedDuringRewrite = (try? outbox.pending())?.contains(released) ?? false
            return false
        })
        #expect(activation.recordedVersion == "2.0.0")
        #expect(rewritten == [workspace.id])
        #expect(owedDuringRewrite)
        #expect(try outbox.pending() == [released])
    }

    @Test("Disabling a legacy plugin writes the workspace's mirror before any cleanup")
    func legacyDisableWritesTheMirrorFirst() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        package.connectors = []
        // No activation: the legacy path that deletes workspace rows.
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace) == nil)
        var rewritten: [UUID] = []
        let result = CapabilityActivationDisabler().disable(
            package, in: env.workspace, capabilities: WorkspaceCapabilities(workspace: env.workspace),
            modelContext: env.context, availablePackages: [package],
            rewriteMirror: { rewritten.append($0.id); return true }
        )
        #expect(result.persisted)
        #expect(rewritten == [env.workspace.id])
    }

    @Test("A startup move whose undo can't be saved keeps its Keychain copies for the stored rows")
    func startupUndoKeepsKeychainUntilSaved() throws {
        let env = try Fixtures.Environment()
        func legacyRow() -> Connector {
            let row = Connector(name: "Tracker", serviceType: "tracker", baseURL: "https://tracker.example.com", authMethod: "bearer")
            row.originPackageID = "imported.tracker"
            row.originComponentID = "connector:tracker:tracker-api"
            row.configKeys = ["TRACKER_PROJECT"]
            row.configValues = ["ENG-1"]
            env.context.insert(row)
            row.workspace = env.workspace
            return row
        }
        for (undoSaves, keeps) in [(false, true), (true, false)] {
            let store = MockSecretStore()
            let row = legacyRow()
            var saves = [true, undoSaves]
            #expect(!StartupCredentialMigrationService.moveSettingsStoredAsCredentials(
                of: [row], mirroredBy: [env.workspace], modelContext: env.context,
                resolver: PluginConnectorFieldTrustTests.StubCreator.self, store: store,
                rewriteMirror: { _ in false }, save: { _ in saves.removeFirst() }
            ))
            #expect(row.configValue("TRACKER_PROJECT") == "ENG-1")
            #expect((PluginConnectorFieldTrustTests.held("TRACKER_PROJECT", of: row, in: store) == "ENG-1") == keeps)
        }
    }

    @Test("Credential keys compare in their stored spelling: runtime copy, Update, field trust, validation")
    func credentialKeysCompareCanonically() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        package.connectors[0].credentialHints = [.init(key: "tracker_token", hint: "Token")]
        try env.install(package)
        let account = try #require(env.workspace.connectors.first)
        // A saved credential is recorded under its canonical key.
        account.credentialKeys = ["TRACKER_TOKEN"]
        account.credentialValues = [""]
        let projection = PluginRuntimeProjection.project(
            workspace: env.workspace, packages: [package], connectorMode: .runtimeCopies, definitions: [package]
        )
        #expect(try #require(projection.connectors.first { $0.id == account.id }).credentialKeys == ["TRACKER_TOKEN"])

        // Update doesn't add the declared spelling beside it.
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        var copied: [PluginUpdateService.CopiedSecret] = []
        PluginUpdateService.syncOwnedAccounts(of: activation, to: package, copied: &copied)
        #expect(account.credentialKeys == ["TRACKER_TOKEN"])

        // A setting and a credential that differ only in case are one stored
        // credential, and the validator says so.
        var mixed = PluginConnectorFieldTrustTests.importedPackage()
        mixed.connectors[0].credentialHints = [.init(key: "TRACKER_PROJECT", hint: "Token")]
        mixed.connectors[0].configHints = [.init(key: "tracker_project", hint: "Project", isList: false)]
        #expect(PluginConnectorFieldTrust.asStored(mixed.connectors[0], in: mixed).credentialHints.map(\.key) == ["TRACKER_PROJECT"])
        #expect(CapabilityPackageValidator.validate(package: mixed, checkPrerequisites: false)
            .issues.contains { $0.title == "Credential keys differ only in case" })
    }
}

/// Skill secrets that record what a cleanup deletes.
private enum RecordingCleanup: SkillSecretPersisting {
    private struct State {
        var deleted: [String] = []
        var cleaned: [UUID] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) static var onClean: (() -> Void)?
    nonisolated(unsafe) static var pendingAtClean: [UUID] = []
    static var deleted: [String] { state.withLock(\.deleted) }
    static var cleaned: [UUID] { state.withLock(\.cleaned) }
    static func reset() {
        state.withLock { $0 = State() }
        onClean = nil
        pendingAtClean = []
    }

    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        state.withLock { $0.deleted.append(key) }
        return true
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { false }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool {
        onClean?()
        state.withLock { $0.cleaned.append(skillID); $0.deleted.append(skillID.uuidString) }
        return true
    }
}
