import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Independent account requests retain accepted credentials", .serialized)
struct UnboundConnectorCredentialFreezeTests {
    @Test("The real submission and launch keep a standalone account's accepted generation", arguments: [false, true], [false, true])
    func submittedStandaloneAccountKeepsAcceptedGeneration(removing: Bool, shared: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let account = Connector(name: "Independent account", serviceType: "custom",
                baseURL: "https://api.example.com", authMethod: "bearer")
            account.isGlobal = shared
            account.workspace = env.workspace
            if shared { WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalConnector(account.id.uuidString) } }
            env.context.insert(account)
            try env.context.save()
            _ = try ConnectorCredentialEditor.save("accepted-independent-token", forKey: "API_TOKEN", on: account, modelContext: env.context)
            try #require(account.credentialNamespaceID != nil)
            try #require(account.accountBindings.isEmpty)
            let originalCleanup = account.keychainCleanup
            let accepted = PluginAccountRecord(account)
            let task = AgentTask(title: "Queued independent account", goal: "Use the accepted account configuration", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
            let id = submission.requestID
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate { $0.id == id })).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let before = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: before)
            let beforeAccount = try #require(TaskCapabilityResolver(task: before).resourceInventory.connectors.first { $0.id == account.id })
            try #require(beforeAccount.currentCredentialValue(forKey: "API_TOKEN") == "accepted-independent-token")
            if removing { try ConnectorCredentialEditor.remove("API_TOKEN", from: account, modelContext: env.context) }
            else { _ = try ConnectorCredentialEditor.save("replacement-independent-token", forKey: "API_TOKEN", on: account, modelContext: env.context) }
            if shared {
                WorkspaceCapabilityActivation.mutate(env.workspace) { $0.globalConnectorIDs = [] }
                try env.context.save()
            }
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == (removing ? nil : "replacement-independent-token"))
            #expect(PendingTaskCredentialReferences.capture(modelContext: env.context)?.holdsAccount(originalCleanup) == true)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let runtimeAccount = TaskCapabilityResolver(task: launch).resourceInventory.connectors.first { $0.id == account.id }
            #expect(runtimeAccount?.currentCredentialValue(forKey: "API_TOKEN") == "accepted-independent-token")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
            _ = journal.resumePending(modelContext: env.context)
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "accepted-independent-token")
        }
    }
    @Test("Accounts introduced after actual submission do not gain authority", arguments: [false, true])
    func lateAccountCannotEnterAcceptedInventory(shared: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let task = AgentTask(title: "Empty account inventory", goal: "Use accepted configuration", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        let snapshot = try submit(task, into: env.context)
        #expect(snapshot.accountInventory?.entries.isEmpty == true)
        let account = Connector(name: "Added later", serviceType: "custom", baseURL: "https://api.example.com", authMethod: "none")
        account.isGlobal = shared
        account.workspace = env.workspace
        env.context.insert(account)
        if shared { WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalConnector(account.id.uuidString) } }
        try env.context.save()
        try #require(TaskCapabilityResolver(task: task).resourceInventory.connectors.contains { $0.id == account.id })
        let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(!TaskCapabilityResolver(task: launch).resourceInventory.connectors.contains { $0.id == account.id })
    }

    @Test("Deleting a standalone account after submission restores its accepted copy")
    func deletedAccountStillLaunches() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let account = Connector(name: "Accepted account", serviceType: "custom", baseURL: "https://api.example.com", authMethod: "none")
        account.workspace = env.workspace
        env.context.insert(account)
        let id = account.id
        let task = AgentTask(title: "Deleted account", goal: "Use accepted configuration", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        let snapshot = try submit(task, into: env.context)
        try #require(snapshot.accountInventory?.entries.contains { $0.account.id == id } == true)
        env.context.delete(account)
        try env.context.save()
        let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(TaskCapabilityResolver(task: launch).resourceInventory.connectors.first { $0.id == id }?.name == "Accepted account")
    }

    @Test("An independently shared account preserves its accepted parent behavior", arguments: [false, true])
    func deletedAccountParentKeepsRole(deleting: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let skill = Skill(name: "Accepted behavior")
        skill.behaviorInstructions = "Use the accepted account protocol."
        skill.isGlobal = true
        env.context.insert(skill)
        let account = Connector(name: "Shared attached account", serviceType: "custom", baseURL: "https://api.example.com", authMethod: "none")
        account.isGlobal = true
        account.skill = skill
        env.context.insert(account)
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalConnector(account.id.uuidString) }
        let task = AgentTask(title: "Queued shared account", goal: "Use accepted configuration", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        let snapshot = try submit(task, into: env.context)
        let id = account.id
        try #require(TaskCapabilityResolver(task: task).resourceInventory.connectors.first { $0.id == id }?.skill?.behaviorInstructions == skill.behaviorInstructions)
        if deleting { env.context.delete(skill) }
        else { skill.behaviorInstructions = "Changed after submission." }
        try env.context.save()
        let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(TaskCapabilityResolver(task: launch).resourceInventory.connectors.first { $0.id == id }?.skill?.behaviorInstructions == "Use the accepted account protocol.")
    }

    private func submit(_ task: AgentTask, into context: ModelContext) throws -> AgentTaskLaunchSnapshot {
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        let id = submission.requestID
        let request = try #require(try context.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate { $0.id == id })).first)
        return try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
    }

}
