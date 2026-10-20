import Foundation
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

}
