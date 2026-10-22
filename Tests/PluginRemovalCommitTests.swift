import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin Remove commit proof", .serialized)
struct PluginRemovalCommitTests {
    @Test("Remove refuses unrelated pending edits before recovery, save or rollback", arguments: [false, true])
    func removePreservesUnrelatedPendingEdits(saveSucceeds: Bool) throws {
        let env = try Fixture(activated: true)
        defer { env.disk.removeFiles() }
        let originalName = env.workspace.name
        let original = WorkspaceCapabilityActivation.snapshot(env.workspace)
        env.workspace.name = "Unrelated unsaved editor work"
        var called = false
        do {
            _ = try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context,
                persist: { _, context in
                    called = true
                    if saveSucceeds { try? context.save() }
                    return saveSucceeds
                })
            Issue.record("Remove accepted another workflow's pending edit")
        } catch { #expect(error as? PluginOperations.OperationError == .pendingEdits) }
        #expect(!called)
        let hasPendingEdits = env.context.hasChanges
        #expect(hasPendingEdits)
        #expect(env.workspace.name == "Unrelated unsaved editor work")
        #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == original)
        let fresh = ModelContext(env.disk.container)
        #expect(try fresh.fetch(FetchDescriptor<Workspace>()).first?.name == originalName)
        #expect(try fresh.fetch(FetchDescriptor<PluginOperationReceipt>()).isEmpty)
        #expect(env.library.installedPackage(id: env.package.id) != nil)
        #expect(try env.journal.pendingIDs().isEmpty)
    }

    @Test("Remove without activations cannot delete files on an unpersisted success callback")
    func noActivationNeedsActualSave() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        #expect(throws: CapabilityUninstaller.UninstallError.self) {
            try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context, persist: { _, _ in true })
        }
        #expect(env.library.installedPackage(id: env.package.id) != nil)
        #expect(try ModelContext(env.disk.container).fetch(FetchDescriptor<PluginOperationReceipt>()).isEmpty)
    }

    @Test("A save reported as failed after commit retains the deletion and durable forward recovery")
    func savedThenFailedIsNotRolledBack() throws {
        let env = try Fixture(activated: true)
        defer { env.disk.removeFiles() }
        var operationID: UUID?
        do {
            _ = try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context, persist: { _, context in
                do { try context.save() } catch { Issue.record("Fixture save failed: \(error)") }
                return false
            })
            Issue.record("Committed work whose save reported failure must remain explicitly pending")
        } catch let problem as PluginOperationProblem {
            guard case .savedRecoveryPending(let id) = problem else { throw problem }
            operationID = id
        }
        let id = try #require(operationID)
        #expect(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace) == nil)
        #expect(env.library.installedPackage(id: env.package.id) != nil)
        let reopened = try env.disk.reopen()
        #expect(try PluginOperationCommit.read(id, container: reopened)?.kind == .remove)
        let result = PluginFileOperationRecovery(journal: env.journal).resumePending(modelContext: reopened.mainContext)
        #expect(result.completed == 1 && result.deferred == 0)
        #expect(env.library.installedPackage(id: env.package.id) == nil)
        #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
    }

    @Test("A library deletion refused after the save is reported and retried from the same receipt")
    func refusedFileDeletionSurvivesReopen() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        var operationID: UUID?
        do {
            _ = try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context, persist: { _, context in
                do { try context.save() } catch { return false }
                env.files.refusesDeletion = true
                return true
            })
            Issue.record("A refused file deletion must not be acknowledged as fully completed")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        #expect(env.library.installedPackage(id: env.package.id) != nil)
        #expect(try env.journal.pendingIDs() == [id])
        env.files.refusesDeletion = false
        let reopened = try env.disk.reopen()
        let result = PluginFileOperationRecovery(journal: env.journal).resumePending(modelContext: reopened.mainContext)
        #expect(result.completed == 1 && result.deferred == 0)
        #expect(env.library.installedPackage(id: env.package.id) == nil)
    }

    @Test("Even a Remove with no secret cleanup retains failed mirror work")
    func mirrorDebtExistsWithoutSecrets() throws {
        let env = try Fixture(activated: true)
        defer { env.disk.removeFiles() }
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Blocked mirror folder".utf8).write(to: support)
        var operationID: UUID?
        do {
            _ = try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context)
            Issue.record("A failed recovery mirror must remain explicitly pending")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        #expect(!PluginOperationRecovery.permitsCredentialCleanup(modelContext: env.context))
        #expect(try env.journal.pendingIDs() == [id])
        try FileManager.default.removeItem(at: support)
        let reopened = try env.disk.reopen()
        let result = PluginFileOperationRecovery(journal: env.journal).resumePending(modelContext: reopened.mainContext)
        #expect(result.completed == 1 && result.deferred == 0)
        let config = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath)))
        #expect(!(config.installedPlugins ?? []).contains { $0.id == env.package.id })
        #expect(PluginOperationRecovery.permitsCredentialCleanup(modelContext: reopened.mainContext))
    }

    @Test("Completing an older Remove retains its mirror scope even when no activation remains", arguments: [false, true])
    func legacyIntentScopeIsNotLost(bareIDs: Bool) throws {
        let env = try Fixture(activated: true)
        defer { env.disk.removeFiles() }
        #expect(WorkspaceConfigManager.exportMirrorNow(workspace: env.workspace, modelContext: env.context))
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0 = WorkspaceCapabilityActivationState() }
        try env.context.save()
        let legacy = PluginRemoveJournal(fileURL: env.disk.root.appendingPathComponent("LegacyRemovals.json"))
        if bareIDs { try JSONEncoder().encode([env.package.id]).write(to: legacy.fileURL) }
        else { try legacy.begin(env.package.id, affecting: [env.workspace.id]) }
        _ = try CapabilityUninstaller(library: env.library).remove(env.package, modelContext: env.context, removeJournal: legacy)
        #expect(try legacy.pending().isEmpty)
        let config = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath)))
        #expect(!(config.installedPlugins ?? []).contains { $0.id == env.package.id })
        let receipts = try ModelContext(env.disk.container).fetch(FetchDescriptor<PluginOperationReceipt>())
        let receipt = try #require(receipts.first { $0.kindRawValue == PluginOperationReceipt.Kind.remove.rawValue })
        #expect(receipt.workspaceIDStrings == [env.workspace.id.uuidString])
    }

    @MainActor
    struct Fixture {
        let disk: PluginFileOperationRecoveryTests.Fixture
        let package = PluginOperationsTests.package(version: "1.0.0")
        let files: RefusingRemovalFiles
        let library: CapabilityLibrary
        let workspace: Workspace
        var context: ModelContext { disk.context }
        var journal: PluginFileOperationJournal { .init(library: library, approvals: CapabilityApprovalStore()) }
        init(activated: Bool = false) throws {
            disk = try PluginFileOperationRecoveryTests.Fixture()
            files = RefusingRemovalFiles()
            library = CapabilityLibrary(directory: disk.library.directory, fileManager: files)
            files.target = library.packageURL(for: package.id)
            try library.install(package, sourceMetadata: .localLibrary())
            let folder = disk.root.appendingPathComponent("Workspace")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            workspace = Workspace(name: "Remove", primaryPath: folder.path)
            disk.context.insert(workspace)
            if activated {
                WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs.append(package.id) }
                WorkspaceCapabilityActivation.recordAccepted(pluginID: package.id, version: package.version,
                    digest: PluginDefinitionDigest.content(of: package), in: workspace)
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
                WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: package), on: activation)
            }
            try disk.context.save()
        }
    }
}

final class RefusingRemovalFiles: FileManager {
    var target: URL?
    var refusesDeletion = false
    override func removeItem(at url: URL) throws {
        if refusesDeletion, url.standardizedFileURL == target?.standardizedFileURL { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
