import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin lifecycle across durable reopen", .serialized)
struct PluginLifecycleIntegrationTests {
    @Test("Add, Update, Remove and re-Add preserve two workspaces and an accepted credential across reopen", arguments: [false, true])
    func completeLifecycle(updateMirrorFails: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try PluginAddCommitTests.Fixture(installed: false)
            defer { fixture.disk.removeFiles() }
            try FileManager.default.removeItem(at: fixture.disk.target)
            let library = fixture.disk.library
            let approvals = CapabilityApprovalStore()
            let sources = PluginSourceStore(root: fixture.disk.root.appendingPathComponent("Sources"))
            let actions = CapabilityCatalogActionService(library: library, appVersion: SemanticVersion(1, 0, 0), sourceStore: sources)
            let first = fixture.workspace
            let secondFolder = fixture.disk.root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
            let second = Workspace(name: "Second lifecycle workspace", primaryPath: secondFolder.path)
            fixture.context.insert(second)
            try fixture.context.save()
            var initial = fixture.package
            initial.skills = PluginOperationsTests.package(version: "1.0.0").skills
            initial.connectors = [PluginConnector(name: "Lifecycle API", serviceType: "custom", icon: "network",
                description: "Isolated lifecycle account", baseURL: "https://lifecycle.example.com", authMethod: "bearer",
                credentialHints: [.init(key: "API_TOKEN", hint: "Token")], configHints: [], notes: "")]
            try checked("First Add") {
                try add(initial, to: first, context: fixture.context, actions: actions, approvals: approvals,
                    token: "lifecycle-first-accepted")
            }
            try checked("Second workspace Add") {
                try add(initial, to: second, context: fixture.context, actions: actions, approvals: approvals,
                    token: "lifecycle-second-accepted")
            }
            let component = CapabilityResourceOrigin.componentID(for: initial.connectors[0])
            let firstAccount = try account(initial.id, component, in: first)
            let secondAccount = try account(initial.id, component, in: second)
            #expect(firstAccount.id != secondAccount.id)
            #expect(firstAccount.credentialNamespaceID != secondAccount.credentialNamespaceID)
            let task = AgentTask(title: "Accepted before update", goal: "Use accepted account", workspace: first)
            fixture.context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [initial])
            fixture.context.insert(request)
            try fixture.context.save()
            let frozen = try #require(request.executionPolicySnapshot?.pluginAccounts?.first)

            var updated = initial
            updated.version = "2.0.0"
            updated.skills[0].behaviorInstructions = "Use the updated lifecycle behavior."
            try library.stage(CapabilityPackageSource(package: updated, manifestURL: nil, assetRootURL: nil))
            let blocked = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: second.primaryPath))
            if updateMirrorFails {
                if FileManager.default.fileExists(atPath: blocked.path) { try FileManager.default.removeItem(at: blocked) }
                try Data("Blocked mirror".utf8).write(to: blocked)
            }
            var pendingID: UUID?
            do {
                _ = try actions.approveStaged(
                    PluginStagedReview.capture(id: updated.id, library: library), modelContext: fixture.context,
                    approvalStore: approvals, approvedBy: "Lifecycle regression")
                #expect(!updateMirrorFails)
            } catch let problem as PluginOperationProblem {
                guard updateMirrorFails, case .savedRecoveryPending(let id) = problem else { throw problem }
                pendingID = id
            }
            let reopened = try fixture.disk.reopen()
            let context = reopened.mainContext
            context.autosaveEnabled = false
            let workspaces = try context.fetch(FetchDescriptor<Workspace>())
            let here = try #require(workspaces.first { $0.id == first.id })
            let there = try #require(workspaces.first { $0.id == second.id })
            for workspace in [here, there] {
                #expect(WorkspaceCapabilityActivation.activation(for: updated.id, in: workspace)?.recordedVersion == "2.0.0")
            }
            #expect(library.installedPackage(id: updated.id)?.version == "2.0.0")
            let journal = PluginFileOperationJournal(library: library, approvals: approvals)
            if let pendingID {
                let recovery = PluginSourceOperationRecovery(library: library, store: sources, approvals: approvals)
                #expect(recovery.resumePending(modelContext: context) == 1)
                try FileManager.default.removeItem(at: blocked)
                #expect(recovery.resumePending(modelContext: context) == 0)
                #expect(try PluginOperationCommit.read(pendingID, container: reopened)?.completedAt != nil)
            }
            #expect(try journal.pendingIDs().isEmpty)
            try checked("Remove after Update") { try actions.remove(updated, modelContext: context) }
            #expect(WorkspaceCapabilityActivation.activation(for: updated.id, in: here) == nil)
            #expect(WorkspaceCapabilityActivation.activation(for: updated.id, in: there) == nil)
            #expect(library.installedPackage(id: updated.id) == nil)
            #expect(frozen.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "lifecycle-first-accepted")

            let afterRemove = try fixture.disk.reopen()
            let finalContext = afterRemove.mainContext
            finalContext.autosaveEnabled = false
            let finalWorkspaces = try finalContext.fetch(FetchDescriptor<Workspace>())
            let finalFirst = try #require(finalWorkspaces.first { $0.id == first.id })
            let finalSecond = try #require(finalWorkspaces.first { $0.id == second.id })
            try checked("First workspace re-Add") {
                try add(updated, to: finalFirst, context: finalContext, actions: actions, approvals: approvals,
                    token: "lifecycle-first-readded")
            }
            try checked("Second workspace re-Add") {
                try add(updated, to: finalSecond, context: finalContext, actions: actions, approvals: approvals, token: nil)
            }
            let current = try account(updated.id, component, in: finalFirst)
            let other = try account(updated.id, component, in: finalSecond)
            #expect(current.id == firstAccount.id && other.id == secondAccount.id)
            #expect(current.currentCredentialValue(forKey: "API_TOKEN") == "lifecycle-first-readded")
            #expect(other.currentCredentialValue(forKey: "API_TOKEN") == "lifecycle-second-accepted")
            #expect(frozen.makeAccount().currentCredentialValue(forKey: "API_TOKEN") == "lifecycle-first-accepted")
            #expect(try finalContext.fetch(FetchDescriptor<Connector>()).count == 2)
            #expect(try journal.pendingIDs().isEmpty)
            for workspace in [finalFirst, finalSecond] {
                let mirror = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath:
                    WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath)))
                #expect(mirror.installedPlugins?.first { $0.id == updated.id }?.version == "2.0.0")
            }
        }
    }

    @discardableResult
    private func add(_ package: PluginPackage, to workspace: Workspace, context: ModelContext,
        actions: CapabilityCatalogActionService, approvals: CapabilityApprovalStore, token: String?) throws -> Connector {
        try actions.add(package, workspace: workspace, modelContext: context,
            policyContext: CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: approvals.records()),
            approvalStore: approvals, traceID: "lifecycle-" + UUID().uuidString)
        let result = try account(package.id, CapabilityResourceOrigin.componentID(for: package.connectors[0]), in: workspace)
        if let token {
            #expect(try ConnectorCredentialEditor.save(token, forKey: "API_TOKEN", on: result, modelContext: context).isSaved)
        }
        return result
    }

    private enum PhaseFailure: Error { case failed(String, String) }

    @discardableResult
    private func checked<Result>(_ phase: String, _ operation: () throws -> Result) throws -> Result {
        do { return try operation() }
        catch { throw PhaseFailure.failed(phase, String(describing: error)) }
    }

    private func account(_ pluginID: String, _ component: String, in workspace: Workspace) throws -> Connector {
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace))
        return try #require(activation.accounts(forComponent: component).first)
    }
}
