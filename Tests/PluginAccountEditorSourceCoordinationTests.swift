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
    @Test("An unrelated source mutation excludes authored skill secret edits", arguments: [false, true])
    func sourceMutationExcludesSkillEdits(removing: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Source-locked skill", environmentVariables: ["API_TOKEN": "accepted-skill-source-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            let namespace = skill.secretNamespaceID
            try PluginSourceStore().exclusively(pluginID: "unrelated-source") {
                #expect(throws: PluginSourceStoreError.libraryBusy) {
                    if removing { try SkillCredentialEditor.remove("API_TOKEN", from: skill, modelContext: env.context) }
                    else { try SkillCredentialEditor.save("must-not-stage", forKey: "API_TOKEN", on: skill, modelContext: env.context) }
                }
            }
            #expect(skill.secretNamespaceID == namespace)
            #expect(skill.environmentVariables["API_TOKEN"] == "accepted-skill-source-token")
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("Finishing a skill edit's recovery respects the source lock and remains retryable")
    func skillRecoveryRespectsSourceMutationLock() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Skill recovery", environmentVariables: ["API_TOKEN": "accepted-skill-source-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            var operationID: UUID?
            do {
                try SkillCredentialEditor.save("pending-skill-source-token", forKey: "API_TOKEN", on: skill,
                    modelContext: env.context, rewriteMirror: { _ in false })
                Issue.record("Saved change must owe recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let namespace = skill.secretNamespaceID
            try PluginSourceStore().exclusively(pluginID: "unrelated-source") {
                #expect(throws: PluginSourceStoreError.libraryBusy) {
                    try SkillCredentialEditor.recover(id, modelContext: env.context)
                }
                let pending = try PluginOperationCommit.read(id, container: env.context.container)
                #expect(pending?.completedAt == nil)
            }
            try SkillCredentialEditor.recover(id, modelContext: env.context)
            #expect(try PluginOperationCommit.read(id, container: env.context.container)?.completedAt != nil)
            #expect(skill.secretNamespaceID == namespace)
            #expect(skill.environmentVariables["API_TOKEN"] == "pending-skill-source-token")
        }
    }


    @Test("An unrelated source mutation excludes skill retirement before deletion or secret collection")
    func sourceMutationExcludesSkillRetirement() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Source-locked retirement", environmentVariables: ["API_TOKEN": "accepted-retirement-source-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            let namespace = skill.secretNamespaceID
            try PluginSourceStore().exclusively(pluginID: "unrelated-source") {
                #expect(throws: PluginSourceStoreError.libraryBusy) {
                    try SkillRetirement.remove(skill, modelContext: env.context)
                }
            }
            // Read saved rows, never fields on a model the old path deletes.
            let saved = ModelContext(env.context.container)
            #expect(try saved.fetchCount(FetchDescriptor<Skill>()) == 1)
            #expect(try saved.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-retirement-source-token")
        }
    }

    @Test("Delete preserves an outstanding skill edit's receipt instead of completing and replaying it")
    func retirementCannotReplayPendingEdit() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Pending skill retirement", environmentVariables: ["API_TOKEN": "accepted-retirement-source-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            var operationID: UUID?
            do {
                try SkillCredentialEditor.save("pending-retirement-source-token", forKey: "API_TOKEN", on: skill,
                    modelContext: env.context, rewriteMirror: { _ in false })
                Issue.record("The saved edit must report its recovery receipt")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            do {
                try SkillRetirement.remove(skill, modelContext: env.context)
                Issue.record("Delete must retain the original pending edit")
            } catch let problem as PluginOperationProblem {
                if case .savedRecoveryPending(let actualID) = problem { #expect(actualID == id) }
                else { Issue.record("Delete must retain the saved-recovery state") }
            }
            let saved = ModelContext(env.context.container)
            #expect(try saved.fetchCount(FetchDescriptor<Skill>()) == 1)
            #expect(try saved.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 1)
            #expect(try PluginOperationCommit.read(id, container: env.context.container)?.completedAt == nil)
            #expect(skill.environmentVariables["API_TOKEN"] == "pending-retirement-source-token")
        }
    }

}
