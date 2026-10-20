import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin account edits preserve accepted credentials", .serialized)
struct PluginAccountCredentialGenerationTests {
    @Test("Repeated Add keeps the credential an accepted queued account used", arguments: [false, true])
    func queuedAccountKeepsItsAcceptedValue(legacy: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("accepted-account-token")
            if legacy {
                account.credentialNamespaceID = nil
                #expect(account.restorePreviouslyStoredCredential(key: "API_TOKEN", value: "accepted-account-token"))
                try env.disk.context.save()
            }
            let task = AgentTask(title: "Queued account", goal: "Use the accepted account", workspace: env.disk.workspace)
            env.disk.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [env.package])
            env.disk.context.insert(request)
            try env.disk.context.save()
            let frozen = try #require(request.executionPolicySnapshot?.pluginAccounts?.first)
            let current = try env.enable("current-account-token")
            #expect(current.id == account.id)
            #expect(current.currentCredentialValue(forKey: "API_TOKEN") == "current-account-token")
            #expect(frozen.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "accepted-account-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            _ = journal.resumePending(modelContext: env.disk.context)
            #expect(frozen.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "accepted-account-token")
            request.state = .completed
            request.terminalAt = Date()
            try env.disk.context.save()
            _ = journal.resumePending(modelContext: env.disk.context)
            #expect(frozen.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(current.currentCredentialValue(forKey: "API_TOKEN") == "current-account-token")
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("Before a failed Add save, the saved account still reads its prior credential")
    func failedAddNeverOverwritesTheSavedAccount() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("saved-account-token")
            var observedBeforeCommit: String?
            #expect(throws: (any Error).self) {
                try env.disk.installer.enable(env.package, in: env.disk.workspace, modelContext: env.disk.context,
                    credentialInputs: ["API_TOKEN": "uncommitted-account-token"], persist: { _, context in
                        let savedContext = ModelContext(context.container)
                        let saved = try! savedContext.fetch(FetchDescriptor<Connector>()).first { $0.id == account.id }!
                        observedBeforeCommit = saved.currentCredentialValue(forKey: "API_TOKEN")
                        return false
                    })
            }
            #expect(observedBeforeCommit == "saved-account-token")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "saved-account-token")
        }
    }

    @Test("A producer lease excludes collection in this process and another process, then orphan recovery is safe")
    func stagedGenerationCannotBeCollectedBeforePublication() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("held-source-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            var prepared: ConnectorCredentialGenerationTransaction? = try .prepare(account: account, isNew: false,
                keeping: ["API_TOKEN"], replacing: [], modelContext: env.disk.context)
            let namespace = try #require(prepared?.namespaceID)
            let stagedAccount = PluginAccountRecord(account).makeAccount()
            stagedAccount.credentialNamespaceID = namespace
            #expect(stagedAccount.currentCredentialValue(forKey: "API_TOKEN") == "held-source-token")
            #expect(journal.resumePending(modelContext: env.disk.context) == 0)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-I", "-c", """
            import fcntl, sys
            with open(sys.argv[1], 'r+') as f:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    sys.exit(23)
                sys.exit(0)
            """, journal.fileURL.appendingPathExtension("lock").path]
            try child.run()
            child.waitUntilExit()
            #expect(child.terminationStatus == 23)
            #expect(stagedAccount.currentCredentialValue(forKey: "API_TOKEN") == "held-source-token")
            withExtendedLifetime(prepared) {}
            prepared = nil // Simulated producer exit, before a domain cutover.
            #expect(journal.resumePending(modelContext: env.disk.context) > 0)
            #expect(stagedAccount.currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "held-source-token")
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("A committed account generation survives a mirror failure and recovers after reopening")
    func mirrorFailureRecoversForward() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("previous-mirror-token")
            let old = PluginAccountRecord(account)
            var operationID: UUID?
            do {
                try env.disk.installer.enable(env.package, in: env.disk.workspace, modelContext: env.disk.context,
                    credentialInputs: ["API_TOKEN": "saved-mirror-token"], rewriteMirror: { _ in false })
                Issue.record("Saved Add must report pending mirror recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "API_TOKEN") == "saved-mirror-token")
            #expect(old.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "previous-mirror-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: reopened.mainContext))
            #expect(journal.resumePending(modelContext: reopened.mainContext) == 0)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
            #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext).completed == 1)
            _ = journal.resumePending(modelContext: reopened.mainContext)
            #expect(saved.currentCredentialValue(forKey: "API_TOKEN") == "saved-mirror-token")
            #expect(old.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(try journal.pending().isEmpty)
            let metadata = try String(contentsOf: journal.fileURL, encoding: .utf8)
            #expect(!metadata.contains("previous-mirror-token") && !metadata.contains("saved-mirror-token"))
        }
    }

    @Test("Replacing one credential preserves the account's other configured keys through collection")
    func replacementPreservesOtherAccountCredentials() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("first-token")
            #expect(account.saveCredentialChecked(key: "SECOND_TOKEN", value: "retained-extra-token").isSaved)
            try env.disk.context.save()
            let current = try env.enable("replacement-token")
            #expect(current.credentialKeys.contains("SECOND_TOKEN"))
            #expect(current.currentCredentialValue(forKey: "SECOND_TOKEN") == "retained-extra-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            _ = journal.resumePending(modelContext: env.disk.context)
            #expect(current.currentCredentialValue(forKey: "SECOND_TOKEN") == "retained-extra-token")
        }
    }

    @Test("Collection waits for a complete recovery scan", arguments: [
        WorkspaceRecoveryTrust.State.pending, .vouchedWithoutScan, .untrusted
    ])
    func collectionWaitsForTrustedRecovery(state: WorkspaceRecoveryTrust.State) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("scan-source-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            var prepared: ConnectorCredentialGenerationTransaction? = try .prepare(account: account, isNew: false,
                keeping: ["API_TOKEN"], replacing: [], modelContext: env.disk.context)
            let orphan = PluginAccountRecord(account).makeAccount()
            orphan.credentialNamespaceID = try #require(prepared?.namespaceID)
            withExtendedLifetime(prepared) {}
            prepared = nil
            let pending = try journal.pending()
            #expect(ConnectorCredentialGenerationJournal.requiresRecoveryScan(modelContext: env.disk.context))
            let previousTrust = WorkspaceRecoveryTrust.state
            defer { WorkspaceRecoveryTrust.set(previousTrust) }
            WorkspaceRecoveryTrust.set(state)
            #expect(journal.resumePending(modelContext: env.disk.context) == 0)
            #expect(try journal.pending() == pending)
            #expect(orphan.currentCredentialValue(forKey: "API_TOKEN") == "scan-source-token")
            WorkspaceRecoveryTrust.set(.trusted)
            #expect(journal.resumePending(modelContext: env.disk.context) > 0)
            #expect(orphan.currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "scan-source-token")
            #expect(!ConnectorCredentialGenerationJournal.requiresRecoveryScan(modelContext: env.disk.context))
        }
    }

    @Test("Absent recovery metadata needs no scan, but unreadable metadata forces one without changing credentials")
    func unreadableJournalRequiresRecoveryScan() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            #expect(!ConnectorCredentialGenerationJournal.requiresRecoveryScan(modelContext: env.disk.context))
            let account = try env.enable("unreadable-record-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            try Data("invalid-recovery-metadata".utf8).write(to: journal.fileURL)
            #expect(ConnectorCredentialGenerationJournal.requiresRecoveryScan(modelContext: env.disk.context))
            ConnectorCredentialGenerationJournal.resumeAfterWorkspaceRecovery(modelContext: env.disk.context)
            #expect(try String(contentsOf: journal.fileURL, encoding: .utf8) == "invalid-recovery-metadata")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "unreadable-record-token")
        }
    }

    @Test("Production runtime copies read the current generation and detached queued copies read the accepted generation")
    func runtimeCopiesPreserveCredentialGeneration() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("accepted-runtime-token")
            let task = AgentTask(title: "Queued runtime", goal: "Use submitted credentials", workspace: env.disk.workspace)
            env.disk.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [env.package])
            env.disk.context.insert(request)
            try env.disk.context.save()
            let accepted = try #require(request.executionPolicySnapshot?.pluginAccounts?.first)
            _ = try env.enable("current-runtime-token")
            let projection = PluginRuntimeProjection.project(workspace: env.disk.workspace,
                packages: [env.package], connectorMode: .runtimeCopies, definitions: [env.package])
            let live = try #require(projection.connectors.first { $0.id == account.id })
            #expect(live.credentialNamespaceID == account.credentialNamespaceID)
            #expect(live.currentCredentialValue(forKey: "API_TOKEN") == "current-runtime-token")
            let queued = TaskExecutionLaunchSnapshotApplicator.detachedConnector(accepted.makeAccount())
            #expect(queued.credentialNamespaceID == accepted.credentialNamespaceID)
            #expect(queued.currentCredentialValue(forKey: "API_TOKEN") == "accepted-runtime-token")
            let environment = ConnectorRuntimeProjection(connectors: [live], secretStore: KeychainSecretStore(),
                credentialExposurePolicy: .allowAllCredentials).environmentVariables()
            #expect(environment.values.contains("current-runtime-token"))
            #expect(!environment.values.contains("accepted-runtime-token"))
        }
    }

    @MainActor
    private struct Fixture {
        let disk: PluginAddCommitTests.Fixture
        let package: PluginPackage
        init() throws {
            disk = try PluginAddCommitTests.Fixture(installed: false)
            var definition = disk.package
            definition.connectors = [PluginConnector(name: "Generation API", serviceType: "custom", icon: "network",
                description: "An isolated account", baseURL: "https://api.example.com", authMethod: "bearer",
                credentialHints: [.init(key: "API_TOKEN", hint: "API token")], configHints: [], notes: "")]
            package = definition
        }
        func enable(_ token: String) throws -> Connector {
            try disk.installer.enable(package, in: disk.workspace, modelContext: disk.context,
                credentialInputs: ["API_TOKEN": token])
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: disk.workspace))
            return try #require(activation.accounts(forComponent: CapabilityResourceOrigin.componentID(for: package.connectors[0])).first)
        }
    }

}
