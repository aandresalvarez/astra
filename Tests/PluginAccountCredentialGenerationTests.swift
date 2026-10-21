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

    @Test("Migrating legacy endpoint and name keeps current and queued credential generations")
    func legacyStructureMigrationKeepsCredentials() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("legacy-structure-token")
            account.credentialNamespaceID = nil
            account.name = ""
            account.baseURL = ""
            #expect(account.restorePreviouslyStoredCredential(key: "API_TOKEN", value: "legacy-structure-token"))
            // Historical stores can hold only the endpoint alias. A modern
            // UUID backfill would hide loss when that endpoint changes.
            let store = KeychainSecretStore()
            #expect(store.delete(key: "API_TOKEN", entityID: KeychainSecretStore.connectorEntityID(for: account.id)))
            try #require(account.currentCredentialValue(forKey: "API_TOKEN") == "legacy-structure-token")
            account.configKeys += ["ENDPOINT", "ACCOUNT_NAME"]
            account.configValues += ["https://restored.example.com", "Restored account"]
            try env.disk.context.save()
            let task = AgentTask(title: "Queued legacy account", goal: "Use the accepted account", workspace: env.disk.workspace)
            env.disk.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [env.package])
            env.disk.context.insert(request)
            try env.disk.context.save()
            let frozen = try #require(request.executionPolicySnapshot?.pluginAccounts?.first)
            var updated = env.package
            updated.version = "2.0.0"
            updated.connectors[0].configHints = [
                .init(key: "ENDPOINT", hint: "Endpoint", isList: false, storage: PluginConnector.ConfigHint.accountBaseURL),
                .init(key: "ACCOUNT_NAME", hint: "Name", isList: false, storage: PluginConnector.ConfigHint.accountAlias)
            ]
            _ = try PluginUpdateService.reconcileAll(modelContext: env.disk.context, packages: [updated], mode: .release,
                approvalRecords: PluginOperationsTests.approvals([updated]))
            #expect(account.baseURL == "https://restored.example.com")
            #expect(account.name == "Restored account")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "legacy-structure-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            _ = journal.resumePending(modelContext: env.disk.context)
            #expect(frozen.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "legacy-structure-token")
            request.state = .completed
            request.terminalAt = Date()
            try env.disk.context.save()
            _ = journal.resumePending(modelContext: env.disk.context)
            #expect(frozen.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "legacy-structure-token")
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

    @Test("Add migrates an unmigrated account credential without dropping it", arguments: [false, true])
    func addPreservesLegacyPlainCredential(replaceAnother: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("existing-api-token")
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("legacy-second-token")
            try env.disk.context.save()
            let originalNamespace = account.credentialNamespaceID
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
            try env.disk.installer.enable(env.package, in: env.disk.workspace, modelContext: env.disk.context,
                credentialInputs: replaceAnother ? ["API_TOKEN": "replacement-api-token"] : [:])
            #expect(account.id == env.disk.workspace.connectors.first?.id)
            #expect(account.credentialNamespaceID != originalNamespace)
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == "legacy-second-token")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == (replaceAnother ? "replacement-api-token" : "existing-api-token"))
            #expect(!account.credentialValues.contains("legacy-second-token"))
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "SECOND_TOKEN") == "legacy-second-token")
        }
    }

    @Test("Rejected legacy plaintext leaves the saved account and credential untouched")
    func legacyAdmissionRefusalKeepsOriginalState() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("before-rejected-migration")
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("your-token-here")
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                try env.disk.installer.enable(env.package, in: env.disk.workspace, modelContext: env.disk.context)
            }
            let saved = try #require(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).first)
            #expect(account.credentialNamespaceID == namespace && saved.credentialNamespaceID == namespace)
            #expect(saved.credentialValues.contains("your-token-here"))
            #expect(account.credentialValues.contains("your-token-here"))
            #expect(saved.currentCredentialValue(forKey: "API_TOKEN") == "before-rejected-migration")
            #expect(saved.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.disk.context))
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("A migration that fails its domain save preserves the original plaintext before and after rollback")
    func failedLegacyMigrationKeepsSavedSource() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("before-unsaved-migration")
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("unmigrated-second-token")
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            var observedPlaintext: [String] = []
            #expect(throws: (any Error).self) {
                try env.disk.installer.enable(env.package, in: env.disk.workspace, modelContext: env.disk.context,
                    persist: { _, context in
                        let saved = try! ModelContext(context.container).fetch(FetchDescriptor<Connector>()).first!
                        observedPlaintext = saved.credentialValues
                        #expect(saved.credentialNamespaceID == namespace)
                        #expect(saved.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
                        return false
                    })
            }
            #expect(observedPlaintext.contains("unmigrated-second-token"))
            #expect(account.credentialValues.contains("unmigrated-second-token"))
            #expect(account.credentialNamespaceID == namespace)
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.credentialValues.contains("unmigrated-second-token"))
            #expect(saved.currentCredentialValue(forKey: "API_TOKEN") == "before-unsaved-migration")
        }
    }

    @Test("A newer vault credential wins over stale legacy plaintext without admitting the stale value")
    func newerVaultValueWinsOverLegacyPlaintext() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("before-newer-migration")
            #expect(account.saveCredentialChecked(key: "SECOND_TOKEN", value: "accepted-newer-second-token").isSaved)
            let index = try #require(account.credentialKeys.firstIndex(of: "SECOND_TOKEN"))
            account.credentialValues[index] = "your-token-here"
            try env.disk.context.save()
            _ = try env.enable("after-newer-migration")
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == "accepted-newer-second-token")
            #expect(!account.credentialValues.contains("your-token-here"))
        }
    }

    @Test("Legacy plaintext must satisfy the definition being accepted, even before it is installed")
    func legacyMigrationUsesAcceptedFormat() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("before-format-migration")
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("legacy-second-token")
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            var strict = env.package
            strict.version = "2.0.0"
            strict.connectors[0].credentialHints.append(.init(key: "SECOND_TOKEN", hint: "Second token",
                format: .init(pattern: "[A-F0-9]{32}", expectation: "32 hexadecimal characters")))
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                try env.disk.installer.enable(strict, in: env.disk.workspace, modelContext: env.disk.context)
            }
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.credentialValues.contains("legacy-second-token"))
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
        }
    }

    @Test("A valid legacy credential is normalized and admitted under the accepted format")
    func legacyMigrationAcceptsTheDeclaredFormat() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("before-valid-format")
            let expected = "A19F2C8D4B6E7A03C5D9F1B2468E0A7C"
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("  " + expected + "\n")
            try env.disk.context.save()
            var strict = env.package
            strict.version = "2.0.0"
            strict.connectors[0].credentialHints.append(.init(key: "SECOND_TOKEN", hint: "Second token",
                format: .init(pattern: "[A-F0-9]{32}", expectation: "32 hexadecimal characters")))
            try env.disk.installer.enable(strict, in: env.disk.workspace, modelContext: env.disk.context)
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == expected)
            #expect(account.credentialValues.allSatisfy { $0.isEmpty })
            let saved = try #require(try ModelContext(env.disk.context.container).fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "SECOND_TOKEN") == expected)
            #expect(saved.credentialValues.allSatisfy { $0.isEmpty })
        }
    }

    @Test("One account bound to two components must satisfy both accepted credential formats")
    func sharedAccountUsesEveryDeclaredFormat() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            var initial = env.package
            initial.connectors[0].id = "first-api"
            var second = initial.connectors[0]
            second.id = "second-api"
            second.name = "Second API"
            initial.connectors.append(second)
            try env.disk.installer.enable(initial, in: env.disk.workspace, modelContext: env.disk.context,
                credentialInputs: ["API_TOKEN": "shared-account-api-token"])
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: initial.id, in: env.disk.workspace))
            let firstID = CapabilityResourceOrigin.componentID(for: initial.connectors[0])
            let secondID = CapabilityResourceOrigin.componentID(for: initial.connectors[1])
            let account = try #require(activation.accounts(forComponent: firstID).first)
            let secondAccount = try #require(activation.accounts(forComponent: secondID).first)
            WorkspaceCapabilityActivation.unbind(secondAccount, from: activation, componentID: secondID)
            WorkspaceCapabilityActivation.bind(account, toComponent: secondID, of: activation, isDefault: true)
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("legacy-second-token")
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            var strict = initial
            strict.version = "2.0.0"
            strict.connectors[0].credentialHints.append(.init(key: "SECOND_TOKEN", hint: "First constraint",
                format: .init(pattern: ".+", expectation: "a nonempty token")))
            strict.connectors[1].credentialHints.append(.init(key: "SECOND_TOKEN", hint: "Second constraint",
                format: .init(pattern: "[A-F0-9]{32}", expectation: "32 hexadecimal characters")))
            let plan = PluginAccountCredentialCutoverPlan.candidates(for: strict, activation: activation)
            #expect(plan.count == 1)
            #expect(plan.first?.formats["SECOND_TOKEN"]?.count == 2)
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                try env.disk.installer.enable(strict, in: env.disk.workspace, modelContext: env.disk.context)
            }
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.credentialValues.contains("legacy-second-token"))
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "shared-account-api-token")
        }
    }


    @Test("Add admits a valid raw setting into its private generation before publishing it", arguments: ["PROJECT", "project"])
    func addMigratesValidLegacySetting(storedKey: String) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("before-valid-setting-migration")
            account.configKeys = [storedKey]
            account.configValues = ["  ENG-4242  "]
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            var accepted = env.package
            accepted.version = "2.0.0"
            accepted.connectors[0].configHints = [.init(key: "PROJECT", hint: "Project", isList: false)]
            _ = try env.disk.installer.enable(accepted, in: env.disk.workspace, modelContext: env.disk.context)
            #expect(account.credentialNamespaceID != namespace)
            #expect(account.configKeys.isEmpty)
            // An opaque value keeps significant spaces; only a declared
            // format or known issuer permits trimming its storage form.
            #expect(account.currentCredentialValue(forKey: "PROJECT") == "  ENG-4242  ")
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "before-valid-setting-migration")
        }
    }

    @Test("Add cannot promote an invalid legacy plain setting without admission")
    func addRejectsInvalidLegacySetting() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable("before-legacy-setting-migration")
            account.configKeys = ["PROJECT"]
            account.configValues = ["your-token-here"]
            try env.disk.context.save()
            let namespace = account.credentialNamespaceID
            var accepted = env.package
            accepted.version = "2.0.0"
            accepted.connectors[0].configHints = [.init(key: "PROJECT", hint: "Project", isList: false)]
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                try env.disk.installer.enable(accepted, in: env.disk.workspace, modelContext: env.disk.context)
            }
            #expect(account.credentialNamespaceID == namespace)
            #expect(account.configValues == ["your-token-here"])
            #expect(account.currentCredentialValue(forKey: "PROJECT") == nil)
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
