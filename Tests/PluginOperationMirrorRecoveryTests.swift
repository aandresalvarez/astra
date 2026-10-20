import Foundation
import os
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin operation mirror recovery", .serialized)
struct PluginOperationMirrorRecoveryTests {
    @Test("A plain setting reports a failed recovery copy after its domain save")
    func mirrorFailureIsNotReportedAsFullSuccess() throws {
        let env = try PluginOperationsTests.Environment()
        env.workspace.primaryPath = env.root.appendingPathComponent("Workspace").path
        try FileManager.default.createDirectory(atPath: env.workspace.primaryPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: env.root) }
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let directory = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath))
            .deletingLastPathComponent()
        let backup = directory.deletingLastPathComponent().appendingPathComponent("mirror-backup-\(UUID())")
        let hadDirectory = FileManager.default.fileExists(atPath: directory.path)
        if hadDirectory { try FileManager.default.moveItem(at: directory, to: backup) }
        defer {
            try? FileManager.default.removeItem(at: directory)
            if hadDirectory { try? FileManager.default.moveItem(at: backup, to: directory) }
        }
        try Data("Not a directory".utf8).write(to: directory)
        #expect(!WorkspaceConfigManager.exportMirrorNow(workspace: env.workspace, modelContext: env.context))
        let changes = OSAllocatedUnfairLock<[UUID?]>(initialState: [])
        let observation = NotificationCenter.default.addObserver(forName: .capabilityCatalogPersistenceChanged,
            object: nil, queue: nil) { notification in
                guard let change = notification.object as? CapabilityCatalogPersistenceChange else { return }
                changes.withLock { $0.append(change.workspaceID) }
            }
        defer { NotificationCenter.default.removeObserver(observation) }
        var reportedFailure = false
        do {
            try PluginOperations.setSetting("PROJECT", to: "saved-change", of: package.skills[0],
                pluginID: package.id, in: env.workspace, modelContext: env.context)
        } catch { reportedFailure = true }
        #expect(reportedFailure)
        #expect(changes.withLock { $0 } == [env.workspace.id])
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        #expect(activation.configuration(forComponent: "skill:report-agent")["PROJECT"] == "saved-change")
        let saved = ModelContext(env.container)
        let stored = try #require(try saved.fetch(FetchDescriptor<PluginActivation>()).first { $0.pluginID == package.id })
        #expect(stored.configuration(forComponent: "skill:report-agent")["PROJECT"] == "saved-change")
    }

    @Test("A saved setting reopens with its pending receipt and regenerates the real mirror")
    func savedSettingRecoversAfterReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-setting-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("test.store")
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: store)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Reopen", primaryPath: folder.path)
        context.insert(workspace)
        let package = PluginOperationsTests.package(version: "1.0.0")
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities"))
        try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            .install(package, into: workspace, modelContext: context, announceCatalogMutation: false)
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: folder.path))
        if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
        try Data("Blocks recovery folder".utf8).write(to: support)
        var pendingID: UUID?
        do {
            try PluginOperations.setSetting("PROJECT", to: "recovered-setting", of: package.skills[0],
                pluginID: package.id, in: workspace, modelContext: context)
            Issue.record("A failed recovery copy was reported as complete")
        } catch let problem as PluginOperationProblem {
            if case .savedRecoveryPending(let id) = problem { pendingID = id }
            else { Issue.record("A saved setting was classified as an uncertain or deferred credential write") }
        }
        let operationID = try #require(pendingID)
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: store)])
        let saved = try #require(try PluginOperationCommit.read(operationID, container: reopened))
        #expect(saved.completedAt == nil)
        try FileManager.default.removeItem(at: support)
        let retry = PluginOperationRecovery.resumePending(modelContext: reopened.mainContext)
        #expect(retry.completed == 1 && retry.deferred == 0)
        #expect(try PluginOperationCommit.read(operationID, container: reopened)?.completedAt != nil)
        let config = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let installed = try #require(json["installedPlugins"] as? [[String: Any]])
        let settings = try #require(installed.first { $0["id"] as? String == package.id }?["settings"] as? [String: String])
        #expect(settings["skill:report-agent#PROJECT"] == "recovered-setting")
    }


    @Test("A completed secret edit publishes once, after the credential value is written")
    func credentialPublicationFollowsTheValueWrite() throws {
        let env = try PluginOperationsTests.Environment()
        var package = PluginOperationsTests.package(version: "1.0.0")
        package.skills[0].environmentKeys.append("API_TOKEN")
        package.skills[0].environmentValues.append("")
        try env.install(package)
        PublishingSecrets.reset()
        let workspaceID = env.workspace.id
        let notifications = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let observation = NotificationCenter.default.addObserver(forName: .capabilityCatalogPersistenceChanged,
            object: nil, queue: nil) { notification in
                guard let change = notification.object as? CapabilityCatalogPersistenceChange,
                      change.workspaceID == workspaceID else { return }
                notifications.withLock { $0.append(PublishingSecrets.wroteValue) }
            }
        defer { NotificationCenter.default.removeObserver(observation) }
        try PluginOperations.setSetting("API_TOKEN", to: "test-only", of: package.skills[0],
            pluginID: package.id, in: env.workspace, modelContext: env.context, secrets: PublishingSecrets.self)
        #expect(notifications.withLock { $0 } == [true])
    }

}


private enum PublishingSecrets: SkillSecretPersisting {
    private static let written = OSAllocatedUnfairLock(initialState: false)
    static var wroteValue: Bool { written.withLock { $0 } }
    static func reset() { written.withLock { $0 = false } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        written.withLock { $0 = true }; return true
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { wroteValue }
    static func deleteAllSecrets(skillID: UUID) {}
}
