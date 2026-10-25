import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Authored skill retirement preserves accepted requests", .serialized)
struct SkillRetirementTests {
    @Test("Deleting a skill preserves the secret still owned by a real queued request", arguments: [false, true])
    func deletionPreservesQueuedCredential(legacyNamespace: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Queued authored deletion", environmentVariables: ["API_TOKEN": "accepted-retirement-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            if !legacyNamespace {
                try SkillCredentialEditor.save("accepted-retirement-token", forKey: "API_TOKEN", on: skill, modelContext: env.context)
            }
            let namespace = skill.secretNamespaceID
            let task = AgentTask(title: "Queued authored deletion", goal: "Use the accepted authored secret", workspace: env.workspace)
            task.skills = [skill]
            env.context.insert(task)
            TaskCapabilitySnapshotCapture.capture(for: task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let before = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            try #require(TaskCapabilityResolver(task: before).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-retirement-token")
            try SkillRetirement.remove(skill, modelContext: env.context)
            try #require(PendingTaskCredentialReferences.capture(modelContext: env.context)?.holdsSkill(namespace, key: "API_TOKEN") == true)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-retirement-token")
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            #expect(TaskCapabilityResolver(task: launch).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-retirement-token")
            // execute() refreshes the unmanaged launch before resolving the
            // actual provider environment. Retired accepted rows must survive it.
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(TaskCapabilityResolver(task: launch).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-retirement-token")
            #expect(try env.context.fetchCount(FetchDescriptor<Skill>()) == 0)
            #expect(try env.context.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        }
    }
    @Test("Deletion needs an actual saved receipt and preserves the prior secret on noncommit")
    func deletionRequiresSavedReceipt() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let namespace = env.skill.secretNamespaceID
            #expect(throws: SkillRetirement.Failure.saveFailed) {
                try SkillRetirement.remove(env.skill, modelContext: env.context, persist: { context in
                    let savedCount = try ModelContext(context.container).fetchCount(FetchDescriptor<Skill>())
                    #expect(savedCount == 1)
                    #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                        store: KeychainSecretStore()) == "accepted-retirement-token")
                })
            }
            let reopened = try env.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Skill>()).first)
            #expect(saved.secretNamespaceID == namespace)
            #expect(saved.environmentVariables["API_TOKEN"] == "accepted-retirement-token")
            #expect(try env.context.fetchCount(FetchDescriptor<Skill>()) == 1)
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
        }
    }

    @Test("A saved deletion recovers forward with the original receipt", arguments: [false, true])
    func savedDeletionRecoversForward(reportedFailure: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            enum SaveFailure: Error { case reported }
            let namespace = env.skill.secretNamespaceID
            var operationID: UUID?
            do {
                try SkillRetirement.remove(env.skill, modelContext: env.context, persist: { context in
                    try context.save()
                    if reportedFailure { throw SaveFailure.reported }
                }, rewriteMirror: { _ in false })
                Issue.record("Saved deletion must report pending recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-retirement-token")
            let reopened = try env.reopen()
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<Skill>()) == 0)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
            try SkillRetirement.recover(id, modelContext: reopened.mainContext)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 1)
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: reopened.mainContext))
            try journal.resumePending(modelContext: reopened.mainContext)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace, store: KeychainSecretStore()) == nil)
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("A failed vault cleanup keeps retirement debt after the domain deletion")
    func cleanupRefusalRetainsIntent() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let namespace = env.skill.secretNamespaceID
            let bad = env.root.appendingPathComponent("unreadable-retirement-vault")
            try Data("not a vault".utf8).write(to: bad)
            try AstraSecureKeychainStore.$keychainPathOverride.withValue(bad.path) {
                try SkillRetirement.remove(env.skill, modelContext: env.context)
            }
            #expect(try env.context.fetchCount(FetchDescriptor<Skill>()) == 0)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-retirement-token")
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            #expect(try journal.pending().contains(namespace))
            try journal.resumePending(modelContext: env.context)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace, store: KeychainSecretStore()) == nil)
            #expect(try journal.pending().isEmpty)
        }
    }

    @Test("Unrelated edits remain unsaved and a held producer lease prevents deletion")
    func unrelatedEditsAndProducerAreNotOverwritten() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            env.workspace.name = "Pending unrelated name"
            #expect(throws: SkillRetirement.Failure.pendingEdits) {
                try SkillRetirement.remove(env.skill, modelContext: env.context)
            }
            #expect(env.workspace.name == "Pending unrelated name")
            let saved = try #require(try ModelContext(env.context.container).fetch(FetchDescriptor<Workspace>()).first)
            #expect(saved.name != "Pending unrelated name")
            env.context.rollback()
            let prepared = try SkillCredentialGenerationTransaction.prepare(skill: env.skill, replacing: "API_TOKEN",
                with: "staged-not-published", modelContext: env.context)
            defer { prepared.discard() }
            #expect(throws: SkillCredentialGenerationJournal.Failure.busy) {
                try SkillRetirement.remove(env.skill, modelContext: env.context)
            }
            #expect(try env.context.fetchCount(FetchDescriptor<Skill>()) == 1)
            #expect(env.skill.environmentVariables["API_TOKEN"] == "accepted-retirement-token")
        }
    }

    @Test("A typed accepted selection survives deletion without a legacy task snapshot")
    func typedSelectionOwnsItsSecretReference() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let namespace = env.skill.secretNamespaceID
            let task = AgentTask(title: "Typed selection", goal: "Use the accepted authored secret", workspace: env.workspace)
            task.skills = [env.skill]
            env.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            env.context.insert(request)
            try env.context.save()
            try #require(task.skillSnapshots.isEmpty)
            try #require(request.executionPolicySnapshot?.authoredSkills?.map(\.id) == [env.skill.id])
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            try SkillRetirement.remove(env.skill, modelContext: env.context)
            #expect(PendingTaskCredentialReferences.capture(modelContext: env.context)?.holdsSkill(namespace, key: "API_TOKEN") == true)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(TaskCapabilityResolver(task: launch).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-retirement-token")
            request.state = .completed
            request.terminalAt = Date()
            try env.context.save()
            let journal = try #require(try SkillCredentialGenerationJournal(modelContext: env.context))
            try journal.resumePending(modelContext: env.context)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace, store: KeychainSecretStore()) == nil)
        }
    }

    @Test("A skill attached after submission cannot enter the accepted authored selection")
    func lateSelectionCannotExpandAcceptedAuthority() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let task = AgentTask(title: "Accepted selection", goal: "Use the accepted authored secret", workspace: env.workspace)
            task.skills = [env.skill]
            env.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let late = Skill(name: "Late unrelated skill", environmentVariables: ["LATE_SECRET": "not-accepted"])
            late.workspace = env.workspace
            env.context.insert(late)
            task.skills.append(late)
            try env.context.save()
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(launch.skills.map(\.id) == [env.skill.id])
            #expect(TaskCapabilityResolver(task: launch).resolver.resolvedEnvironmentVariables["LATE_SECRET"] == nil)
            #expect(task.skills.contains { $0.id == late.id })
            #expect(try env.context.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        }
    }

    @Test("Accepted authored attachments survive live edits and deletion of their skill")
    func acceptedAttachmentsStayFrozen() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let connector = Connector(name: "Authored attachment", serviceType: "custom", authMethod: "none")
            connector.workspace = env.workspace
            connector.skill = env.skill
            connector.configKeys = ["REGION"]
            connector.configValues = ["accepted-region"]
            env.context.insert(connector)
            let tool = LocalTool(name: "Accepted tool", toolDescription: "Synthetic tool", toolType: "cli", command: "echo", arguments: "accepted")
            tool.workspace = env.workspace
            tool.skill = env.skill
            env.context.insert(tool)
            let connectorID = connector.id
            let toolID = tool.id
            let task = AgentTask(title: "Accepted attachments", goal: "Use the accepted authored secret", workspace: env.workspace)
            task.skills = [env.skill]
            env.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            try #require(snapshot.authoredSkills?.first?.attachedConnectors?.map(\.id) == [connectorID])
            try #require(snapshot.authoredSkills?.first?.attachedTools?.map(\.id) == [toolID])
            connector.configValues = ["changed-region"]
            tool.arguments = "changed"
            try env.context.save()
            try SkillRetirement.remove(env.skill, modelContext: env.context)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let resources = TaskCapabilityResolver(task: launch).resourceInventory
            #expect(resources.connectors.first { $0.id == connectorID }?.configValue("REGION") == "accepted-region")
            #expect(resources.localTools.first { $0.id == toolID }?.arguments == "accepted")
            #expect(resources.connectors.allSatisfy { $0.modelContext == nil })
            #expect(resources.localTools.allSatisfy { $0.modelContext == nil })
            #expect(connector.configValue("REGION") == "changed-region")
            #expect(tool.arguments == "changed")
            #expect(try env.context.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        }
    }

    @Test("Deletion receipts cover former consumers' mirrors as well as the current workspace")
    func everyKnownMirrorParticipates() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let formerPath = env.root.appendingPathComponent("former-skill-consumer")
            try FileManager.default.createDirectory(at: formerPath, withIntermediateDirectories: true)
            let former = Workspace(name: "Former skill consumer", primaryPath: formerPath.path)
            env.context.insert(former)
            try env.context.save()
            let namespace = env.skill.secretNamespaceID
            var operationID: UUID?
            var visited = Set<UUID>()
            do {
                try SkillRetirement.remove(env.skill, modelContext: env.context, rewriteMirror: { workspace in
                    visited.insert(workspace.id)
                    return workspace.id != former.id
                })
                Issue.record("Former mirror failure must owe recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let receipt = try #require(try PluginOperationCommit.read(id, container: env.context.container))
            #expect(Set(receipt.workspaceIDs) == [env.workspace.id, former.id])
            #expect(visited == Set(receipt.workspaceIDs))
            #expect(receipt.completedAt == nil)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-retirement-token")
        }
    }

    @Test("Legacy request and launch JSON without authored records retains its previous contract")
    func legacyPoliciesRemainReadable() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let task = AgentTask(title: "Legacy policy", goal: "Decode the previous shape", workspace: env.workspace)
            task.skills = [env.skill]
            let policy = TaskExecutionPolicySnapshotV1(task: task, pluginDefinitions: [])
            var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
            json.removeValue(forKey: "authoredSkills")
            let decoded = try JSONDecoder().decode(TaskExecutionPolicySnapshotV1.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded.authoredSkills == nil)
            #expect(decoded.skillSnapshotsJSON == policy.skillSnapshotsJSON)
            let launch = AgentTaskLaunchSnapshot(task: task)
            var launchJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(launch)) as? [String: Any])
            launchJSON.removeValue(forKey: "authoredSkills")
            let decodedLaunch = try JSONDecoder().decode(AgentTaskLaunchSnapshot.self, from: JSONSerialization.data(withJSONObject: launchJSON))
            #expect(decodedLaunch.authoredSkills == nil)
            #expect(decodedLaunch.model == launch.model)
        }
    }

    @Test("A chosen workspace cannot borrow authored request authority; trusted recovery preserves it")
    func importTrustControlsAcceptedAuthoredRecords() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try Fixture()
            defer { env.removeFiles() }
            let task = AgentTask(title: "Recover accepted selection", goal: "Use the accepted authored secret", workspace: env.workspace)
            task.skills = [env.skill]
            env.context.insert(task)
            let message = TaskEvent(task: task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "Use the synthetic authored skill")
            env.context.insert(message)
            let request = TaskTurnRequest(task: task, messageEventID: message.id, sequence: 1, pluginDefinitions: [])
            env.context.insert(request)
            try env.context.save()
            let config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
            let exported = try #require(config.tasks?.first?.turnRequests?.first?.executionPolicySnapshotJSON)
            let policy = try JSONDecoder().decode(TaskExecutionPolicySnapshotV1.self, from: Data(exported.utf8))
            try #require(policy.authoredSkills?.map(\.id) == [env.skill.id])
            #expect(!exported.contains("accepted-retirement-token"))
            let chosen = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            let imported = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: chosen.mainContext,
                capabilityTrust: .validate(.init(approvedPackageIDs: [], installedPackageIDs: [], availablePackIDs: []))).workspace
            try chosen.mainContext.save()
            #expect(try chosen.mainContext.fetchCount(FetchDescriptor<TaskTurnRequest>()) == 0)
            let importedTask = try #require(imported.tasks.first)
            #expect(TaskCapabilityResolver(task: importedTask).resolver.resolvedEnvironmentVariables["API_TOKEN"] == nil)
            let own = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            let recovered = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: own.mainContext,
                taskRecoveryTrustPolicy: .trustedLocalRecovery, capabilityTrust: .preserveRecordedState).workspace
            try own.mainContext.save()
            let restoredRequest = try #require(try own.mainContext.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let restoredTask = try #require(recovered.tasks.first)
            #expect(restoredRequest.executionPolicySnapshot?.authoredSkills?.map(\.id) == [env.skill.id])
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: restoredRequest, from: restoredTask))
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: restoredTask)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(TaskCapabilityResolver(task: launch).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-retirement-token")
        }
    }

    @MainActor
    private struct Fixture {
        let env: PluginAddCommitTests.Fixture
        let skill: Skill
        var context: ModelContext { env.context }
        var workspace: Workspace { env.workspace }
        var root: URL { env.disk.root }
        init() throws {
            env = try PluginAddCommitTests.Fixture(installed: false)
            skill = Skill(name: "Authored retirement", environmentVariables: ["API_TOKEN": "accepted-retirement-token"])
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
        }
        func reopen() throws -> ModelContainer { try env.disk.reopen() }
        func removeFiles() { env.disk.removeFiles() }
    }

}
