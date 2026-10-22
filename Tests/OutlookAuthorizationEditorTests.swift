import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Durable Outlook authorization publication", .serialized)
struct OutlookAuthorizationEditorTests {
    private func bundle(_ principal: String) -> OutlookOAuthBundle {
        .init(tenantDomain: "tenant.example", clientID: "synthetic-client", principalID: principal,
              accessToken: "access-" + principal, refreshToken: "refresh-" + principal,
              expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
    private func identity(_ principal: String) -> GraphMeResponse {
        .init(id: principal, displayName: principal, userPrincipalName: principal + "@tenant.example", mail: nil)
    }
    private func account(_ env: PluginAddCommitTests.Fixture) throws -> Connector {
        let account = Connector(name: "Outlook publication")
        account.applyStanfordOutlookDefaults()
        account.setConfigValue(StanfordOutlookMail.tenantDomainKey, value: "tenant.example")
        account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
        account.setConfigValue(StanfordOutlookMail.accountIDKey, value: "original")
        account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat
        account.credentialNamespaceID = UUID()
        account.workspace = env.workspace
        env.context.insert(account)
        try env.context.save()
        let session = try OutlookOAuthVaultSession(reference: .generation(account.credentialNamespaceID!))
        try #require(try session.save(bundle("original")))
        return account
    }
    private func load(_ record: PluginAccountRecord) throws -> OutlookOAuthBundle? {
        let copy = record.makeAccount()
        let reference = try #require(OutlookCredentialIdentity.resolve(accountID: copy.id,
            credentialNamespaceID: copy.credentialNamespaceID, format: copy.outlookCredentialFormat))
        let session = try OutlookOAuthVaultSession(reference: reference)
        return try session.load(tenantDomain: copy.outlookTenantDomain, clientID: copy.outlookClientID,
            principalID: copy.configValue(StanfordOutlookMail.accountIDKey))
    }
    private func accept(_ env: PluginAddCommitTests.Fixture, title: String, accountID: UUID) throws -> (TaskTurnRequest, PluginAccountRecord) {
        let task = AgentTask(title: title, goal: "Use accepted Outlook", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
        let taskID = task.id
        let request = try #require(env.context.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate { $0.taskID == taskID })).first)
        let record = try #require(request.executionPolicySnapshot?.accountInventory?.entries.first { $0.account.id == accountID }?.account)
        return (request, record)
    }

    @Test("Actual login and sign-out retain accepted requests until completion and survive disk reopen")
    func completeAuthorizationLifecycle() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(env)
            let (firstRequest, firstAccepted) = try accept(env, title: "Original login", accountID: current.id)
            let first = current.credentialNamespaceID
            try OutlookAuthorizationEditor.authorize(bundle("replacement"), identity: identity("replacement"),
                expected: PluginAccountRecord(current), on: current, modelContext: env.context, allowUserInteraction: false)
            #expect(current.credentialNamespaceID != first)
            #expect(try load(PluginAccountRecord(current)) == bundle("replacement"))
            #expect(try load(firstAccepted) == bundle("original"))
            let (secondRequest, secondAccepted) = try accept(env, title: "New login", accountID: current.id)
            let second = current.credentialNamespaceID
            try OutlookAuthorizationEditor.signOut(current, modelContext: env.context)
            #expect(current.credentialNamespaceID != second)
            #expect(current.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
            #expect(try load(PluginAccountRecord(current)) == nil)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
            _ = journal.resumePending(modelContext: env.context)
            #expect(try load(firstAccepted) == bundle("original"))
            #expect(try load(secondAccepted) == bundle("replacement"))
            let reopened = try env.disk.reopen()
            let id = current.id
            let saved = try #require(reopened.mainContext.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })).first)
            #expect(saved.credentialNamespaceID == current.credentialNamespaceID)
            #expect(try load(PluginAccountRecord(saved)) == nil)
            firstRequest.state = .completed
            secondRequest.state = .completed
            try env.context.save()
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context,
                url: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath)))
            _ = journal.resumePending(modelContext: env.context)
            #expect(try load(firstAccepted) == nil)
            #expect(try load(secondAccepted) == nil)
        }
    }

    @Test("A failed domain save removes only unpublished credentials and restores the exact account")
    func failedCommitKeepsOriginalAuthorization() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(env)
            let before = PluginAccountRecord(current)
            var staged: UUID?
            #expect(throws: (any Error).self) {
                try OutlookAuthorizationEditor.authorize(bundle("replacement"), identity: identity("replacement"),
                    expected: before, on: current, modelContext: env.context, allowUserInteraction: false,
                    persist: { _ in staged = current.credentialNamespaceID; throw CocoaError(.fileWriteNoPermission) })
            }
            #expect(PluginAccountRecord(current) == before)
            #expect(try load(before) == bundle("original"))
            let namespace = try #require(staged)
            #expect(namespace != before.credentialNamespaceID)
            #expect(KeychainService.load(key: OutlookOAuthBundle.storageKey, connectorID: namespace) == nil)
        }
    }

    @Test("A late sign-in cannot replace an edited account or publish another verified principal")
    func staleOrUnverifiedCompletionIsRefused() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(env)
            let expected = PluginAccountRecord(current)
            current.name = "Edited while signing in"
            try env.context.save()
            #expect(throws: (any Error).self) {
                try OutlookAuthorizationEditor.authorize(bundle("replacement"), identity: identity("replacement"),
                    expected: expected, on: current, modelContext: env.context, allowUserInteraction: false)
            }
            #expect(throws: (any Error).self) {
                try OutlookAuthorizationEditor.authorize(bundle("replacement"), identity: identity("different-principal"),
                    expected: PluginAccountRecord(current), on: current, modelContext: env.context, allowUserInteraction: false)
            }
            #expect(current.credentialNamespaceID == expected.credentialNamespaceID)
            #expect(try load(PluginAccountRecord(current)) == bundle("original"))
        }
    }

    @Test("A committed login awaiting mirrors recovers forward without replacing its credential generation")
    func committedPublicationRecoversForward() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let current = try account(env)
            let (_, accepted) = try accept(env, title: "Pending original", accountID: current.id)
            var receipt: UUID?
            do {
                try OutlookAuthorizationEditor.authorize(bundle("replacement"), identity: identity("replacement"),
                    expected: PluginAccountRecord(current), on: current, modelContext: env.context, allowUserInteraction: false,
                    rewriteMirror: { _ in false })
                Issue.record("Expected committed recovery debt")
            } catch PluginOperationProblem.savedRecoveryPending(let id) { receipt = id }
            let published = try #require(current.credentialNamespaceID)
            let id = current.id
            let reopened = try env.disk.reopen()
            let saved = try #require(reopened.mainContext.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })).first)
            #expect(saved.credentialNamespaceID == published)
            #expect(try load(PluginAccountRecord(saved)) == bundle("replacement"))
            try ConnectorCredentialEditor.recover(try #require(receipt), modelContext: reopened.mainContext)
            #expect(saved.credentialNamespaceID == published)
            #expect(try load(PluginAccountRecord(saved)) == bundle("replacement"))
            #expect(try load(accepted) == bundle("original"))
        }
    }

    @Test("Applying provider defaults does not erase unrelated account credentials")
    func defaultsPreserveCredentialOwner() {
        let account = Connector(name: "Configured account", serviceType: OutlookCredentialIdentity.serviceType)
        account.credentialKeys = ["EXTRA_TOKEN"]
        account.credentialValues = [""]
        account.applyStanfordOutlookDefaults()
        #expect(account.credentialKeys == ["EXTRA_TOKEN"])
        #expect(account.credentialValues == [""])
    }
}
