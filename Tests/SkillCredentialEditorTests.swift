import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Authored skill credential edits preserve queued requests", .serialized)
struct SkillCredentialEditorTests {
    @Test("Replacing or removing an authored skill secret preserves the actual queued launch", arguments: [false, true], [false, true])
    func queuedLaunchKeepsAcceptedSecret(removing: Bool, legacyNamespace: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Authored secret", environmentVariables: ["API_TOKEN": "accepted-authored-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            if !legacyNamespace {
                try SkillCredentialEditor.save("accepted-authored-token", forKey: "API_TOKEN", on: skill, modelContext: env.context)
            }
            let task = AgentTask(title: "Queued authored skill", goal: "Keep accepted secret", workspace: env.workspace)
            task.skills = [skill]
            env.context.insert(task)
            TaskCapabilitySnapshotCapture.capture(for: task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let before = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            try #require(TaskCapabilityResolver(task: before).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-authored-token")
            let namespace = skill.secretNamespaceID
            #expect(PendingTaskCredentialReferences.capture(modelContext: env.context)?.holdsSkill(namespace, key: "API_TOKEN") == true)
            if removing {
                try SkillCredentialEditor.remove("API_TOKEN", from: skill, modelContext: env.context)
            } else {
                try SkillCredentialEditor.save("replacement-authored-token", forKey: "API_TOKEN", on: skill, modelContext: env.context)
            }
            let queued = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            #expect(TaskCapabilityResolver(task: queued).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(TaskCapabilityResolver(task: queued).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(skill.environmentVariables["API_TOKEN"] == (removing ? nil : "replacement-authored-token"))
            #expect(skill.secretNamespaceID != namespace)
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            try journal.resumePending(modelContext: env.context)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-authored-token")
            // The task's saved snapshot is itself a consumer even after the
            // request finishes. Release both before collecting its generation.
            request.state = .completed
            request.terminalAt = Date()
            task.skillSnapshots = []
            try env.context.save()
            try journal.resumePending(modelContext: env.context)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == nil)
            #expect(skill.environmentVariables["API_TOKEN"] == (removing ? nil : "replacement-authored-token"))
        }
    }

    @Test("Opaque multiline secrets and other settings survive an independent generation")
    func opaqueValuesAndRetainedSecrets() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let opaque = "  first line\nsecond line\n "
            #expect(env.skill.upsertEnvironmentEntry(key: "SECOND_SECRET", value: opaque))
            env.skill.upsertEnvironmentEntry(key: "REGION", value: "west")
            try env.context.save()
            try SkillCredentialEditor.save(opaque, forKey: "API_TOKEN", on: env.skill, modelContext: env.context)
            #expect(env.skill.environmentVariables["API_TOKEN"] == opaque)
            #expect(env.skill.environmentVariables["SECOND_SECRET"] == opaque)
            #expect(env.skill.environmentVariables["REGION"] == "west")
            #expect(!env.skill.environmentValues.contains(opaque))
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).first)
            #expect(saved.credentialNamespaceID == env.skill.credentialNamespaceID)
            #expect(saved.environmentVariables["SECOND_SECRET"] == opaque)
        }
    }

    @Test("A callback without a durable save preserves the prior secret before and after reopening", arguments: [false, true])
    func successNeedsSavedReceipt(removing: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let namespace = env.skill.secretNamespaceID
            var observed: String?
            let persist: (ModelContext) throws -> Void = { context in
                let saved = try #require(try ModelContext(context.container).fetch(FetchDescriptor<Skill>()).first)
                observed = saved.environmentVariables["API_TOKEN"]
            }
            #expect(throws: SkillCredentialEditor.Failure.self) {
                if removing {
                    try SkillCredentialEditor.remove("API_TOKEN", from: env.skill, modelContext: env.context, persist: persist)
                } else {
                    try SkillCredentialEditor.save("unsaved-token", forKey: "API_TOKEN", on: env.skill, modelContext: env.context, persist: persist)
                }
            }
            #expect(observed == "accepted-authored-token")
            #expect(env.skill.secretNamespaceID == namespace)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-authored-token")
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).first)
            #expect(saved.secretNamespaceID == namespace)
            #expect(saved.environmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginOperationReceipt>()).isEmpty)
            #expect(!env.context.hasChanges)
            try SkillCredentialEditor.save("corrected-token", forKey: "API_TOKEN", on: env.skill, modelContext: env.context)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "corrected-token")
        }
    }

    @Test("A saved failure recovers the same receipt after reopening without replay", arguments: [false, true])
    func savedFailuresRecoverForward(reportedFailure: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            enum SaveFailure: Error { case reported }
            var operationID: UUID?
            do {
                try SkillCredentialEditor.save("committed-authored-token", forKey: "API_TOKEN", on: env.skill, modelContext: env.context,
                    persist: { context in
                        try context.save()
                        if reportedFailure { throw SaveFailure.reported }
                    }, rewriteMirror: { _ in false })
                Issue.record("Saved failure must retain its receipt")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let namespace = env.skill.secretNamespaceID
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            let candidates = try journal.pending()
            let reopened = try env.disk.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).first)
            #expect(saved.environmentVariables["API_TOKEN"] == "committed-authored-token")
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
            var repeatedProblem: PluginOperationProblem?
            do {
                try SkillCredentialEditor.save("must-not-replay", forKey: "API_TOKEN", on: saved, modelContext: reopened.mainContext)
                Issue.record("A pending saved edit must not repeat its write")
            } catch let problem as PluginOperationProblem { repeatedProblem = problem }
            catch { Issue.record("The original recovery action was lost: \(type(of: error))") }
            #expect(repeatedProblem?.operationID == id)
            try SkillCredentialEditor.recover(id, modelContext: reopened.mainContext)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
            #expect(saved.secretNamespaceID == namespace)
            #expect(saved.environmentVariables["API_TOKEN"] == "committed-authored-token")
            #expect(try journal.pending() == candidates)
            #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginOperationReceipt>()).count == 1)
        }
    }

    @Test("A staged generation excludes collection in this process and another process")
    func unpublishedGenerationSurvivesCollection() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            var prepared: SkillCredentialGenerationTransaction? = try .prepare(skill: env.skill, replacing: "API_TOKEN",
                with: "private-not-yet-published", modelContext: env.context)
            let namespace = try #require(prepared?.namespaceID)
            func stagedValue() -> String? {
                SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace, store: KeychainSecretStore())
            }
            #expect(stagedValue() == "private-not-yet-published")
            try journal.resumePending(modelContext: env.context)
            #expect(stagedValue() == "private-not-yet-published")
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
            #expect(throws: (any Error).self) {
                try SkillCredentialEditor.save("concurrent-write", forKey: "API_TOKEN", on: env.skill, modelContext: env.context)
            }
            withExtendedLifetime(prepared) {}
            prepared = nil // Exit before publishing, leaving only the durable intent.
            try journal.resumePending(modelContext: env.context)
            #expect(stagedValue() == nil)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("All known workspace mirrors participate, including former skill consumers")
    func allMirrorsRetainedForRecovery() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let path = env.disk.disk.root.appendingPathComponent("former-consumer")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let former = Workspace(name: "Former consumer", primaryPath: path.path)
            env.context.insert(former)
            try env.context.save()
            var visited = Set<UUID>()
            var operationID: UUID?
            do {
                try SkillCredentialEditor.remove("API_TOKEN", from: env.skill, modelContext: env.context,
                    rewriteMirror: { workspace in visited.insert(workspace.id); return workspace.id != former.id })
                Issue.record("A failed former mirror must owe recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let receipt = try #require(try PluginOperationCommit.read(id, container: env.context.container))
            #expect(Set(receipt.workspaceIDs) == [former.id, env.disk.workspace.id])
            #expect(visited == Set(receipt.workspaceIDs))
            #expect(receipt.completedAt == nil)
        }
    }

    @Test("Unrelated dirty edits are neither committed nor rolled back")
    func unrelatedChangesStayUnsaved() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            env.disk.workspace.name = "Unrelated pending name"
            #expect(throws: SkillCredentialEditor.Failure.self) {
                try SkillCredentialEditor.save("must-not-save", forKey: "API_TOKEN", on: env.skill, modelContext: env.context)
            }
            #expect(env.disk.workspace.name == "Unrelated pending name")
            let saved = try #require(try ModelContext(env.context.container).fetch(FetchDescriptor<Workspace>()).first)
            #expect(saved.name != "Unrelated pending name")
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-authored-token")
        }
    }

    @Test("An unreadable retained credential aborts before the skill or journal changes")
    func unreadableVaultRetainsSource() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            #expect(env.skill.upsertEnvironmentEntry(key: "SECOND_SECRET", value: "retained-secret"))
            try env.context.save()
            let namespace = env.skill.secretNamespaceID
            let bad = env.disk.disk.root.appendingPathComponent("not-a-vault")
            try Data("unreadable vault".utf8).write(to: bad)
            try AstraSecureKeychainStore.$keychainPathOverride.withValue(bad.path) {
                #expect(throws: SkillCredentialEditor.Failure.self) {
                    try SkillCredentialEditor.save("must-not-save", forKey: "API_TOKEN", on: env.skill, modelContext: env.context)
                }
            }
            #expect(env.skill.secretNamespaceID == namespace)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-authored-token")
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("Malformed or unrelated raw legacy fields are kept for explicit review", arguments: [false, true])
    func legacyFieldDebtIsNotDiscarded(unlabelled: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            if unlabelled { env.skill.environmentValues.append("unlabelled-secret") }
            else { env.skill.environmentKeys.append("SECOND_SECRET"); env.skill.environmentValues.append("raw-legacy-secret") }
            try env.context.save()
            let values = env.skill.environmentValues
            #expect(throws: SkillCredentialEditor.Failure.self) {
                try SkillCredentialEditor.remove("API_TOKEN", from: env.skill, modelContext: env.context)
            }
            #expect(env.skill.environmentValues == values)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-authored-token")
        }
    }

    @Test("Case aliases of the edited key are settled together", arguments: [false, true])
    func caseAliasesSettleTogether(removing: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            env.skill.environmentKeys.append("api_token")
            env.skill.environmentValues.append("raw-legacy-alias")
            try env.context.save()
            if removing { try SkillCredentialEditor.remove("api_token", from: env.skill, modelContext: env.context) }
            else { try SkillCredentialEditor.save("settled-token", forKey: "api_token", on: env.skill, modelContext: env.context) }
            #expect(!env.skill.environmentKeys.contains("api_token"))
            #expect(!env.skill.environmentValues.contains("raw-legacy-alias"))
            #expect(env.skill.environmentVariables["API_TOKEN"] == (removing ? nil : "settled-token"))
        }
    }

    @Test("Foreign or corrupt generation records block edits and cannot authorize deletion", arguments: [false, true])
    func unreadableJournalDoesNotAdmitMutation(foreign: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            let data = foreign ? try JSONSerialization.data(withJSONObject: ["version": 1, "storeIdentity": "different-store", "namespaces": []])
                : Data("corrupt record".utf8)
            try data.write(to: journal.fileURL)
            let namespace = env.skill.secretNamespaceID
            #expect(SkillCredentialGenerationJournal.requiresRecoveryScan(modelContext: env.context))
            #expect(throws: (any Error).self) {
                try SkillCredentialEditor.remove("API_TOKEN", from: env.skill, modelContext: env.context)
            }
            #expect(throws: (any Error).self) { try journal.resumePending(modelContext: env.context) }
            #expect(env.skill.secretNamespaceID == namespace)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(try Data(contentsOf: journal.fileURL) == data)
        }
    }

    @Test("A plugin override's accepted record wins over an older task skill copy")
    func pluginOverrideRemainsTheCredentialOwner() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            var package = env.disk.package
            let component = PluginSkill(name: "Override component", icon: "puzzlepiece", description: "Synthetic override",
                allowedTools: ["Read"], disallowedTools: [], customTools: [], behaviorInstructions: "Read the synthetic fixture.",
                environmentKeys: [], environmentValues: [])
            package.skills = [component]
            _ = try env.disk.installer.enable(package, in: env.disk.workspace, modelContext: env.context)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.disk.workspace))
            WorkspaceCapabilityActivation.setOverridden(true, componentID: CapabilityResourceOrigin.componentID(for: component),
                rowID: env.skill.id, on: activation)
            env.disk.workspace.launchPluginDefinitions = [package]
            let task = AgentTask(title: "Queued plugin override", goal: "Use the accepted override", workspace: env.disk.workspace)
            task.skills = [env.skill]
            var stale = SkillSnapshotConfig(skill: env.skill)
            stale.credentialNamespaceID = UUID()
            task.skillSnapshots = [stale]
            env.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [package])
            env.context.insert(request)
            try env.context.save()
            try #require(request.executionPolicySnapshot?.pluginOverrides?.skills.contains { $0.id == env.skill.id } == true)
            try #require(TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-authored-token")
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            try SkillCredentialEditor.save("replacement-override-token", forKey: "API_TOKEN", on: env.skill, modelContext: env.context)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            #expect(TaskCapabilityResolver(task: launch).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(TaskCapabilityResolver(task: launch).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(env.skill.environmentVariables["API_TOKEN"] == "replacement-override-token")
        }
    }

    @Test("A refused vault write leaves the saved skill and accepted secret intact")
    func refusedVaultWriteKeepsAcceptedSource() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.disk.disk.removeFiles() }
            let namespace = env.skill.secretNamespaceID
            let bad = env.disk.disk.root.appendingPathComponent("unwritable-vault")
            try Data("invalid vault data".utf8).write(to: bad)
            AstraSecureKeychainStore.$keychainPathOverride.withValue(bad.path) {
                #expect(throws: SkillCredentialEditor.Failure.secretSaveFailed) {
                    try SkillCredentialEditor.save("must-not-save", forKey: "API_TOKEN", on: env.skill, modelContext: env.context)
                }
            }
            #expect(env.skill.secretNamespaceID == namespace)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-authored-token")
            let saved = try #require(try ModelContext(env.context.container).fetch(FetchDescriptor<Skill>()).first)
            #expect(saved.secretNamespaceID == namespace)
            #expect(saved.environmentVariables["API_TOKEN"] == "accepted-authored-token")
            #expect(try env.context.fetch(FetchDescriptor<PluginOperationReceipt>()).isEmpty)
        }
    }

    @MainActor
    private struct Fixture {
        let disk: PluginAddCommitTests.Fixture
        let skill: Skill
        var context: ModelContext { disk.context }
        init() throws {
            disk = try PluginAddCommitTests.Fixture(installed: false)
            skill = Skill(name: "Authored secret", environmentVariables: ["API_TOKEN": "accepted-authored-token"])
            skill.workspace = disk.workspace
            disk.context.insert(skill)
            try disk.context.save()
        }
    }

}
