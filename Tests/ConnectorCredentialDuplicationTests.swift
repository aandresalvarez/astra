import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Durable account credential duplication", .serialized)
struct ConnectorCredentialDuplicationTests {
    @Test("Duplicating a selected account uses a private namespace without writing its endpoint alias")
    func selectedAccountUsesIndependentNamespace() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: source))
            #expect(KeychainSecretStore().save(key: "API_TOKEN", value: "other-legacy-endpoint-token", entityID: stable, label: nil))
            let copy = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context)
            #expect(copy.credentialNamespaceID != nil)
            #expect(copy.credentialNamespaceID != source.credentialNamespaceID)
            #expect(copy.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(source.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(KeychainSecretStore().load(key: "API_TOKEN", entityID: stable) == "other-legacy-endpoint-token")
            let saved = try #require(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).first { $0.id == copy.id })
            #expect(saved.credentialNamespaceID == copy.credentialNamespaceID)
            let projection = PluginRuntimeProjection.project(workspace: env.disk.workspace, packages: [env.package],
                connectorMode: .runtimeCopies, definitions: [env.package])
            #expect(projection.connectors.contains { $0.id == copy.id })
            #expect(!projection.connectors.contains { $0.id == source.id })
            #expect(copy.originPackageID == source.originPackageID)
            #expect(copy.originComponentID == source.originComponentID)
        }
    }

    @Test("An unproved duplication save keeps the original account enabled and reclaims only its copy")
    func failedSaveKeepsSource() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            source.isGlobal = true
            source.workspace = nil
            env.disk.workspace.enabledGlobalConnectorIDs = [source.id.uuidString]
            try env.disk.context.save()
            var staged: Connector?
            #expect(throws: ConnectorCredentialEditor.Failure.self) {
                _ = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context,
                    persist: { context in
                        staged = try context.fetch(FetchDescriptor<Connector>()).first { $0.id != source.id }
                        #expect(try ModelContext(context.container).fetch(FetchDescriptor<Connector>()).count == 1)
                    })
            }
            let copy = try #require(staged)
            #expect(copy.currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(source.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(env.disk.workspace.enabledGlobalConnectorIDs == [source.id.uuidString])
            #expect(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).count == 1)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("A saved copy recovers its original receipt without duplicating again", arguments: [false, true])
    func savedCopyRecovers(reportedFailure: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            var operationID: UUID?
            do {
                _ = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context,
                    persist: { context in
                        try context.save()
                        if reportedFailure { throw TestFailure.afterSave }
                    }, rewriteMirror: { _ in false })
                Issue.record("A saved copy needs forward recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let copies = try env.disk.context.fetch(FetchDescriptor<Connector>()).filter { $0.id != source.id }
            let copy = try #require(copies.first)
            #expect(copies.count == 1)
            #expect(copy.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(throws: PluginOperationProblem.self) {
                _ = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context)
            }
            try ConnectorCredentialEditor.recover(id, modelContext: env.disk.context)
            #expect(try PluginOperationCommit.read(id, container: env.disk.context.container)?.completedAt != nil)
            #expect(try env.disk.context.fetch(FetchDescriptor<Connector>()).count == 2)
            #expect(copy.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
        }
    }

    @Test("Duplicating preserves a newer promoted setting without borrowing another namespace")
    func promotedSettingKeepsAcceptedValue() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            source.originPackageID = "imported.tracker"
            source.configKeys = ["tracker_project"]
            source.configValues = ["ENG-1"]
            #expect(source.restorePreviouslyStoredCredential(key: "TRACKER_PROJECT", value: "ENG-2"))
            try env.disk.context.save()
            let copy = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context,
                settingResolver: PluginConnectorFieldTrustTests.StubCreator.self)
            #expect(copy.currentCredentialValue(forKey: "TRACKER_PROJECT") == "ENG-2")
            #expect(copy.configValue("tracker_project") == "ENG-1")
        }
    }


    @Test("A local duplicate keeps the shared original bound in other workspaces")
    func otherWorkspaceKeepsSharedAccount() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            source.isGlobal = true
            source.workspace = nil
            let other = Workspace(name: "Other consumer", primaryPath: env.disk.disk.root.appendingPathComponent("other").path)
            env.disk.context.insert(other)
            let activation = PluginActivation(pluginID: env.package.id)
            env.disk.context.insert(activation)
            activation.workspace = other
            let component = try #require(source.originComponentID)
            WorkspaceCapabilityActivation.bind(source, toComponent: component, of: activation, isDefault: true)
            try env.disk.context.save()
            let copy = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context)
            #expect(activation.bindings.contains { !$0.isDeleted && $0.account?.id == source.id && $0.isDefault })
            #expect(!activation.bindings.contains { $0.account?.id == copy.id })
            #expect(source.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            let current = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.disk.workspace))
            #expect(current.bindings.contains { !$0.isDeleted && $0.account?.id == copy.id && $0.isDefault })
            #expect(!current.bindings.contains { !$0.isDeleted && $0.account?.id == source.id })
        }
    }

    @Test("Duplication refuses invalid raw credentials without changing the selected source")
    func rawLegacyValueRequiresAdmission() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            source.credentialKeys.append("SECOND_TOKEN")
            source.credentialValues.append("your-token-here")
            try env.disk.context.save()
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                _ = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context)
            }
            #expect(source.credentialValues.contains("your-token-here"))
            #expect(source.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).count == 1)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("An unreadable credential vault cannot produce a partial copy")
    func unavailableSourceRefusesDuplication() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let source = try env.enable()
            let badVault = env.disk.disk.root.appendingPathComponent("unreadable-vault")
            try Data("not-a-keychain".utf8).write(to: badVault)
            AstraSecureKeychainStore.$keychainPathOverride.withValue(badVault.path) {
                #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                    _ = try ConnectorCredentialDuplication.duplicate(source, in: env.disk.workspace, modelContext: env.disk.context)
                }
            }
            #expect(source.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).count == 1)
        }
    }

    private enum TestFailure: Error { case afterSave }
}
