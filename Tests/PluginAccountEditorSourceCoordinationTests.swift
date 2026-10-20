import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Account editor uses the source mutation lock", .serialized)
struct PluginAccountEditorSourceCoordinationTests {
    @Test("An unrelated source mutation excludes credential edits before they write")
    func unrelatedSourceChangeExcludesEditor() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            let namespace = account.credentialNamespaceID
            let store = PluginSourceStore()
            try store.exclusively(pluginID: "unrelated-source") {
                #expect(throws: PluginSourceStoreError.libraryBusy) {
                    _ = try ConnectorCredentialEditor.save("must-not-cross-source-commit", forKey: "API_TOKEN", on: account,
                        modelContext: env.disk.context)
                }
                #expect(throws: PluginSourceStoreError.libraryBusy) {
                    try ConnectorCredentialEditor.remove("API_TOKEN", from: account, modelContext: env.disk.context)
                }
            }
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
        }
    }
    @Test("Finishing credential recovery respects the same source lock and remains retryable")
    func recoveryRespectsSourceMutationLock() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            var operationID: UUID?
            do {
                _ = try ConnectorCredentialEditor.save("pending-editor-source-token", forKey: "API_TOKEN", on: account,
                    modelContext: env.disk.context, rewriteMirror: { _ in false })
                Issue.record("Saved editor change must report pending recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let namespace = account.credentialNamespaceID
            let store = PluginSourceStore()
            try store.exclusively(pluginID: "unrelated-source") {
                #expect(throws: PluginSourceStoreError.libraryBusy) {
                    try ConnectorCredentialEditor.recover(id, modelContext: env.disk.context)
                }
                let pending = try PluginOperationCommit.read(id, container: env.disk.context.container)
                #expect(pending?.completedAt == nil)
            }
            try ConnectorCredentialEditor.recover(id, modelContext: env.disk.context)
            #expect(try PluginOperationCommit.read(id, container: env.disk.context.container)?.completedAt != nil)
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "pending-editor-source-token")
        }
    }

    @Test("An unrelated source mutation excludes account duplication before staging")
    func unrelatedSourceChangeExcludesDuplication() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            let store = PluginSourceStore()
            try store.exclusively(pluginID: "unrelated-source") {
                #expect(throws: PluginSourceStoreError.libraryBusy) {
                    _ = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context)
                }
            }
            #expect(try env.disk.context.fetchCount(FetchDescriptor<Connector>()) == 1)
            #expect(source.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("Source mutation excludes both automatic and direct legacy credential migration", arguments: [false, true])
    func sourceMutationExcludesLegacyMigration(startupEntry: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = nil
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("legacy-second-token")
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            try PluginSourceStore().exclusively(pluginID: "unrelated-source") {
                if startupEntry { StartupCredentialMigrationService.migrate(modelContext: env.disk.context) }
                else {
                    #expect(throws: PluginSourceStoreError.libraryBusy) {
                        _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context)
                    }
                }
            }
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.credentialValues.contains("legacy-second-token"))
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
        }
    }

}
