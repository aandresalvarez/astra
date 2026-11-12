import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// The explicit journal recovery has to be reachable from where the journal
/// blocks: an Add, or a new workspace, creates the first account, so there is
/// no account row to open and recover from. Synthetic stores and journals;
/// nothing here reads or writes a credential.
@MainActor
@Suite("Account credential journal recovery reachability", .serialized)
struct CredentialJournalRecoveryReachabilityTests {
    @Test("A store with no account can recover an unverifiable journal")
    func recoversWithoutAnAccount() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        #expect(try env.context.fetch(FetchDescriptor<Connector>()).isEmpty)
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeDriftedJournal(journal, context: env.context)
        let service = CapabilityCatalogActionService()
        #expect(service.credentialEditingNeedsRecovery(modelContext: env.context))
        expectWrongStore { _ = try journal.pending() }

        try service.recoverCredentialEditing(modelContext: env.context)

        #expect(try journal.pending().isEmpty)
        #expect(!service.credentialEditingNeedsRecovery(modelContext: env.context))
        // The unverifiable record is archived, never dropped.
        #expect(try recoveryArchives(journal).count == 1)
        #expect(!env.context.hasChanges)
    }

    @Test("Unsaved edits and an unfinished change in any workspace come first", arguments: [false, true])
    func recoveryHonorsMutationBoundaries(pendingEdit: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeDriftedJournal(journal, context: env.context)
        let before = try Data(contentsOf: journal.fileURL)
        if pendingEdit {
            env.workspace.name = "Unsaved synthetic edit"
        } else {
            // Scoped to one workspace: an account elsewhere would not see it,
            // and an action with no account to scope it must.
            let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: [], workspaceIDs: [env.workspace.id],
                modelContext: env.context)
            guard case .committed = outcome else { Issue.record("Fixture receipt did not commit"); return }
        }

        #expect(throws: (any Error).self) {
            try CapabilityCatalogActionService().recoverCredentialEditing(modelContext: env.context)
        }

        #expect(try Data(contentsOf: journal.fileURL) == before)
        #expect(try recoveryArchives(journal).isEmpty)
        #expect(env.context.hasChanges == pendingEdit)
    }

    @Test("The recovery is offered only beside the journal's own refusal")
    func offerFollowsTheError() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let service = CapabilityCatalogActionService()
        let refusal = ConnectorCredentialGenerationJournal.Failure.wrongStore
        // No journal yet: nothing to recover, whatever the error says.
        #expect(!service.offersCredentialEditingRecovery(after: refusal, modelContext: env.context))
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeDriftedJournal(journal, context: env.context)
        #expect(service.offersCredentialEditingRecovery(after: refusal, modelContext: env.context))
        #expect(!service.offersCredentialEditingRecovery(after: CocoaError(.fileNoSuchFile), modelContext: env.context))
    }

    @Test("A new workspace that needs an account asks before creating anything")
    func creationAsksBeforeCreating() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let root = env.disk.root.appendingPathComponent("Workspaces")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
        try writeDriftedJournal(journal, context: env.context)
        let coordinator = ContentWorkspaceActionCoordinator(modelContext: env.context, taskQueue: TaskQueue(),
            workspacesRoot: root.path)
        var draft = NewWorkspaceDraft(name: "Needs An Account")
        draft.selectedCapabilityIDs = [OnboardingCapabilitySetup.redcapPackageID]
        draft.capabilityConfiguration.redcapAPIToken = "synthetic-token"
        try #require(draft.canCreate)
        let workspacesBefore = try env.context.fetch(FetchDescriptor<Workspace>()).count

        let attempt = coordinator.attemptWorkspaceCreation(from: draft, source: "test")

        #expect(attempt.outcome == .needsCredentialRecovery)
        #expect(attempt.workspace == nil)
        #expect(try env.context.fetch(FetchDescriptor<Workspace>()).count == workspacesBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(!env.context.hasChanges)

        // A workspace with no account to create is not held up by the journal.
        let plain = coordinator.attemptWorkspaceCreation(from: NewWorkspaceDraft(name: "No Capabilities"), source: "test")
        #expect(plain.outcome == .created)
        #expect(plain.workspace?.name == "No Capabilities")
    }

    @Test("Setup notices carry the creation outcome, and the installer's reasons")
    func noticeMapping() {
        #expect(WorkspaceCapabilityNotice(.created) == nil)
        #expect(WorkspaceCapabilityNotice(.notCreated) == nil)
        #expect(WorkspaceCapabilityNotice(.needsCredentialRecovery) == .needsCredentialRecovery)
        #expect(!WorkspaceCreationOutcome.needsCredentialRecovery.didCreate)
        let failures = (1...5).map { "Synthetic \($0): reason \($0)" }
        let notice = WorkspaceCapabilityNotice(.createdWithCapabilityIssues(failures))
        #expect(notice == .enableFailures(failures))
        #expect(WorkspaceCreationOutcome.createdWithCapabilityIssues(failures).didCreate)
        let message = notice?.enableFailureMessage ?? ""
        #expect(message.contains("Synthetic 3: reason 3") && !message.contains("Synthetic 4"))
        #expect(message.contains("and 2 more"))
        #expect(notice?.isRecoveryPrompt == false)
        #expect(WorkspaceCapabilityNotice.recoveryFailed("synthetic").isRecoveryPrompt)
        #expect(WorkspaceCapabilityNotice.recoveryFailed("synthetic").enableFailureMessage == nil)
    }

    /// A version 1 record whose only difference from this store is the mount
    /// device number, as a reboot leaves it.
    private func writeDriftedJournal(_ journal: ConnectorCredentialGenerationJournal, context: ModelContext) throws {
        let identity = try #require(PersistentStoreIdentity.current(for: context))
        let parts = identity.split(separator: "|")
        let numbers = parts[1].split(separator: ":")
        let drifted = "\(parts[0])|\((UInt64(numbers[0]) ?? 0) + 3):\(numbers[1])"
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "storeIdentity": drifted, "candidates": [Any]()], options: [.sortedKeys])
        try data.write(to: journal.fileURL, options: .atomic)
    }

    private func recoveryArchives(_ journal: ConnectorCredentialGenerationJournal) throws -> [URL] {
        let directory = journal.fileURL.deletingLastPathComponent().appendingPathComponent("ConnectorCredentialRecovery")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func expectWrongStore(_ body: () throws -> Void) {
        do { try body(); Issue.record("Expected wrongStore") }
        catch ConnectorCredentialGenerationJournal.Failure.wrongStore { }
        catch { Issue.record("Unexpected error type: \(String(reflecting: type(of: error)))") }
    }
}
