import Foundation
import os
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// A plugin secret setting's owner is durable before its Keychain value
/// (`PluginSecretSettingWriter`), and an automatic pass moves nothing for a
/// definition awaiting its review. Fixtures are `PluginOperationsTests`'s.
@Suite("Plugin secret settings and review-gated renames")
@MainActor
struct PluginSecretSettingWriterTests {
    typealias Fixtures = PluginOperationsTests

    /// The fixture plugin with one secret skill setting and, for Add, no
    /// connector (Add hands configured settings to skills only then).
    static func secretPackage(connectors: Bool = true) -> PluginPackage {
        var package = Fixtures.package(version: "1.0.0")
        package.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        package.skills[0].environmentValues = ["default-project", ""]
        if !connectors { package.connectors = [] }
        return package
    }

    /// An on-disk store, so the cleanup outbox and a relaunch's view exist.
    @MainActor
    struct DiskStore {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        let library: CapabilityLibrary

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-secret-writer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))]
            )
            Fixtures.Environment.retained.append(container)
            context = container.mainContext
            workspace = Workspace(name: "Ops", primaryPath: root.appendingPathComponent("workspace").path)
            context.insert(workspace)
            library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
        }

        /// The secret settings a relaunch would read for `pluginID`.
        func storedSecretKeys(of pluginID: String) throws -> [String] {
            let fresh = ModelContext(container)
            return try fresh.fetch(FetchDescriptor<PluginActivation>()).first { $0.pluginID == pluginID }?.secretSettingKeys ?? []
        }
    }

    @Test("The row's editor saves the secret's marker before the Keychain write, and takes it back when the write fails")
    func editorSavesTheMarkerBeforeTheWrite() throws {
        let store = try DiskStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let package = Self.secretPackage()
        try CapabilityInstaller(library: store.library, appVersion: SemanticVersion(1, 0, 0))
            .install(package, into: store.workspace, modelContext: store.context, announceCatalogMutation: false)
        let settingKey = PluginActivation.settingKey(componentID: "skill:report-agent", key: "API_TOKEN")

        // What a relaunch reads at the moment of the write: a quit there
        // leaves the marker and no value.
        RecordingSecrets.reset()
        RecordingSecrets.onSave = { RecordingSecrets.markerAtWrite = (try? store.storedSecretKeys(of: package.id)) ?? [] }
        try PluginOperations.setSetting(
            "API_TOKEN", to: "token", of: package.skills[0], pluginID: package.id, in: store.workspace,
            modelContext: store.context, secrets: RecordingSecrets.self
        )
        #expect(RecordingSecrets.markerAtWrite == [settingKey])
        #expect(RecordingSecrets.saved == ["API_TOKEN"])

        // In that state, Remove still cleans the namespace and an Update
        // that drops the key still releases it.
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: store.workspace))
        let namespace = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:report-agent")
        #expect(PluginRuntimeProjection.secretNamespaces(of: activation, package: package).contains(namespace))
        #expect(activation.secretSettingKeys == [settingKey])

        // A write the Keychain refuses takes the marker back, durably.
        WorkspaceCapabilityActivation.setSecretRecorded(false, forKey: settingKey, on: activation)
        try store.context.save()
        RecordingSecrets.reset()
        RecordingSecrets.refusesWrites = true
        #expect(throws: PluginOperations.OperationError.secretSaveFailed(key: "API_TOKEN")) {
            try PluginOperations.setSetting(
                "API_TOKEN", to: "token", of: package.skills[0], pluginID: package.id, in: store.workspace,
                modelContext: store.context, secrets: RecordingSecrets.self
            )
        }
        #expect(activation.secretSettingKeys.isEmpty)
        #expect(try store.storedSecretKeys(of: package.id).isEmpty)
    }

    @Test("Every secret edit writes the workspace's mirror before the Keychain, and writes nothing when it can't")
    func secretEditWritesTheMirrorFirst() throws {
        let env = try Fixtures.Environment()
        let package = Self.secretPackage()
        try env.install(package)
        var log: [String] = []
        RecordingSecrets.reset()
        RecordingSecrets.onSave = { log.append("keychain") }
        for value in ["first", "second"] {
            try PluginOperations.setSetting(
                "API_TOKEN", to: value, of: package.skills[0], pluginID: package.id, in: env.workspace,
                modelContext: env.context, secrets: RecordingSecrets.self, rewriteMirror: { _ in log.append("mirror"); return true }
            )
        }
        #expect(log == ["mirror", "keychain", "mirror", "keychain"])

        RecordingSecrets.reset()
        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.setSetting(
                "API_TOKEN", to: "third", of: package.skills[0], pluginID: package.id, in: env.workspace,
                modelContext: env.context, secrets: RecordingSecrets.self, rewriteMirror: { _ in false }
            )
        }
        #expect(RecordingSecrets.saved.isEmpty)
    }

    @Test("A marker that can't be saved writes nothing to the Keychain")
    func unsavedMarkerWritesNothing() throws {
        let env = try Fixtures.Environment()
        let package = Self.secretPackage()
        try env.install(package)
        RecordingSecrets.reset()
        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.setSetting(
                "API_TOKEN", to: "token", of: package.skills[0], pluginID: package.id, in: env.workspace, modelContext: env.context,
                secrets: RecordingSecrets.self, persist: { _, _ in throw CocoaError(.fileWriteUnknown) }
            )
        }
        #expect(RecordingSecrets.saved.isEmpty)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        #expect(activation.secretSettingKeys.isEmpty)
    }

    @Test("Add journals a secret setting before the Keychain write and settles it with its save; launch cleans one a quit stranded")
    func addJournalsSecretSettingsBeforeTheWrite() throws {
        let store = try DiskStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let package = Self.secretPackage(connectors: false)
        let outbox = try #require(PluginSecretCleanupOutbox(for: store.context))
        RecordingSecrets.reset()
        RecordingSecrets.onSave = { RecordingSecrets.journalAtWrite = (try? outbox.entries()) ?? [] }
        try CapabilityInstaller(library: store.library, appVersion: SemanticVersion(1, 0, 0), skillSecrets: RecordingSecrets.self)
            .install(package, into: store.workspace, modelContext: store.context, configInputs: ["API_TOKEN": "token"],
                     announceCatalogMutation: false)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: store.workspace))
        let namespace = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:report-agent")
        #expect(RecordingSecrets.journalAtWrite == ["\(namespace.uuidString)#API_TOKEN"])
        // Settled with the save: the activation records it now.
        #expect(try outbox.entries().isEmpty)
        #expect(try store.storedSecretKeys(of: package.id) == [PluginActivation.settingKey(componentID: "skill:report-agent", key: "API_TOKEN")])

        // A quit between the write and the save: the journal names a value
        // nothing records, and launch deletes it.
        let stranded = UUID()
        try outbox.journal([.init(key: "API_TOKEN", skillID: stranded)])
        RecordingSecrets.reset()
        PluginSecretCleanupOutbox.resumePending(
            modelContext: store.context, outbox: outbox, secrets: RecordingSecrets.self, rewriteMirror: { _ in true }
        )
        #expect(RecordingSecrets.deleted == ["API_TOKEN@\(stranded.uuidString)"])
        #expect(try outbox.entries().isEmpty)
    }

    @Test("An Add whose save fails takes back what it journaled")
    func failedAddForgetsItsJournal() throws {
        let store = try DiskStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let package = Self.secretPackage(connectors: false)
        let outbox = try #require(PluginSecretCleanupOutbox(for: store.context))
        RecordingSecrets.reset()
        let installer = CapabilityInstaller(library: store.library, appVersion: SemanticVersion(1, 0, 0), skillSecrets: RecordingSecrets.self)
        #expect(throws: (any Error).self) {
            try installer.enable(
                package, in: store.workspace, modelContext: store.context, configInputs: ["API_TOKEN": "token"],
                persist: { _, _ in false }
            )
        }
        #expect(RecordingSecrets.saved == ["API_TOKEN"])
        #expect(try outbox.entries().isEmpty)
    }

    /// An unapproved definition that declares `replaces` (a file import, a
    /// tampered digest): no pass moves settings, bindings or secrets to the
    /// IDs it names until an approval covers it.
    @Test("An unapproved definition's renames move nothing, at launch or on Update, until it is approved")
    func unapprovedRenamesMoveNothing() throws {
        let env = try Fixtures.Environment()
        let v1 = Self.secretPackage()
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)
        WorkspaceCapabilityActivation.setSecretRecorded(
            true, forKey: PluginActivation.settingKey(componentID: "skill:report-agent", key: "API_TOKEN"), on: activation
        )
        let account = try #require(env.workspace.connectors.first)
        let known = activation.knownComponentIDs

        var v2 = v1
        v2.version = "2.0.0"
        v2.skills[0].id = "summary-agent"
        v2.skills[0].name = "Summary Agent"
        v2.skills[0].replaces = ["report-agent"]
        v2.connectors[0].id = "tracker"
        v2.connectors[0].replaces = ["connector:tracker:tracker-api"]
        try env.library.install(v2, sourceMetadata: .builtIn())
        let packages = env.library.installedPackages()

        for mode in [PluginUpdateService.Mode.automatic, .release] {
            RecordingSecrets.reset()
            try PluginUpdateService.reconcileAll(
                modelContext: env.context, packages: packages, mode: mode, secrets: RecordingSecrets.self, approvalRecords: []
            )
            #expect(activation.awaitingUpdate)
            #expect(activation.recordedVersion == "1.0.0")
            #expect(activation.knownComponentIDs == known)
            #expect(activation.configuration(forComponent: "skill:report-agent") == ["PROJECT": "alpha"])
            #expect(activation.configuration(forComponent: "skill:summary-agent").isEmpty)
            #expect(activation.accounts(forComponent: "connector:tracker:tracker-api").map(\.id) == [account.id])
            #expect(RecordingSecrets.saved.isEmpty && RecordingSecrets.loaded.isEmpty)
        }

        try PluginUpdateService.reconcileAll(
            modelContext: env.context, packages: packages, mode: .release, secrets: RecordingSecrets.self,
            approvalRecords: Fixtures.approvals(packages)
        )
        #expect(!activation.awaitingUpdate)
        #expect(activation.configuration(forComponent: "skill:summary-agent") == ["PROJECT": "alpha"])
        #expect(activation.accounts(forComponent: "connector:tracker:tracker").map(\.id) == [account.id])
        #expect(RecordingSecrets.loaded.contains("API_TOKEN"))
    }
}

/// Skill secrets that record what they were asked, and can refuse writes.
private enum RecordingSecrets: SkillSecretPersisting {
    private struct State {
        var saved: [String] = []
        var loaded: [String] = []
        var deleted: [String] = []
        var refusesWrites = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) static var onSave: (() -> Void)?
    nonisolated(unsafe) static var markerAtWrite: [String] = []
    nonisolated(unsafe) static var journalAtWrite: [String] = []

    static var saved: [String] { state.withLock(\.saved) }
    static var loaded: [String] { state.withLock(\.loaded) }
    static var deleted: [String] { state.withLock(\.deleted) }
    static var refusesWrites: Bool {
        get { state.withLock(\.refusesWrites) }
        set { state.withLock { $0.refusesWrites = newValue } }
    }

    static func reset() {
        state.withLock { $0 = State() }
        onSave = nil
        markerAtWrite = []
        journalAtWrite = []
    }

    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        state.withLock { $0.loaded.append(key) }
        return nil
    }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        onSave?()
        return state.withLock { state in
            guard !state.refusesWrites else { return false }
            state.saved.append(key)
            return true
        }
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        state.withLock { $0.deleted.append("\(key)@\(skillID.uuidString)") }
        return true
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { false }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { true }
}
