import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Account credential editor commits", .serialized)
struct ConnectorCredentialEditorTests {
    @Test("Replacing or removing a credential keeps the value accepted by a queued request", arguments: [false, true])
    func queuedAccountKeepsAcceptedCredential(removing: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            let task = AgentTask(title: "Queued editor", goal: "Use accepted credential", workspace: env.disk.workspace)
            env.disk.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [env.package])
            env.disk.context.insert(request)
            try env.disk.context.save()
            let accepted = try #require(request.executionPolicySnapshot?.pluginAccounts?.first)
            if removing {
                try remove("API_TOKEN", from: account, in: env)
                #expect(account.currentCredentialValue(forKey: "API_TOKEN") == nil)
            } else {
                #expect(try replace("API_TOKEN", with: "replacement-editor-token", on: account, in: env).isSaved)
                #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "replacement-editor-token")
            }
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            request.state = .completed
            request.terminalAt = Date()
            try env.disk.context.save()
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            _ = journal.resumePending(modelContext: env.disk.context)
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == (removing ? nil : "replacement-editor-token"))
        }
    }

    @Test("An unsaved callback cannot publish a credential replacement or removal", arguments: [false, true])
    func successRequiresSavedReceipt(removing: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.configKeys = ["api_token", "SCOPE"]
            account.configValues = ["legacy-plain-token", "workspace-scope"]
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            var observed: String?
            #expect(throws: ConnectorCredentialEditor.Failure.self) {
                let persist: (ModelContext) throws -> Void = { context in
                    let saved = try #require(try ModelContext(context.container).fetch(FetchDescriptor<Connector>()).first)
                    observed = saved.currentCredentialValue(forKey: "API_TOKEN")
                }
                if removing {
                    try ConnectorCredentialEditor.remove("API_TOKEN", from: account, modelContext: env.disk.context, persist: persist)
                } else {
                    _ = try ConnectorCredentialEditor.save("uncommitted-editor-token", forKey: "API_TOKEN", on: account,
                        modelContext: env.disk.context, persist: persist)
                }
            }
            #expect(observed == "accepted-editor-token")
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.configKeys == ["api_token", "SCOPE"])
            #expect(account.configValues == ["legacy-plain-token", "workspace-scope"])
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
        }
    }

    @Test("Saved edits recover their original receipt without repeating the credential write", arguments: [false, true])
    func savedFailureRecoversWithoutAnotherWrite(failureAfterSave: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            var operationID: UUID?
            do {
                _ = try ConnectorCredentialEditor.save("saved-editor-token", forKey: "API_TOKEN", on: account,
                    modelContext: env.disk.context, persist: { context in
                        try context.save()
                        if failureAfterSave { throw FixtureFailure.saveReportedFailure }
                    }, rewriteMirror: { _ in false })
                Issue.record("Saved change must retain its pending recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let namespace = account.credentialNamespaceID
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "saved-editor-token")
            let saved = try #require(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "API_TOKEN") == "saved-editor-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            let candidates = try journal.pending()
            #expect(throws: PluginOperationProblem.self) {
                _ = try ConnectorCredentialEditor.save("must-not-replay-token", forKey: "API_TOKEN", on: account,
                    modelContext: env.disk.context)
            }
            #expect(try journal.pending() == candidates)
            try ConnectorCredentialEditor.recover(id, modelContext: env.disk.context)
            #expect(try PluginOperationCommit.read(id, container: env.disk.context.container)?.completedAt != nil)
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "saved-editor-token")
            #expect(try journal.pending() == candidates)
        }
    }

    @Test("An invalid replacement leaves the accepted account untouched")
    func rejectedReplacementDoesNotChangeAccount() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            let namespace = account.credentialNamespaceID
            let result = try ConnectorCredentialEditor.save("your-token-here", forKey: "API_TOKEN", on: account,
                modelContext: env.disk.context)
            #expect(result == .rejected(.placeholder))
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("Indeterminate caller receipts block another credential edit before staging")
    func unsavedReceiptPreventsAnotherEdit() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            let receipt = PluginOperationReceipt(kind: .configure, pluginIDs: [], workspaceIDs: [env.disk.workspace.id])
            env.disk.context.insert(receipt)
            #expect(throws: PluginOperationProblem.self) {
                _ = try ConnectorCredentialEditor.save("unverified-editor-token", forKey: "API_TOKEN", on: account,
                    modelContext: env.disk.context)
            }
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
            #expect(throws: ConnectorCredentialEditor.Failure.self) {
                try ConnectorCredentialEditor.recover(receipt.id, modelContext: env.disk.context)
            }
        }
    }

    @Test("Credential removal clears every canonical duplicate marker")
    func removeDuplicateMarkersTogether() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.credentialKeys.append("api_token")
            account.credentialValues.append("")
            try env.disk.context.save()
            try ConnectorCredentialEditor.remove("api_token", from: account, modelContext: env.disk.context)
            #expect(account.credentialKeys.isEmpty)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == nil)
        }
    }

    @Test("Conflicting legacy values require an explicit replacement instead of silently choosing one")
    func conflictingLegacyValuesNeedExplicitChoice() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.credentialKeys += ["SECOND_TOKEN", "second_token"]
            account.credentialValues += ["legacy-first-second-token", "legacy-other-second-token"]
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                _ = try ConnectorCredentialEditor.save("must-not-replace-api", forKey: "API_TOKEN", on: account,
                    modelContext: env.disk.context)
            }
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(account.credentialValues.contains("legacy-first-second-token"))
            #expect(account.credentialValues.contains("legacy-other-second-token"))
            #expect(try ConnectorCredentialEditor.save("chosen-second-token", forKey: "SECOND_TOKEN", on: account,
                modelContext: env.disk.context).isSaved)
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == "chosen-second-token")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(account.credentialKeys.filter { ConnectorCredentialKey.same($0, "SECOND_TOKEN") }.count == 1)
        }
    }

    @Test("Editing another credential preserves a newer vault value behind a promoted legacy setting", arguments: ["TRACKER_PROJECT", "tracker_project"])
    func promotedShadowValueRemainsOwned(key: String) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            #expect(account.restorePreviouslyStoredCredential(key: "TRACKER_PROJECT", value: "ENG-2"))
            account.credentialKeys = ["API_TOKEN"]
            account.credentialValues = [""]
            account.configKeys = [key]
            account.configValues = ["ENG-1"]
            account.originPackageID = "imported.tracker"
            try env.disk.context.save()
            #expect(try ConnectorCredentialEditor.save("new-api-editor-token", forKey: "API_TOKEN", on: account,
                modelContext: env.disk.context, settingResolver: PluginConnectorFieldTrustTests.StubCreator.self).isSaved)
            #expect(account.currentCredentialValue(forKey: "TRACKER_PROJECT") == "ENG-2")
            #expect(account.configValue(key) == "ENG-1")
        }
    }

    @Test("A secret edit settles its legacy plain alias while retaining other configuration", arguments: [false, true])
    func editedKeyHasOneOwner(removing: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.configKeys = ["api_token", "SCOPE"]
            account.configValues = ["stale-plain-token", "workspace-scope"]
            try env.disk.context.save()
            if removing {
                try ConnectorCredentialEditor.remove("API_TOKEN", from: account, modelContext: env.disk.context)
            } else {
                #expect(try ConnectorCredentialEditor.save("new-single-owner-token", forKey: "API_TOKEN", on: account,
                    modelContext: env.disk.context).isSaved)
            }
            #expect(account.configKeys == ["SCOPE"])
            #expect(account.configValue("SCOPE") == "workspace-scope")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == (removing ? nil : "new-single-owner-token"))
        }
    }

    @Test("A shared account edit records every consuming workspace and excludes unrelated workspaces")
    func sharedAccountRewritesAllConsumers() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            account.isGlobal = true
            account.workspace = nil
            let other = Workspace(name: "Other consumer", primaryPath: env.disk.disk.root.appendingPathComponent("other").path)
            let unrelated = Workspace(name: "Unrelated", primaryPath: env.disk.disk.root.appendingPathComponent("unrelated").path)
            env.disk.context.insert(other)
            env.disk.context.insert(unrelated)
            WorkspaceCapabilityActivation.mutate(other) { $0.enableGlobalConnector(account.id.uuidString) }
            try env.disk.context.save()
            var exported: [UUID] = []
            #expect(try ConnectorCredentialEditor.save("shared-editor-token", forKey: "API_TOKEN", on: account,
                modelContext: env.disk.context, rewriteMirror: { workspace in exported.append(workspace.id); return true }).isSaved)
            #expect(Set(exported) == Set([env.disk.workspace.id, other.id]))
            #expect(exported.count == 2)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "shared-editor-token")
        }
    }

    @Test("Adding a credential retains the account's existing credentials and persists both")
    func addingCredentialKeepsExistingValues() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            #expect(try ConnectorCredentialEditor.save("additional-editor-token", forKey: "SECOND_TOKEN", on: account,
                modelContext: env.disk.context).isSaved)
            #expect(account.credentialKeys == ["API_TOKEN", "SECOND_TOKEN"])
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == "additional-editor-token")
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "API_TOKEN") == "accepted-editor-token")
            #expect(saved.currentCredentialValue(forKey: "SECOND_TOKEN") == "additional-editor-token")
        }
    }

    private enum FixtureFailure: Error { case saveReportedFailure }

    private func replace(_ key: String, with value: String, on account: Connector, in env: Fixture) throws -> ConnectorCredentialSaveOutcome {
        try ConnectorCredentialEditor.save(value, forKey: key, on: account, modelContext: env.disk.context)
    }

    private func remove(_ key: String, from account: Connector, in env: Fixture) throws {
        try ConnectorCredentialEditor.remove(key, from: account, modelContext: env.disk.context)
    }

    @MainActor
    struct Fixture {
        let disk: PluginAddCommitTests.Fixture
        let package: PluginPackage
        init() throws {
            disk = try PluginAddCommitTests.Fixture(installed: false)
            var value = disk.package
            value.connectors = [PluginConnector(name: "Editor API", serviceType: "custom", icon: "network",
                description: "Credential editor", baseURL: "https://api.example.com", authMethod: "bearer",
                credentialHints: [.init(key: "API_TOKEN", hint: "API token")], configHints: [], notes: "")]
            package = value
        }
        func enable() throws -> Connector {
            try disk.installer.enable(package, in: disk.workspace, modelContext: disk.context,
                credentialInputs: ["API_TOKEN": "accepted-editor-token"])
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: disk.workspace))
            return try #require(activation.bindings.first?.account)
        }
    }
}
