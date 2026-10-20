import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Startup account credential cutover", .serialized)
struct PluginStartupCredentialMigrationTests {
    @Test("Startup does not admit an invalid raw credential or promoted setting", arguments: [false, true])
    func invalidRawValueStaysPending(setting: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            let key = setting ? "TRACKER_PROJECT" : "SECOND_TOKEN"
            account.originPackageID = "imported.tracker"
            if setting {
                account.configKeys = [key]
                account.configValues = ["your-token-here"]
            } else {
                account.credentialKeys.append(key)
                account.credentialValues.append("your-token-here")
            }
            try env.disk.context.save()
            #expect(!StartupCredentialMigrationService.migrateAccounts([account],
                mirroredBy: [env.disk.workspace], modelContext: env.disk.context,
                resolver: PluginConnectorFieldTrustTests.StubCreator.self))
            #expect(account.currentCredentialValue(forKey: key) == nil)
            #expect((setting ? account.configValues : account.credentialValues).contains("your-token-here"))
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
        }
    }

    @Test("The production startup entry publishes admitted plaintext in an independent generation")
    func actualStartupKeepsQueuedAccountUnchanged() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = nil
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("legacy-second-token")
            let task = AgentTask(title: "Before startup cutover", goal: "Keep accepted account", workspace: env.disk.workspace)
            env.disk.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [env.package])
            env.disk.context.insert(request)
            try env.disk.context.save()
            let accepted = try #require(request.executionPolicySnapshot?.pluginAccounts?.first)
            let oldNamespace = account.credentialNamespaceID
            StartupCredentialMigrationService.migrate(modelContext: env.disk.context)
            #expect(account.credentialNamespaceID != oldNamespace)
            #expect(account.credentialValues.allSatisfy { $0.isEmpty })
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == "legacy-second-token")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
            request.state = .completed
            request.terminalAt = Date()
            try env.disk.context.save()
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            _ = journal.resumePending(modelContext: env.disk.context)
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == "legacy-second-token")
        }
    }

    @Test("A no-op migration save preserves the raw source before callback, rollback and reopen")
    func noCommitPreservesSavedSource() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = "imported.tracker"
            account.configKeys = ["tracker_project"]
            account.configValues = ["ENG-1"]
            try env.disk.context.save()
            let oldNamespace = account.credentialNamespaceID
            #expect(throws: ConnectorCredentialEditor.Failure.self) {
                _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context,
                    resolver: PluginConnectorFieldTrustTests.StubCreator.self, persist: { context in
                        let saved = try #require(try ModelContext(context.container).fetch(FetchDescriptor<Connector>()).first)
                        #expect(saved.configValues == ["ENG-1"])
                        #expect(saved.currentCredentialValue(forKey: "TRACKER_PROJECT") == nil)
                        #expect(saved.credentialNamespaceID == oldNamespace)
                    })
            }
            #expect(account.configValues == ["ENG-1"])
            #expect(account.credentialNamespaceID == oldNamespace)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.configValues == ["ENG-1"])
            #expect(saved.currentCredentialValue(forKey: "TRACKER_PROJECT") == nil)
        }
    }

    @Test("A committed migration recovers the same receipt after reopen without repeating admission", arguments: [false, true])
    func savedFailureRecovers(reportedFailure: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = "imported.tracker"
            account.configKeys = ["TRACKER_PROJECT"]
            account.configValues = ["ENG-1"]
            let unused = Workspace(name: "Former consumer", primaryPath: env.disk.disk.root.appendingPathComponent("unused").path)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: unused.primaryPath), withIntermediateDirectories: true)
            env.disk.context.insert(unused)
            try env.disk.context.save()
            var operationID: UUID?
            do {
                _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context,
                    resolver: PluginConnectorFieldTrustTests.StubCreator.self, persist: { context in
                        try context.save()
                        if reportedFailure { throw FixtureFailure.reportedAfterSave }
                    }, rewriteMirror: { _ in false })
                Issue.record("A committed migration must report pending recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let receipt = try #require(try PluginOperationCommit.read(id, container: env.disk.context.container))
            #expect(Set(receipt.workspaceIDs) == [env.disk.workspace.id, unused.id])
            let namespace = account.credentialNamespaceID
            let reopened = try env.disk.disk.reopen()
            let context = reopened.mainContext
            let saved = try #require(try context.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "TRACKER_PROJECT") == "ENG-1")
            #expect(saved.configKeys.isEmpty)
            #expect(throws: PluginOperationProblem.self) {
                _ = try ConnectorCredentialMigration.migrate(saved, mirroredBy: [], modelContext: context,
                    resolver: PluginConnectorFieldTrustTests.StubCreator.self)
            }
            try ConnectorCredentialEditor.recover(id, modelContext: context)
            #expect(saved.credentialNamespaceID == namespace)
            #expect(saved.currentCredentialValue(forKey: "TRACKER_PROJECT") == "ENG-1")
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
            #expect(try String(contentsOfFile: WorkspaceFileLayout.workspaceConfigFile(for: unused.primaryPath), encoding: .utf8).contains("ENG-1") == false)
        }
    }

    @Test("An accepted credential never discards a conflicting legacy setting", arguments: ["ENG-1", "your-token-here"])
    func newerVaultWins(raw: String) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = "imported.tracker"
            account.configKeys = ["tracker_project"]
            account.configValues = [raw]
            #expect(account.restorePreviouslyStoredCredential(key: "TRACKER_PROJECT", value: "ENG-2"))
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context,
                    resolver: PluginConnectorFieldTrustTests.StubCreator.self)
            }
            #expect(account.currentCredentialValue(forKey: "TRACKER_PROJECT") == "ENG-2")
            #expect(account.configValues == [raw])
            #expect(account.credentialNamespaceID == namespace)
        }
    }

    @Test("An unreadable vault leaves raw source data and accepted credentials unchanged")
    func unavailableVaultKeepsSource() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = "imported.tracker"
            account.configKeys = ["TRACKER_PROJECT"]
            account.configValues = ["ENG-1"]
            try env.disk.context.save()
            let badVault = env.disk.disk.root.appendingPathComponent("unreadable-vault")
            try Data("not-a-keychain".utf8).write(to: badVault)
            AstraSecureKeychainStore.$keychainPathOverride.withValue(badVault.path) {
                #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                    _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context,
                        resolver: PluginConnectorFieldTrustTests.StubCreator.self)
                }
            }
            #expect(account.configValues == ["ENG-1"])
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
        }
    }

    @Test("Automatic migration leaves unrelated unsaved edits untouched")
    func unsavedEditsAreNotPartOfMigration() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = nil
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("legacy-second-token")
            try env.disk.context.save()
            env.disk.workspace.name = "Unsaved workspace edit"
            #expect(throws: ConnectorCredentialMigration.Failure.unsavedChanges) {
                _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context)
            }
            #expect(env.disk.workspace.name == "Unsaved workspace edit")
            #expect(env.disk.context.hasChanges)
            #expect(account.credentialValues.contains("legacy-second-token"))
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
        }
    }

    @Test("An unavailable creator or ambiguous legacy rows remain repairable", arguments: [false, true])
    func unknownOrMalformedSourceStaysPending(malformed: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            if malformed {
                account.originPackageID = nil
                account.credentialValues.append("orphan-without-key")
            } else {
                account.credentialKeys.append("SECOND_TOKEN")
                account.credentialValues.append("legacy-second-token")
            }
            try env.disk.context.save()
            let original = account.credentialValues
            #expect(throws: ConnectorCredentialMigration.Failure.self) {
                _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context)
            }
            #expect(account.credentialValues == original)
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
        }
    }

    @Test("Startup applies the current creator's declared format before admitting raw credentials", arguments: [false, true])
    func creatorFormatIsEnforced(valid: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            var package = env.package
            package.connectors[0].credentialHints.append(.init(key: "SECOND_TOKEN", hint: "Second token",
                format: .init(pattern: "[A-F0-9]{32}", expectation: "32 hexadecimal characters")))
            try CapabilityLibrary().install(package)
            let accepted = "A19F2C8D4B6E7A03C5D9F1B2468E0A7C"
            let raw = valid ? "  " + accepted + "  " : "legacy-wrong-shape"
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append(raw)
            try env.disk.context.save()
            if valid {
                #expect(try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context))
                #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == accepted)
                #expect(account.credentialValues.allSatisfy { $0.isEmpty })
            } else {
                #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                    _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context)
                }
                #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
                #expect(account.credentialValues.contains(raw))
            }
        }
    }

    @Test("A leading empty duplicate cannot hide a valid legacy setting from migration")
    func duplicatePlainFieldsKeepAdmittedValue() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.originPackageID = "imported.tracker"
            account.configKeys = ["TRACKER_PROJECT", "TRACKER_PROJECT"]
            account.configValues = ["", "ENG-1"]
            try env.disk.context.save()
            #expect(try ConnectorCredentialMigration.migrate(account, mirroredBy: [env.disk.workspace], modelContext: env.disk.context,
                resolver: PluginConnectorFieldTrustTests.StubCreator.self))
            #expect(account.currentCredentialValue(forKey: "TRACKER_PROJECT") == "ENG-1")
            #expect(account.configKeys.isEmpty)
        }
    }

    private enum FixtureFailure: Error { case reportedAfterSave }

}
