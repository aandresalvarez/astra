import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Standalone updates preserve accepted credential generations", .serialized)
struct PluginStandaloneUpdateCredentialTests {
    @Test("A public queued request cannot gain a credential promoted by a later Update", arguments: [false, true])
    func promotionDoesNotChangeQueuedAuthority(automatic: Bool) throws {
        try withLegacySetting { env, package, activation, task, snapshot in
            let before = try #require(TaskCapabilityResolver(task: task).resourceInventory.behaviorSkills.first)
            try #require(before.environmentVariables["API_TOKEN"] == nil)
            let namespace = before.secretNamespaceID
            var updated = package
            updated.version = "2.0.0"
            try CapabilityLibrary().install(updated)
            let changed = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated],
                mode: automatic ? .automatic : .release)
            try #require(changed == 1)
            let live = try #require(TaskCapabilityResolver(task: task).resourceInventory.behaviorSkills.first)
            try #require(live.environmentVariables["API_TOKEN"] == "legacy-update-promotion-token")
            #expect(live.secretNamespaceID != namespace)
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let accepted = try #require(TaskCapabilityResolver(task: launch).resourceInventory.behaviorSkills.first)
            #expect(accepted.environmentVariables["API_TOKEN"] == nil)
            #expect(activation.configuration(forComponent: CapabilityResourceOrigin.componentID(for: package.skills[0]))["API_TOKEN"] == nil)
        }
    }

    @Test("An Update cannot publish a promoted secret before the domain save", arguments: [false, true])
    func failedUpdateDoesNotPublishBeforeSave(throwing: Bool) throws {
        try withLegacySetting { env, package, activation, _, _ in
            var updated = package
            updated.version = "2.0.0"
            let component = CapabilityResourceOrigin.componentID(for: package.skills[0])
            let before = PluginActivationRecord(activation)
            let receipts = try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>())
            var beforeCommit: String?
            #expect(throws: (any Error).self) {
                _ = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated], mode: .release,
                    persist: { context in
                        let saved = try #require(try ModelContext(context.container).fetch(FetchDescriptor<PluginActivation>()).first)
                        let namespace = PluginRuntimeProjection.credentialID(of: saved, componentID: component)
                        beforeCommit = SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace, store: KeychainSecretStore())
                        if throwing { throw NSError(domain: "synthetic.update.save", code: 1) }
                    })
            }
            #expect(beforeCommit == nil)
            #expect(PluginActivationRecord(activation) == before)
            #expect(try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == receipts)
            #expect(activation.configuration(forComponent: component)["API_TOKEN"] == "legacy-update-promotion-token")
        }
    }

    @Test("A saved promoted generation recovers its original receipt after reopening", arguments: [false, true])
    func savedUpdateRecoversForward(reportedSaveFailure: Bool) throws {
        try withLegacySetting { env, package, activation, task, _ in
            var updated = package
            updated.version = "2.0.0"
            try CapabilityLibrary().install(updated)
            let component = CapabilityResourceOrigin.componentID(for: package.skills[0])
            let original = PluginRuntimeProjection.credentialID(of: activation, componentID: component)
            let persist: ((ModelContext) throws -> Void)? = reportedSaveFailure ? { context in
                try context.save()
                throw NSError(domain: "synthetic.update.reported-save", code: 1)
            } : nil
            var operationID: UUID?
            do {
                _ = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated], mode: .release,
                    rewriteMirror: reportedSaveFailure ? nil : { _ in false }, persist: persist)
                Issue.record("A saved update must report its incomplete recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: component)
            #expect(namespace != original)
            let reopened = try env.disk.reopen()
            let savedTask = try #require(try reopened.mainContext.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
            let request = try #require(try reopened.mainContext.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: savedTask))
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
            #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext, only: id).completed == 1)
            PluginSecretCleanupOutbox.resumePending(modelContext: reopened.mainContext)
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
            #expect(PluginRuntimeProjection.credentialID(of: saved, componentID: component) == namespace)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "legacy-update-promotion-token")
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: savedTask)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            let accepted = try #require(TaskCapabilityResolver(task: launch).resourceInventory.behaviorSkills.first)
            #expect(accepted.environmentVariables["API_TOKEN"] == nil)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
        }
    }

    @Test("Public request and recovery export do not serialize legacy secret settings")
    func acceptedRequestDoesNotExportLegacySecret() throws {
        try withLegacySetting { env, package, activation, _, _ in
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let json = try #require(request.executionPolicySnapshotJSON)
            #expect(!json.contains("legacy-update-promotion-token"))
            let mirror = env.disk.root.appendingPathComponent("legacy-secret-request.json")
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context, url: mirror)
            #expect(try !String(contentsOf: mirror, encoding: .utf8).contains("legacy-update-promotion-token"))
            #expect(activation.configuration(forComponent: CapabilityResourceOrigin.componentID(for: package.skills[0]))["API_TOKEN"] == "legacy-update-promotion-token")
        }
    }

    @Test("Export redacts an older saved request without changing its durable snapshot")
    func oldRequestExportDoesNotCopyLegacySecret() throws {
        try withLegacySetting { env, _, activation, _, _ in
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let json = try #require(request.executionPolicySnapshotJSON)
            var older = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            older["pluginActivations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([PluginActivationRecord(activation)]))
            let legacyJSON = try #require(String(data: JSONSerialization.data(withJSONObject: older), encoding: .utf8))
            try #require(legacyJSON.contains("legacy-update-promotion-token"))
            request.executionPolicySnapshotJSON = legacyJSON
            try env.context.save()
            let mirror = env.disk.root.appendingPathComponent("older-request-export.json")
            try WorkspaceConfigManager.exportToFile(workspace: env.workspace, modelContext: env.context, url: mirror)
            #expect(try !String(contentsOf: mirror, encoding: .utf8).contains("legacy-update-promotion-token"))
            #expect(request.executionPolicySnapshotJSON == legacyJSON)
        }
    }

    private func withLegacySetting(_ body: (PluginAddCommitTests.Fixture, PluginPackage, PluginActivation, AgentTask, AgentTaskLaunchSnapshot) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            package.skills[0].environmentKeys = ["API_TOKEN"]
            package.skills[0].environmentValues = [""]
            let library = CapabilityLibrary()
            try library.install(package)
            defer { _ = try? library.removePackage(id: package.id) }
            let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            try installer.enable(package, in: env.workspace, modelContext: env.context)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
            let component = CapabilityResourceOrigin.componentID(for: package.skills[0])
            // Saved shape from before secret settings were moved to the vault.
            WorkspaceCapabilityActivation.setConfigValue("legacy-update-promotion-token", forKey: "\(component)#API_TOKEN", on: activation)
            let task = AgentTask(title: "Accepted before legacy promotion", goal: "Use the accepted plugin", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
            let request = try #require(try env.context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            try body(env, package, activation, task, snapshot)
        }
    }
}
