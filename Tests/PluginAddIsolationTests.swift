import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor @Suite("Plugins Add owns its transaction", .serialized)
struct PluginAddIsolationTests {
    @Test("Add preserves pending task and workspace drafts and refreshes the saved activation",
          arguments: [false, true], [false, true])
    func keepsDrafts(workspaceDraft: Bool, existing: Bool) throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        if existing {
            _ = try env.installer.enable(env.package, in: env.workspace, modelContext: env.context)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
            activation.isEnabled = false
            try env.context.save()
        }
        let originalName = env.workspace.name
        let task = AgentTask(title: "Saved task", goal: "Synthetic task", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        task.title = "Task draft"
        if workspaceDraft { env.workspace.name = "Workspace draft" }
        let actions = actions(in: env)
        let approvals = CapabilityApprovalStore(directory: env.disk.root.appendingPathComponent("Approvals"))
        try actions.add(env.package, workspace: env.workspace, modelContext: env.context,
            policyContext: .currentUser(workspace: env.workspace, approvalRecords: [], packPolicy: .empty),
            approvalStore: approvals, traceID: "isolated-add-fixture")
        #expect(task.title == "Task draft")
        #expect(env.workspace.name == (workspaceDraft ? "Workspace draft" : originalName))
        #expect(env.context.hasChanges)
        #expect(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace)?.isEnabled == true)
        let saved = ModelContext(env.context.container)
        #expect(try saved.fetch(FetchDescriptor<AgentTask>()).first?.title == "Saved task")
        #expect(try saved.fetch(FetchDescriptor<Workspace>()).first?.name == originalName)
        #expect(try saved.fetch(FetchDescriptor<PluginActivation>()).count == 1)
        #expect(try saved.fetch(FetchDescriptor<PluginActivation>()).first?.isEnabled == true)
        // A subsequent ordinary save must retain the committed plugin graph,
        // without duplicate activation/binding records or lost editor work.
        try env.context.save()
        let reopened = try env.disk.reopen()
        #expect(try reopened.mainContext.fetch(FetchDescriptor<AgentTask>()).first?.title == "Task draft")
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).count == 1)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first?.isEnabled == true)
    }

    @Test("Three sequential tasks can Add plugins with SSH configuration retained")
    func consecutiveTasksKeepSSHAndHistory() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let ssh = SSHConnection(name: "Fixture SSH", host: "127.0.0.1", user: "fixture", port: 22222)
        SSHConnectionManager.save([ssh], workspacePath: env.workspace.primaryPath)
        let sshURL = URL(fileURLWithPath: SSHConnectionManager.connectionsFilePath(for: env.workspace.primaryPath))
        let sshBefore = try Data(contentsOf: sshURL)
        let actions = actions(in: env)
        let approvals = CapabilityApprovalStore(directory: env.disk.root.appendingPathComponent("Approvals"))
        for turn in 1...3 {
            let task = AgentTask(title: "Task \(turn)", goal: "Synthetic sequence", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            task.title = "Task \(turn) pending draft"
            var package = env.package
            package.id += "-\(turn)"
            try actions.add(package, workspace: env.workspace, modelContext: env.context,
                policyContext: .currentUser(workspace: env.workspace, approvalRecords: approvals.records(), packPolicy: .empty),
                approvalStore: approvals, traceID: "sequence-\(turn)")
            #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace)?.isEnabled == true)
            #expect(task.title == "Task \(turn) pending draft")
            #expect(try Data(contentsOf: sshURL) == sshBefore)
            try env.context.save()
        }
        let reopened = try env.disk.reopen()
        #expect(try reopened.mainContext.fetch(FetchDescriptor<AgentTask>()).count == 3)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).count == 3)
        #expect(SSHConnectionManager.load(workspacePath: env.workspace.primaryPath) == [ssh])
    }

    @Test("Pending plugin edits remain protected without saving or rolling them back")
    func doesNotReplacePluginDraft() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let account = Connector(name: "Unsaved account", serviceType: "jira")
        env.context.insert(account)
        #expect(throws: PluginOperations.OperationError.pendingEdits) {
            try actions(in: env).add(env.package, workspace: env.workspace, modelContext: env.context,
                policyContext: .currentUser(workspace: env.workspace, approvalRecords: [], packPolicy: .empty),
                approvalStore: .init(directory: env.disk.root.appendingPathComponent("Approvals")), traceID: "pending-plugin")
        }
        #expect(env.context.insertedModelsArray.contains { ($0 as? Connector) === account })
        #expect(try ModelContext(env.context.container).fetch(FetchDescriptor<Connector>()).isEmpty)
        #expect(try ModelContext(env.context.container).fetch(FetchDescriptor<PluginActivation>()).isEmpty)
    }

    @Test("A complete plugin refreshes accounts, bindings and templates beside a workspace draft")
    func completePluginGraphIsPreserved() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture()
            defer { env.disk.removeFiles() }
            var package = PluginTemplateIDsAndMirrorsTests.packageWithTemplate()
            package.id = env.package.id
            let draft = AgentTask(title: "Saved task", goal: "Synthetic", workspace: env.workspace)
            env.context.insert(draft)
            try env.context.save()
            env.workspace.name = "Keep workspace draft"
            draft.title = "Keep task draft"
            try actions(in: env).add(package, workspace: env.workspace, modelContext: env.context,
                policyContext: .currentUser(workspace: env.workspace, approvalRecords: [], packPolicy: .empty),
                approvalStore: .init(directory: env.disk.root.appendingPathComponent("Approvals")), traceID: "full-graph")
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
            #expect(activation.isEnabled && activation.bindings.count == 1)
            #expect(env.workspace.connectors.count == 1 && env.workspace.templates.count == 1)
            let account = try #require(activation.bindings.first?.account)
            let namespace = account.credentialNamespaceID
            let activationID = activation.id
            #expect(env.workspace.name == "Keep workspace draft" && draft.title == "Keep task draft")
            try env.context.save()
            let saved = ModelContext(env.context.container)
            #expect(try saved.fetchCount(FetchDescriptor<Connector>()) == 1)
            #expect(try saved.fetchCount(FetchDescriptor<AccountBinding>()) == 1)
            #expect(try saved.fetchCount(FetchDescriptor<TaskTemplate>()) == 1)
            let committed = try #require(try saved.fetch(FetchDescriptor<PluginActivation>()).first)
            #expect(committed.id == activationID && committed.isEnabled)
            #expect(committed.bindings.first?.account?.credentialNamespaceID == namespace)
        }
    }

    @Test("A pending schedule edit is not overwritten by Add reconciliation")
    func pendingScheduleRemainsOwnedByEditor() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let schedule = TaskSchedule(name: "Schedule", goal: "Synthetic", workspace: env.workspace)
        env.context.insert(schedule)
        try env.context.save()
        schedule.skillIDs = [UUID().uuidString]
        let draft = schedule.skillIDs
        #expect(throws: PluginOperations.OperationError.pendingEdits) {
            try actions(in: env).add(env.package, workspace: env.workspace, modelContext: env.context,
                policyContext: .currentUser(workspace: env.workspace, approvalRecords: [], packPolicy: .empty),
                approvalStore: .init(directory: env.disk.root.appendingPathComponent("Approvals")), traceID: "schedule-draft")
        }
        #expect(schedule.skillIDs == draft)
        #expect(try ModelContext(env.context.container).fetch(FetchDescriptor<TaskSchedule>()).first?.skillIDs.isEmpty == true)
    }

    @Test("Two complete Adds work without saving the caller's drafts between them")
    func consecutiveAddsDoNotLeaveFalsePendingEdits() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture()
            defer { env.disk.removeFiles() }
            let task = AgentTask(title: "Saved task", goal: "Synthetic", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            let originalName = env.workspace.name
            env.workspace.name = "Workspace draft"
            task.title = "Task draft"
            let approvals = CapabilityApprovalStore(directory: env.disk.root.appendingPathComponent("Approvals"))
            for index in 1...2 {
                var package = PluginTemplateIDsAndMirrorsTests.packageWithTemplate()
                package.id = env.package.id + "-double-\(index)"
                try actions(in: env).add(package, workspace: env.workspace, modelContext: env.context,
                    policyContext: .currentUser(workspace: env.workspace, approvalRecords: approvals.records(), packPolicy: .empty),
                    approvalStore: approvals, traceID: "double-add-\(index)")
                #expect(env.workspace.name == "Workspace draft" && task.title == "Task draft")
                #expect(WorkspaceCapabilityActivation.activations(of: env.workspace).count == index)
                #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace)?.bindings.count == 1)
                let saved = ModelContext(env.context.container)
                #expect(try saved.fetch(FetchDescriptor<Workspace>()).first?.name == originalName)
                #expect(try saved.fetch(FetchDescriptor<AgentTask>()).first?.title == "Saved task")
            }
            try env.context.save()
            let reopened = try env.disk.reopen()
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginActivation>()) == 2)
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<AccountBinding>()) == 2)
        }
    }

    private func actions(in env: PluginAddCommitTests.Fixture) -> CapabilityCatalogActionService {
        .init(library: env.disk.library, appVersion: SemanticVersion(1, 0, 0),
              sourceStore: PluginSourceStore(root: env.disk.root.appendingPathComponent("Sources")))
    }
}
