import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Accepted account inventory persistence", .serialized)
struct AcceptedAccountInventoryPersistenceTests {
    @Test("The real exported request alone retains an independent account generation")
    func recoveryMirrorHoldsAcceptedAccount() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let prior = WorkspaceRecoveryTrust.loadedMirrors
            defer { WorkspaceRecoveryTrust.recordLoadedMirrors(prior) }
            let account = Connector(name: "Mirror account", serviceType: "custom", baseURL: "https://api.example.com", authMethod: "bearer")
            account.workspace = env.workspace
            env.context.insert(account)
            try env.context.save()
            _ = try ConnectorCredentialEditor.save("accepted-mirror-account-token", forKey: "API_TOKEN", on: account, modelContext: env.context)
            let accepted = PluginAccountRecord(account)
            let task = AgentTask(title: "Recoverable independent account", goal: "Use the accepted account", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let json = try #require(request.executionPolicySnapshotJSON)
            #expect(!json.contains("accepted-mirror-account-token"))
            #expect(request.executionPolicySnapshot?.accountInventory?.entries.first?.account.id == account.id)
            var old = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            old.removeValue(forKey: "accountInventory")
            #expect(try JSONDecoder().decode(TaskExecutionPolicySnapshotV1.self,
                from: JSONSerialization.data(withJSONObject: old)).accountInventory == nil)
            let mirror = env.disk.root.appendingPathComponent("independent-request-copy.json")
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context, url: mirror)
            WorkspaceRecoveryTrust.recordLoadedMirrors([mirror.path])
            _ = try ConnectorCredentialEditor.save("current-mirror-account-token", forKey: "API_TOKEN", on: account, modelContext: env.context)
            env.context.delete(request)
            try env.context.save()
            let currentMirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath))
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context, url: currentMirror)
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: env.context))
            _ = journal.resumePending(modelContext: env.context)
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "accepted-mirror-account-token")
            try FileManager.default.removeItem(at: mirror)
            _ = journal.resumePending(modelContext: env.context)
            #expect(accepted.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == nil)
            #expect(account.currentCredentialValue(forKey: "API_TOKEN") == "current-mirror-account-token")
        }
    }

    @Test("Actual submission preserves a bound plugin account after its live activation is turned off")
    func pluginAccountUsesTheSameAcceptedInventory() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.localTools = []
            let library = CapabilityLibrary()
            try library.install(package)
            defer { _ = try? library.removePackage(id: package.id) }
            let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            try installer.enable(package, in: env.workspace, modelContext: env.context,
                                 credentialInputs: ["TRACKER_TOKEN": "accepted-bound-account-token"])
            let task = AgentTask(title: "Real queued plugin account", goal: "Use accepted configuration", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            let account = try #require(TaskCapabilityResolver(task: task).resourceInventory.connectors.first)
            let id = account.id
            try #require(account.currentCredentialValue(forKey: "TRACKER_TOKEN") == "accepted-bound-account-token")
            _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            try #require(snapshot.accountInventory?.entries.contains { $0.account.id == id } == true)
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.capabilityIDs = [] }
            try env.context.save()
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let queued = try #require(TaskCapabilityResolver(task: launch).resourceInventory.connectors.first { $0.id == id })
            #expect(queued.currentCredentialValue(forKey: "TRACKER_TOKEN") == "accepted-bound-account-token")
            #expect(queued.skill?.behaviorInstructions == package.skills.first?.behaviorInstructions)
        }
    }

    @Test("A plugin OAuth storage format survives actual accepted inventory and detached launch")
    func outlookMetadataSurvivesAcceptedInventory() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        var package = PluginOperationsTests.package(version: "1.0.0")
        package.id = env.package.id
        package.localTools = []
        package.connectors[0].serviceType = OutlookCredentialIdentity.serviceType
        package.connectors[0].authMethod = StanfordOutlookMail.authMethod
        package.connectors[0].credentialHints = []
        package.connectors[0].configHints = []
        let library = CapabilityLibrary()
        try library.install(package)
        defer { _ = try? library.removePackage(id: package.id) }
        try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            .enable(package, in: env.workspace, modelContext: env.context)
        let account = try #require(env.workspace.connectors.first { $0.originPackageID == package.id })
        account.credentialNamespaceID = UUID()
        account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat
        account.setConfigValue(StanfordOutlookMail.clientIDKey, value: "synthetic-client")
        try env.context.save()
        let task = AgentTask(title: "Accepted Outlook", goal: "List mail", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        let projected = try #require(TaskCapabilityResolver(task: task).resourceInventory.connectors.first { $0.id == account.id })
        #expect(projected.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
        _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
        let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let frozen = try #require(snapshot.accountInventory?.entries.first { $0.account.id == account.id })
        #expect(frozen.account.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
        let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
        let queued = try #require(TaskCapabilityResolver(task: launch).resourceInventory.connectors.first { $0.id == account.id })
        #expect(queued.credentialNamespaceID == account.credentialNamespaceID)
        #expect(queued.outlookCredentialFormat == OutlookCredentialIdentity.generationFormat)
    }
}
