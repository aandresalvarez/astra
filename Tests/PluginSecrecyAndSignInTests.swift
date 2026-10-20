import Foundation
import os
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Rename copies journaled before they are written, settings whose secrecy
/// changed, and accounts whose sign-in method was withdrawn. Fixtures are
/// `PluginOperationsTests`'s.
@Suite("Journaled rename copies, secrecy changes, withdrawn sign-in methods")
@MainActor
struct PluginSecrecyAndSignInTests {
    typealias Fixtures = PluginOperationsTests

    @Test("A rename's secret copy is journaled before it is written and settled once the activation is saved")
    func renameCopiesAreJournaledFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-rename-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))]
        )
        Fixtures.Environment.retained.append(container)
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Ops", primaryPath: root.appendingPathComponent("workspace").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        context.insert(workspace)
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
        var v1 = Fixtures.package(version: "1.0.0")
        v1.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        v1.skills[0].environmentValues = ["default-project", ""]
        try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            .install(v1, into: workspace, modelContext: context, announceCatalogMutation: false)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))
        WorkspaceCapabilityActivation.setSecretRecorded(
            true, forKey: PluginActivation.settingKey(componentID: "skill:report-agent", key: "API_TOKEN"), on: activation
        )
        try context.save()
        let outbox = try #require(PluginSecretCleanupOutbox(for: context))
        let newID = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:summary-agent")

        var v2 = v1
        v2.version = "2.0.0"
        v2.skills[0].id = "summary-agent"
        v2.skills[0].name = "Summary Agent"
        v2.skills[0].replaces = ["report-agent"]
        RenameSecrets.reset(holding: PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:report-agent"))
        RenameSecrets.onSave = { RenameSecrets.journalAtWrite = (try? outbox.pendingKeys()) ?? [] }
        try PluginUpdateService.reconcileAll(
            modelContext: context, packages: [v2], mode: .release, secrets: RenameSecrets.self, approvalRecords: []
        )
        #expect(RenameSecrets.journalAtWrite == [.init(key: "API_TOKEN", skillID: newID)])
        #expect(RenameSecrets.saved == ["API_TOKEN@\(newID.uuidString)"])
        #expect(activation.secretSettingKeys.contains(PluginActivation.settingKey(componentID: "skill:summary-agent", key: "API_TOKEN")))
        // Settled with the save: the activation owns the copy.
        #expect(try outbox.pendingKeys().isEmpty)
    }

    @Test("Update moves a plain value kept for a secret setting into the Keychain; a plain replacement moves to a separate credential generation")
    func secrecyChangesMoveOrClearValues() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        v1.skills[0].environmentValues = ["default-project", ""]
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        let skillID = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:report-agent")
        // A value an older build kept plain for a setting now classed secret.
        let tokenKey = PluginActivation.settingKey(componentID: "skill:report-agent", key: "API_TOKEN")
        WorkspaceCapabilityActivation.setConfigValue("tok-plain", forKey: tokenKey, on: activation)
        try env.context.save()

        RenameSecrets.reset(holding: UUID())
        var v2 = v1
        v2.version = "2.0.0"
        try PluginUpdateService.reconcileAll(
            modelContext: env.context, packages: [v2], mode: .release, secrets: RenameSecrets.self, approvalRecords: []
        )
        #expect(RenameSecrets.saved == ["API_TOKEN@\(skillID.uuidString)"])
        #expect(activation.configuration(forComponent: "skill:report-agent")["API_TOKEN"] == nil)
        #expect(activation.secretSettingKeys.contains(tokenKey))
        let mirror = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        #expect(!(String(data: try JSONEncoder().encode(mirror), encoding: .utf8) ?? "").contains("tok-plain"))

        // The reverse: a secret kept under a key now plain stays unread
        // until the person enters the setting, which clears it.
        let projectKey = PluginActivation.settingKey(componentID: "skill:report-agent", key: "PROJECT")
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: projectKey, on: activation)
        RenameSecrets.reset(holding: UUID())
        try PluginOperations.setSetting(
            "PROJECT", to: "alpha", of: v2.skills[0], pluginID: v2.id, in: env.workspace, modelContext: env.context,
            secrets: RenameSecrets.self
        )
        #expect(RenameSecrets.deleted.isEmpty)
        #expect(PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:report-agent") != skillID)
        #expect(!activation.secretSettingKeys.contains(projectKey))
        #expect(activation.configuration(forComponent: "skill:report-agent")["PROJECT"] == "alpha")
    }

    @Test("An account whose sign-in method was withdrawn stays bound but runs nothing until it reconnects")
    func withdrawnSignInMethodIsNotProjected() throws {
        let env = try Fixtures.Environment()
        let v1 = Fixtures.package(version: "1.0.0")
        try env.install(v1)
        let account = try #require(env.workspace.connectors.first)
        var v2 = Fixtures.package(version: "2.0.0")
        v2.connectors[0].authMethod = "oauth"
        try env.importUpdate(v2)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        let componentID = CapabilityResourceOrigin.componentID(for: v2.connectors[0])
        #expect(activation.accounts(forComponent: componentID).map(\.id) == [account.id])
        func projected() -> [UUID] {
            PluginRuntimeProjection.project(workspace: env.workspace, packages: [v2], connectorMode: .runtimeCopies, definitions: [v2])
                .connectors.map(\.id)
        }
        #expect(!projected().contains(account.id))
        let state = CapabilityPackageState(package: v2, workspace: env.workspace, capabilities: WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: [v2]))
        #expect(state.readiness.level == .needsAttention)

        // Reconnected with the declared method, it runs again.
        account.authMethod = "oauth"
        #expect(projected().contains(account.id))
    }
}

/// Skill secrets holding one value in `source`'s namespace, recording writes and deletes.
private enum RenameSecrets: SkillSecretPersisting {
    private struct State {
        var source = UUID()
        var saved: [String] = []
        var deleted: [String] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) static var onSave: (() -> Void)?
    nonisolated(unsafe) static var journalAtWrite: [PluginUpdateService.StaleSecret] = []
    static var saved: [String] { state.withLock(\.saved) }
    static var deleted: [String] { state.withLock(\.deleted) }
    static func reset(holding source: UUID) {
        state.withLock { $0 = State(source: source) }
        onSave = nil
        journalAtWrite = []
    }

    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        state.withLock { $0.source == skillID ? "tok" : nil }
    }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        onSave?()
        state.withLock { $0.saved.append("\(key)@\(skillID.uuidString)") }
        return true
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        state.withLock { $0.deleted.append("\(key)@\(skillID.uuidString)") }
        return true
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { false }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { true }
}
