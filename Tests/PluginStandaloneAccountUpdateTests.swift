import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Standalone account updates preserve accepted credentials", .serialized)
struct PluginStandaloneAccountUpdateTests {
    @Test("A later Update cannot give an accepted account a missing credential", arguments: [false, true])
    func promotionDoesNotChangeQueuedAuthority(automatic: Bool) throws {
        try withLegacySetting { env, package, account, task, snapshot in
            let before = try #require(TaskCapabilityResolver(task: task).resourceInventory.connectors.first { $0.id == account.id })
            try #require(before.credentialKeys.contains("PROJECT"))
            try #require(before.currentCredentialValue(forKey: "PROJECT") == nil)
            let namespace = before.credentialNamespaceID
            var updated = package
            updated.version = "2.0.0"
            try CapabilityLibrary().install(updated)
            let changed = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated],
                mode: automatic ? .automatic : .release)
            try #require(changed == 1)
            let current = try #require(TaskCapabilityResolver(task: task).resourceInventory.connectors.first { $0.id == account.id })
            try #require(current.currentCredentialValue(forKey: "PROJECT") == "legacy-account-update-token")
            #expect(current.credentialNamespaceID != namespace)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let queued = try #require(TaskCapabilityResolver(task: launch).resourceInventory.connectors.first { $0.id == account.id })
            #expect(queued.credentialKeys.contains("PROJECT"))
            #expect(queued.currentCredentialValue(forKey: "PROJECT") == nil)
            #expect(account.configKeys.isEmpty)
        }
    }

    @Test("Before a failed Update save, a fresh reader sees only the accepted account", arguments: [false, true])
    func failedUpdateDoesNotPublishBeforeSave(throwing: Bool) throws {
        try withLegacySetting { env, package, account, _, _ in
            var updated = package
            updated.version = "2.0.0"
            let before = PluginAccountRecord(account)
            let receipts = try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>())
            var beforeCommit: String?
            #expect(throws: (any Error).self) {
                _ = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated], mode: .release,
                    persist: { context in
                        let saved = try #require(try ModelContext(context.container).fetch(FetchDescriptor<Connector>()).first { $0.id == account.id })
                        beforeCommit = saved.currentCredentialValue(forKey: "PROJECT")
                        if throwing { throw NSError(domain: "synthetic.account-update.save", code: 1) }
                    })
            }
            #expect(beforeCommit == nil)
            #expect(PluginAccountRecord(account) == before)
            #expect(try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == receipts)
            #expect(account.configValues == ["legacy-account-update-token"])
        }
    }

    @Test("A saved account update recovers forward with its original namespace and receipt", arguments: [false, true])
    func savedUpdateRecoversForward(reportedSaveFailure: Bool) throws {
        try withLegacySetting { env, package, account, task, _ in
            var updated = package
            updated.version = "2.0.0"
            try CapabilityLibrary().install(updated)
            let original = account.credentialNamespaceID
            let persist: ((ModelContext) throws -> Void)? = reportedSaveFailure ? { context in
                try context.save()
                throw NSError(domain: "synthetic.account-update.reported-save", code: 1)
            } : nil
            var operationID: UUID?
            do {
                _ = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated], mode: .release,
                    rewriteMirror: reportedSaveFailure ? nil : { _ in false }, persist: persist)
                Issue.record("A saved account update must report its incomplete recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let namespace = try #require(account.credentialNamespaceID)
            #expect(namespace != original)
            let reopened = try env.disk.reopen()
            let savedTask = try #require(try reopened.mainContext.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
            let request = try #require(try reopened.mainContext.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: savedTask))
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: reopened.mainContext))
            #expect(try journal.pending().contains { $0.credentialNamespaceID == namespace })
            #expect(journal.resumePending(modelContext: reopened.mainContext) == 0)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
            #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext, only: id).completed == 1)
            _ = journal.resumePending(modelContext: reopened.mainContext)
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first { $0.id == account.id })
            #expect(saved.credentialNamespaceID == namespace)
            #expect(saved.currentCredentialValue(forKey: "PROJECT") == "legacy-account-update-token")
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: savedTask)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let queued = try #require(TaskCapabilityResolver(task: launch).resourceInventory.connectors.first { $0.id == account.id })
            #expect(queued.currentCredentialValue(forKey: "PROJECT") == nil)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
        }
    }

    private func withLegacySetting(_ body: (PluginAddCommitTests.Fixture, PluginPackage, Connector, AgentTask, AgentTaskLaunchSnapshot) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.localTools = []
            package.skills[0].environmentKeys = []
            package.skills[0].environmentValues = []
            package.connectors[0].credentialHints = []
            package.connectors[0].configHints = [.init(key: "PROJECT", hint: "Project", isList: false)]
            let library = CapabilityLibrary()
            try library.install(package)
            defer { _ = try? library.removePackage(id: package.id) }
            try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
                .enable(package, in: env.workspace, modelContext: env.context)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
            let account = try #require(activation.bindings.first?.account)
            try #require(account.credentialKeys.contains("PROJECT"))
            try #require(account.currentCredentialValue(forKey: "PROJECT") == nil)
            account.configKeys = ["PROJECT"]
            account.configValues = ["legacy-account-update-token"]
            let task = AgentTask(title: "Accepted account before Update", goal: "Use accepted account", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            try body(env, package, account, task, snapshot)
        }
    }
}
