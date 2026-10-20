import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Durable authored skill legacy migration", .serialized)
struct SkillCredentialMigrationTests {
    @Test("Startup publishes a saved private generation and receipt before clearing legacy skill values")
    func startupCutoverIsDurable() throws {
        try withSkill { env, skill in
            let previousNamespace = skill.secretNamespaceID
            StartupCredentialMigrationService.migrate(modelContext: env.context)
            let saved = ModelContext(env.context.container)
            let row = try #require(try saved.fetch(FetchDescriptor<Skill>()).first)
            #expect(row.credentialNamespaceID != nil)
            #expect(row.secretNamespaceID != previousNamespace)
            #expect(row.environmentValues == ["", "west"])
            #expect(row.environmentVariables["API_TOKEN"] == "legacy-startup-synthetic-token")
            #expect(try saved.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 1)
            #expect(!env.context.hasChanges)
            let namespace = row.secretNamespaceID
            #expect(try !SkillCredentialMigration.migrate(skill, modelContext: env.context))
            #expect(skill.secretNamespaceID == namespace)
            #expect(try saved.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 1)
            #expect(!env.context.hasChanges)
        }
    }

    @Test("A callback without a saved receipt keeps the original plaintext and namespace after reopening")
    func noncommitPreservesLegacyState() throws {
        try withSkill { env, skill in
            let namespace = skill.secretNamespaceID
            #expect(throws: SkillCredentialEditor.Failure.saveFailed) {
                _ = try SkillCredentialMigration.migrate(skill, modelContext: env.context, persist: { _ in })
            }
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).first)
            #expect(saved.secretNamespaceID == namespace)
            #expect(saved.environmentValues == ["legacy-startup-synthetic-token", "west"])
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace, store: KeychainSecretStore()) == nil)
        }
    }

    @Test("Saved migrations recover the same receipt without replay after reopening", arguments: [false, true])
    func savedMigrationRecoversForward(reportedFailure: Bool) throws {
        try withSkill { env, skill in
            enum ReportedFailure: Error { case saved }
            var operationID: UUID?
            do {
                _ = try SkillCredentialMigration.migrate(skill, modelContext: env.context, persist: { context in
                    try context.save()
                    if reportedFailure { throw ReportedFailure.saved }
                }, rewriteMirror: { _ in false })
                Issue.record("The committed migration must report mirror recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let namespace = skill.secretNamespaceID
            do {
                _ = try SkillCredentialMigration.migrate(skill, modelContext: env.context)
                Issue.record("A repeated migration must preserve the existing recovery action")
            } catch let problem as PluginOperationProblem { #expect(problem.operationID == id) }
            #expect(try PluginOperationCommit.read(id, container: env.context.container)?.completedAt == nil)
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).first)
            #expect(saved.secretNamespaceID == namespace)
            #expect(saved.environmentValues == ["", "west"])
            #expect(saved.environmentVariables["API_TOKEN"] == "legacy-startup-synthetic-token")
            try SkillCredentialEditor.recover(id, modelContext: reopened.mainContext)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 1)
            #expect(saved.secretNamespaceID == namespace)
        }
    }

    @Test("An accepted vault value wins over stale plaintext and remains available to the real queued launch")
    func queuedCredentialAndOpaqueValuesStayIntact() throws {
        let opaque = "  first line\nsecond line\n "
        try withSkill(keys: ["API_TOKEN", "SECOND_SECRET", "REGION"], values: ["stale-raw-token", opaque, "west"]) { env, skill in
            let original = skill.secretNamespaceID
            try #require(SkillSecretSeam.required.saveSecretValue("accepted-queued-startup-token", key: "API_TOKEN",
                skillID: original, skillName: skill.name, allowUserInteraction: false))
            let task = AgentTask(title: "Accepted startup skill", goal: "Retain the accepted credential", workspace: env.workspace)
            task.skills = [skill]
            env.context.insert(task)
            TaskCapabilitySnapshotCapture.capture(for: task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let before = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            try #require(TaskCapabilityResolver(task: before).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-queued-startup-token")
            #expect(try SkillCredentialMigration.migrate(skill, modelContext: env.context))
            #expect(skill.secretNamespaceID != original)
            #expect(skill.environmentVariables["API_TOKEN"] == "accepted-queued-startup-token")
            #expect(skill.environmentVariables["SECOND_SECRET"] == opaque)
            #expect(skill.environmentValues == ["", "", "west"])
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(TaskCapabilityResolver(task: launch).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-queued-startup-token")
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: original, store: KeychainSecretStore()) == "accepted-queued-startup-token")
            #expect(SkillSecretSeam.required.loadSecretValue(key: "SECOND_SECRET", skillID: original, store: KeychainSecretStore()) == nil)
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            try journal.resumePending(modelContext: env.context)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: original, store: KeychainSecretStore()) == "accepted-queued-startup-token")
        }
    }

    @Test("Ambiguous legacy arrays are preserved without staging credentials", arguments: [0, 1, 2])
    func malformedLegacyValuesAreNotGuessed(shape: Int) throws {
        let keys = shape == 0 ? ["API_TOKEN", "api_token"] : (shape == 1 ? ["REGION"] : [" API_TOKEN"])
        let values = shape == 0 ? ["first-synthetic-token", "second-synthetic-token"] : (shape == 1 ? ["west", "unlabelled-synthetic-token"] : ["space-key-synthetic-token"])
        try withSkill(keys: keys, values: values) { env, skill in
            let namespace = skill.secretNamespaceID
            #expect(throws: SkillCredentialEditor.Failure.legacyFieldsNeedReview) {
                _ = try SkillCredentialMigration.migrate(skill, modelContext: env.context)
            }
            #expect(skill.environmentKeys == keys)
            #expect(skill.environmentValues == values)
            #expect(skill.secretNamespaceID == namespace)
            #expect(try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            #expect(try journal.pending().isEmpty)
            #expect(!env.context.hasChanges)
        }
    }

    @Test("Unrelated dirty metadata and unavailable vaults preserve legacy values")
    func unsafeAdmissionCannotClearValues() throws {
        try withSkill { env, skill in
            env.workspace.name = "Unsaved unrelated workspace"
            #expect(throws: SkillCredentialEditor.Failure.pendingEdits) {
                _ = try SkillCredentialMigration.migrate(skill, modelContext: env.context)
            }
            #expect(env.workspace.name == "Unsaved unrelated workspace")
            env.context.rollback()
            let bad = env.disk.root.appendingPathComponent("unreadable-startup-vault")
            try Data("not a vault".utf8).write(to: bad)
            try AstraSecureKeychainStore.$keychainPathOverride.withValue(bad.path) {
                #expect(throws: SkillCredentialEditor.Failure.secretReadFailed) {
                    _ = try SkillCredentialMigration.migrate(skill, modelContext: env.context)
                }
            }
            #expect(skill.environmentValues == ["legacy-startup-synthetic-token", "west"])
            #expect(skill.credentialNamespaceID == nil)
            #expect(try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
        }
    }

    @Test("Migration receipts include former consumers' recovery mirrors")
    func receiptsCoverAllKnownMirrors() throws {
        try withSkill { env, skill in
            let folder = env.disk.root.appendingPathComponent("former-startup-consumer")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let former = Workspace(name: "Former startup consumer", primaryPath: folder.path)
            env.context.insert(former)
            try env.context.save()
            #expect(try SkillCredentialMigration.migrate(skill, modelContext: env.context))
            let receipt = try #require(try env.context.fetch(FetchDescriptor<PluginOperationReceipt>()).first)
            let saved = try #require(try PluginOperationCommit.read(receipt.id, container: env.context.container))
            #expect(Set(saved.workspaceIDs) == [env.workspace.id, former.id])
        }
    }

    private func withSkill(keys: [String] = ["API_TOKEN", "REGION"],
                           values: [String] = ["legacy-startup-synthetic-token", "west"],
                           _ body: (PluginAddCommitTests.Fixture, Skill) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Legacy authored startup")
            skill.environmentKeys = keys
            skill.environmentValues = values
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            try body(env, skill)
        }
    }
}
