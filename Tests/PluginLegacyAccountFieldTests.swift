import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Legacy account fields retain their source", .serialized)
struct PluginLegacyAccountFieldTests {
    @Test("Add never erases an unlabelled legacy credential value")
    func addKeepsUnlabelledRawFields() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.credentialValues.append("unlabelled-legacy-value")
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                try env.disk.installer.enable(env.package, in: env.disk.workspace, modelContext: env.disk.context)
            }
            #expect(account.credentialValues.contains("unlabelled-legacy-value"))
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
        }
    }

    @Test("Add leaves an unsaved legacy setting available to its editor")
    func addDoesNotConsumeUnsavedLegacySetting() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.configKeys = ["PROJECT"]
            account.configValues = ["ENG-1"]
            try env.disk.context.save()
            account.configValues = ["ENG-2"]
            var package = env.package
            package.version = "2.0.0"
            package.connectors[0].configHints = [.init(key: "PROJECT", hint: "Project", isList: false)]
            #expect(throws: PluginOperations.OperationError.pendingEdits) {
                try env.disk.installer.enable(package, in: env.disk.workspace, modelContext: env.disk.context)
            }
            #expect(account.configValues == ["ENG-2"])
            #expect(env.disk.context.hasChanges)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
            let saved = try #require(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.configValues == ["ENG-1"])
        }
    }

    @Test("An unpublished legacy source cannot stage a secret before its fields are saved")
    func unpublishedLegacySourceDoesNotStage() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = Connector(name: "Unpublished legacy", serviceType: "custom", baseURL: "https://new.example.com")
            account.configKeys = ["PROJECT"]
            account.configValues = ["ENG-1"]
            env.disk.context.insert(account)
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                _ = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: true,
                    keeping: ["PROJECT"], replacing: [], modelContext: env.disk.context, migratingSettings: ["PROJECT"])
            }
            #expect(account.configValues == ["ENG-1"])
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
        }
    }
}
