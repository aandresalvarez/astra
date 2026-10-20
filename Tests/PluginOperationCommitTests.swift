import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRACore
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin operation commit proof", .serialized)
struct PluginOperationCommitTests {
    enum Failure: Error { case save, read, expectedCommitted }

    @Test("A callback that does not save cannot authorize completion")
    func successfulCallbackIsNotCommitProof() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        fixture.workspace.name = "Unsaved"
        let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: ["example"],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context, persist: { _ in })
        guard case .notCommitted = outcome else { Issue.record("Missing durable receipt was treated as committed"); return }
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<PluginOperationReceipt>()).isEmpty)
        fixture.context.rollback()
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<Workspace>()).first?.name == "Original")
    }

    @Test("The receipt and domain change land in the same save", arguments: [false, true])
    func domainAndReceiptShareCommit(onDisk: Bool) throws {
        let fixture = try Fixture(onDisk: onDisk)
        defer { fixture.removeFiles() }
        fixture.workspace.name = "Saved"
        let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: ["example", "example"],
            workspaceIDs: [fixture.workspace.id, fixture.workspace.id], modelContext: fixture.context)
        let snapshot = try committed(outcome)
        #expect(snapshot.pluginIDs == ["example"])
        #expect(snapshot.workspaceIDs == [fixture.workspace.id])
        #expect(snapshot.completedAt == nil)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<Workspace>()).first?.name == "Saved")
        #expect(try PluginOperationCommit.read(snapshot.id, container: fixture.container) == snapshot)
    }

    @Test("An exception after a real save cannot authorize rolling the domain state back")
    func saveThenThrowIsCommitted() throws {
        let fixture = try Fixture(onDisk: true)
        defer { fixture.removeFiles() }
        fixture.workspace.name = "Saved before exception"
        let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: [], workspaceIDs: [fixture.workspace.id],
            modelContext: fixture.context, persist: { context in try context.save(); throw Failure.save })
        guard case .committed(let snapshot, let reportedFailure) = outcome else {
            Issue.record("A durable commit was reported as safe to roll back"); return
        }
        #expect(reportedFailure)
        #expect(snapshot.completedAt == nil)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<Workspace>()).first?.name == "Saved before exception")
    }

    @Test("An unreadable commit proof is indeterminate, never an unsaved operation")
    func unknownCommitDoesNotAuthorizeRollback() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let id = UUID()
        let outcome = PluginOperationCommit.save(id: id, kind: .add, pluginIDs: [], workspaceIDs: [],
            modelContext: fixture.context, readSaved: { _, _ in throw Failure.read })
        guard case .indeterminate(let uncertainID, _) = outcome else {
            Issue.record("An unavailable proof was treated as a known save result"); return
        }
        #expect(uncertainID == id)
        #expect(try PluginOperationCommit.read(id, container: fixture.container) != nil)
    }

    @Test("A failed save leaves no receipt in the durable store")
    func failedSaveHasNoCommitProof() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let id = UUID()
        let outcome = PluginOperationCommit.save(id: id, kind: .remove, pluginIDs: ["example"], workspaceIDs: [],
            modelContext: fixture.context, persist: { _ in throw Failure.save })
        guard case .notCommitted = outcome else { Issue.record("A failed save acquired commit proof"); return }
        #expect(try PluginOperationCommit.read(id, container: fixture.container) == nil)
    }

    @Test("A second operation cannot reuse a receipt's identity")
    func duplicateIDCannotOverwriteProof() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let first = try committed(PluginOperationCommit.save(kind: .add, pluginIDs: ["first"],
            workspaceIDs: [], modelContext: fixture.context))
        var savedAgain = false
        let second = PluginOperationCommit.save(id: first.id, kind: .remove, pluginIDs: ["second"],
            workspaceIDs: [], modelContext: fixture.context, persist: { _ in savedAgain = true })
        guard case .notCommitted = second else { Issue.record("An existing receipt was overwritten"); return }
        #expect(!savedAgain)
        #expect(try PluginOperationCommit.read(first.id, container: fixture.container) == first)
    }

    @Test("Mirror retry survives reopening without any credential-cleanup entries")
    func mirrorDebtSurvivesReopening() throws {
        let fixture = try Fixture(onDisk: true)
        defer { fixture.removeFiles() }
        let snapshot = try committed(PluginOperationCommit.save(kind: .configure, pluginIDs: [],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context))
        let failed = PluginOperationRecovery.resumePending(modelContext: fixture.context, export: { _, _ in false })
        #expect(failed.completed == 0 && failed.deferred == 1)
        #expect(try PluginOperationCommit.read(snapshot.id, container: fixture.container)?.completedAt == nil)
        let reopened = try fixture.reopen()
        var exported: [UUID] = []
        let retry = PluginOperationRecovery.resumePending(modelContext: reopened.mainContext,
            export: { workspace, _ in exported.append(workspace.id); return true })
        #expect(retry.completed == 1 && retry.deferred == 0)
        #expect(exported == [fixture.workspace.id])
        #expect(try PluginOperationCommit.read(snapshot.id, container: reopened)?.completedAt != nil)
        let again = PluginOperationRecovery.resumePending(modelContext: reopened.mainContext,
            export: { _, _ in Issue.record("Completed work was exported again"); return true })
        #expect(again.completed == 0 && again.deferred == 0)
    }

    @Test("Recovery does not save unrelated unsaved edits from its caller")
    func retryUsesOnlyCommittedDomainState() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        _ = try committed(PluginOperationCommit.save(kind: .configure, pluginIDs: [],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context))
        fixture.workspace.name = "Unsaved editor text"
        var exportedNames: [String] = []
        let result = PluginOperationRecovery.resumePending(modelContext: fixture.context,
            export: { workspace, _ in exportedNames.append(workspace.name); return true })
        #expect(result.completed == 1)
        #expect(exportedNames == ["Original"])
        #expect(fixture.workspace.name == "Unsaved editor text")
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<Workspace>()).first?.name == "Original")
    }

    @Test("A prepared file operation waits for its library and approval recovery")
    func fileOperationNeedsRecoveryAdmission() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let snapshot = try committed(PluginOperationCommit.save(kind: .approval, pluginIDs: ["example"],
            workspaceIDs: [fixture.workspace.id], manifestDigest: String(repeating: "a", count: 64), modelContext: fixture.context))
        var exports = 0
        let held = PluginOperationRecovery.resumePending(modelContext: fixture.context,
            export: { _, _ in exports += 1; return true })
        #expect(held.deferred == 1 && exports == 0)
        let admitted = PluginOperationRecovery.resumePending(modelContext: fixture.context,
            allowsFileOperation: { $0.id == snapshot.id && $0.manifestDigest == snapshot.manifestDigest },
            export: { _, _ in exports += 1; return true })
        #expect(admitted.completed == 1 && exports == 1)
    }

    @Test("A completion save that fails or does nothing keeps the durable retry", arguments: [false, true])
    func completionFailureKeepsDebt(throwsError: Bool) throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let snapshot = try committed(PluginOperationCommit.save(kind: .configure, pluginIDs: [],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context))
        let result = PluginOperationRecovery.resumePending(modelContext: fixture.context, export: { _, _ in true },
            persistCompletion: { _ in if throwsError { throw Failure.save } })
        #expect(result.deferred == 1 && result.completed == 0)
        #expect(try PluginOperationCommit.read(snapshot.id, container: fixture.container)?.completedAt == nil)
    }

    @Test("A completion saved before an adapter throws remains completed")
    func completionSavedBeforeException() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let snapshot = try committed(PluginOperationCommit.save(kind: .configure, pluginIDs: [],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context))
        let result = PluginOperationRecovery.resumePending(modelContext: fixture.context, export: { _, _ in true },
            persistCompletion: { context in try context.save(); throw Failure.save })
        #expect(result.completed == 1 && result.deferred == 0)
        #expect(try PluginOperationCommit.read(snapshot.id, container: fixture.container)?.completedAt != nil)
    }

    @Test("A pending operation keeps account cleanup owed until its mirror is confirmed")
    func pendingOperationHoldsCredentialCleanup() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let snapshot = try committed(PluginOperationCommit.save(kind: .configure, pluginIDs: [],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context))
        let account = Connector(name: "Deleted", serviceType: "rest_api", baseURL: "https://receipt.example.test")
        var attempts = 0
        let perform: ([ConnectorKeychainCleanup], ConnectorCredentialCleanup.Ownership) -> Bool = { _, _ in
            attempts += 1; return true
        }
        #expect(!ConnectorCredentialCleanup.run([account.keychainCleanup], modelContext: fixture.context, retained: [], perform: perform))
        #expect(attempts == 0)
        _ = PluginOperationRecovery.resumePending(modelContext: fixture.context, only: snapshot.id, export: { _, _ in true })
        #expect(ConnectorCredentialCleanup.run([account.keychainCleanup], modelContext: fixture.context, retained: [], perform: perform))
        #expect(attempts == 1)
    }

    @Test("Workspace cleanup waits for operation receipts before removing external state")
    func workspaceCleanupWaitsForRecovery() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let snapshot = try committed(PluginOperationCommit.save(kind: .configure, pluginIDs: [],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context))
        let record = WorkspaceDeletionCleanupRecord(workspaceID: UUID(),
            primaryPath: fixture.root.appendingPathComponent("deleted").path, connectors: [], skills: [])
        #expect(!WorkspaceDeletionCleanupService.settle(record, modelContext: fixture.context))
        _ = PluginOperationRecovery.resumePending(modelContext: fixture.context, only: snapshot.id, export: { _, _ in true })
        #expect(WorkspaceDeletionCleanupService.settle(record, modelContext: fixture.context))
    }

    @Test("Workspace cleanup preserves frozen task accounts and skills until cancellation")
    func workspaceCleanupKeepsPendingTaskOwners() throws {
        let fixture = try Fixture(onDisk: false)
        defer { fixture.removeFiles() }
        let activation = PluginActivation(pluginID: "queued-receipt")
        fixture.context.insert(activation)
        activation.workspace = fixture.workspace
        WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:agent#API_TOKEN", on: activation)
        let namespace = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:agent")
        let account = Connector(name: "Queued", serviceType: "rest_api", baseURL: "https://queued.example.test")
        fixture.context.insert(account)
        account.workspace = fixture.workspace
        WorkspaceCapabilityActivation.bind(account, toComponent: "connector:rest_api:account", of: activation)
        let task = AgentTask(title: "Queued", goal: "Use accepted context", workspace: fixture.workspace)
        fixture.context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
        fixture.context.insert(request)
        try fixture.context.save()
        let accountID = account.id
        let record = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: fixture.root.appendingPathComponent("deleted").path,
            connectors: [account.keychainCleanup], skills: [.init(skillID: namespace)])
        fixture.context.delete(activation)
        fixture.context.delete(account)
        try fixture.context.save()
        var accounts: [UUID] = [], skills: [UUID] = []
        func settle() -> Bool {
            WorkspaceDeletionCleanupService.settle(record, modelContext: fixture.context,
                cleanConnectors: { rows, _ in accounts += rows.map(\.connectorID); return true },
                cleanSkill: { skills.append($0.skillID); return true })
        }
        #expect(!settle())
        #expect(accounts.isEmpty && skills.isEmpty)
        request.state = .cancelled
        try fixture.context.save()
        #expect(settle())
        #expect(accounts == [accountID] && skills == [namespace])
    }

    @Test("An unavailable mirror target is a durable failure, not a completed export")
    func realMirrorTargetFailureRemainsPending() throws {
        let fixture = try Fixture(onDisk: true)
        defer { fixture.removeFiles() }
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: fixture.workspace.primaryPath))
        try Data("Blocks support directory".utf8).write(to: support)
        let snapshot = try committed(PluginOperationCommit.save(kind: .configure, pluginIDs: [],
            workspaceIDs: [fixture.workspace.id], modelContext: fixture.context))
        let failed = PluginOperationRecovery.resumePending(modelContext: fixture.context)
        #expect(failed.completed == 0 && failed.deferred == 1)
        #expect(try PluginOperationCommit.read(snapshot.id, container: fixture.container)?.completedAt == nil)
        try FileManager.default.removeItem(at: support)
        let retry = PluginOperationRecovery.resumePending(modelContext: fixture.context)
        #expect(retry.completed == 1 && retry.deferred == 0)
        #expect(FileManager.default.fileExists(atPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.workspace.primaryPath)))
    }

    private func committed(_ outcome: PluginOperationCommit.Outcome) throws -> PluginOperationCommit.Snapshot {
        guard case .committed(let snapshot, let reportedFailure) = outcome, !reportedFailure else { throw Failure.expectedCommitted }
        return snapshot
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        init(onDisk: Bool) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-plugin-receipt-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [onDisk ? ModelConfiguration(url: root.appendingPathComponent("test.store"))
                    : ModelConfiguration(isStoredInMemoryOnly: true)])
            context = container.mainContext
            context.autosaveEnabled = false
            workspace = Workspace(name: "Original", primaryPath: root.path)
            context.insert(workspace)
            try context.save()
        }
        func reopen() throws -> ModelContainer {
            try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: root.appendingPathComponent("test.store"))])
        }
        func removeFiles() { try? FileManager.default.removeItem(at: root) }
    }
}
