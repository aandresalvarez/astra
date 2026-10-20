import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Turn off has durable recovery proof", .serialized)
struct PluginTurnOffCommitTests {
    @Test("A callback without a save cannot claim Turn off succeeded or change recovery ownership")
    func successNeedsSavedReceipt() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, skill in
            let original = WorkspaceCapabilityActivation.pendingLegacyState(of: env.workspace)
            let namespace = skill.secretNamespaceID
            let result = CapabilityActivationDisabler().disable(package, in: env.workspace, modelContext: env.context,
                library: env.disk.library, persist: { _ in })
            #expect(!result.persisted && result.problem == .saveFailed)
            #expect(WorkspaceCapabilityActivation.pendingLegacyState(of: env.workspace) == original)
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Workspace>()).first)
            #expect(WorkspaceCapabilityActivation.pendingLegacyState(of: saved) == original)
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-legacy-disable-token")
        }
    }

    @Test("A saved Turn off recovers the same receipt after reopening, never replaying it", arguments: [false, true])
    func savedChangeRecoversForward(reportedFailure: Bool) throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, skill in
            enum Reported: Error { case afterSave }
            let namespace = skill.secretNamespaceID
            let result = CapabilityActivationDisabler().disable(package, in: env.workspace, modelContext: env.context,
                library: env.disk.library, persist: { context in
                    try context.save()
                    if reportedFailure { throw Reported.afterSave }
                }, rewriteMirror: { _ in false })
            try #require(result.persisted)
            let id = try #require(result.problem?.operationID)
            #expect(result.problem == .savedRecoveryPending(id))
            let actions = CapabilityCatalogActionService(library: env.disk.library)
            #expect(try actions.pendingStateRecoveries(modelContext: env.context) == [.init(id: id, isSaved: true)])
            let reopened = try env.disk.reopen()
            let workspace = try #require(try reopened.mainContext.fetch(FetchDescriptor<Workspace>()).first)
            #expect(!workspace.enabledCapabilityIDs.contains(package.id))
            #expect(try actions.pendingStateRecoveries(modelContext: reopened.mainContext) == [.init(id: id, isSaved: true)])
            let repeated = actions.disable(package, workspace: workspace, modelContext: reopened.mainContext)
            #expect(!repeated.persisted && repeated.problem == .savedRecoveryPending(id))
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 1)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
            try actions.finishStateRecovery(id, modelContext: reopened.mainContext)
            #expect(try actions.pendingStateRecoveries(modelContext: reopened.mainContext).isEmpty)
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
            try actions.finishStateRecovery(id, modelContext: reopened.mainContext)
            let alreadyOff = actions.disable(package, workspace: workspace, modelContext: reopened.mainContext)
            #expect(alreadyOff.persisted && alreadyOff.problem == nil)
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 1)
            #expect(!workspace.enabledCapabilityIDs.contains(package.id))
            #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                store: KeychainSecretStore()) == "accepted-legacy-disable-token")
        }
    }

    @Test("Unrelated dirty edits cannot be committed by the actual Plugins action")
    func unrelatedEditsAreNotSaved() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, _ in
            env.workspace.name = "Unrelated pending workspace name"
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(package, workspace: env.workspace, modelContext: env.context)
            #expect(!result.persisted && result.problem == .pendingEdits)
            #expect(env.workspace.name == "Unrelated pending workspace name")
            let savedContext = ModelContext(env.context.container)
            let saved = try #require(try savedContext.fetch(FetchDescriptor<Workspace>()).first)
            #expect(saved.name != "Unrelated pending workspace name")
            #expect(saved.enabledCapabilityIDs.contains(package.id))
            #expect(try savedContext.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
        }
    }

    @Test("The state recovery action cannot settle a file manifest receipt")
    func fileRecoveryKeepsItsOwnBoundary() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, _ in
            let receipt = PluginOperationReceipt(kind: .update, pluginIDs: [package.id], workspaceIDs: [env.workspace.id],
                manifestDigest: String(repeating: "a", count: 64))
            env.context.insert(receipt)
            try env.context.save()
            let actions = CapabilityCatalogActionService(library: env.disk.library)
            #expect(try actions.pendingStateRecoveries(modelContext: env.context).isEmpty)
            let blocked = actions.disable(package, workspace: env.workspace, modelContext: env.context)
            #expect(!blocked.persisted && blocked.problem == .recoveryRequired)
            #expect(blocked.problem?.operationID == nil)
            #expect(throws: PluginStateRecovery.Failure.receiptUnavailable) {
                try actions.finishStateRecovery(receipt.id, modelContext: env.context)
            }
            #expect(try PluginOperationCommit.read(receipt.id, container: env.context.container)?.completedAt == nil)
        }
    }

    @Test("A missing legacy installation marker is added without losing unrelated parallel metadata")
    func membershipMetadataIsLossless() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, _ in
            env.workspace.legacyInstalledPluginIDs = ["other-plugin"]
            env.workspace.legacyInstalledPluginVersions = ["2.0.0", "unlabelled-tail"]
            env.workspace.legacyEnabledCapabilityIDs = [package.id, "other-plugin"]
            try env.context.save()
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(package, workspace: env.workspace, modelContext: env.context)
            #expect(result.persisted && result.problem == nil)
            #expect(env.workspace.legacyInstalledPluginIDs == ["other-plugin", package.id])
            #expect(env.workspace.legacyInstalledPluginVersions == ["2.0.0", "", "unlabelled-tail"])
            #expect(env.workspace.legacyEnabledCapabilityIDs == ["other-plugin"])
        }
    }

    @Test("Provenance alone cannot admit a legacy selection; an independent shared choice remains usable")
    func selectedRoleRequiresActualOwner() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, skill in
            env.workspace.legacyEnabledCapabilityIDs = []
            env.workspace.legacyInstalledPluginIDs = []
            let task = AgentTask(title: "Orphan origin", goal: "Do not borrow provenance", workspace: env.workspace)
            task.skills = [skill]
            env.context.insert(task)
            try env.context.save()
            #expect(TaskExecutionPolicySnapshotV1(task: task, pluginDefinitions: [package]).authoredSkills?.isEmpty == true)
            skill.isGlobal = true
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalSkill(skill.id.uuidString) }
            try env.context.save()
            let policy = TaskExecutionPolicySnapshotV1(task: task, pluginDefinitions: [package])
            #expect(policy.authoredSkills?.map(\.id) == [skill.id])
            env.workspace.legacyEnabledCapabilityIDs = [package.id]
            try env.context.save()
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(package, workspace: env.workspace, modelContext: env.context)
            try #require(result.persisted && result.problem == nil)
            #expect(WorkspaceCapabilities(workspace: env.workspace, globalSkills: [skill], packageDefinitions: [package]).activeSkills.contains { $0.id == skill.id })
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: [package])
            env.context.insert(request)
            try env.context.save()
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            let launch = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            TaskCapabilitySnapshotter.refreshForFreshRun(task: launch)
            #expect(TaskCapabilityResolver(task: launch).resolvedScope(.fullInventory).resolver.resolvedEnvironmentVariables["API_TOKEN"] == "accepted-legacy-disable-token")
        }
    }

    @Test("An already-off plugin needs no new save or recovery receipt")
    func alreadyOffDoesNotReplayASave() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, _ in
            env.workspace.legacyEnabledCapabilityIDs = []
            try env.context.save()
            let original = WorkspaceCapabilityActivation.snapshot(env.workspace)
            let result = CapabilityActivationDisabler().disable(package, in: env.workspace, modelContext: env.context,
                library: env.disk.library, persist: { _ in Issue.record("An already-saved off state needs no second commit") })
            #expect(result.persisted && result.problem == nil)
            #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == original)
            #expect(try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
            #expect(!env.context.hasChanges)
        }
    }

    @Test("A cached shared row cannot turn off a skill that is now private")
    func staleSharedRoleRequiresReopening() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, _, skill in
            skill.originPackageID = nil
            skill.isGlobal = true
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalSkill(skill.id.uuidString) }
            try env.context.save()
            let row = try #require(CapabilityCatalogInventory.packages(catalogPackages: [],
                capabilities: WorkspaceCapabilities(workspace: env.workspace, globalSkills: [skill])).first)
            skill.isGlobal = false
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.globalSkillIDs.removeAll { $0 == skill.id.uuidString } }
            try env.context.save()
            let before = WorkspaceCapabilityActivation.snapshot(env.workspace)
            let result = CapabilityCatalogActionService(library: env.disk.library).disable(row,
                workspace: env.workspace, modelContext: env.context)
            #expect(!result.persisted && result.problem == .changedResource)
            #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == before)
            #expect(try env.context.fetchCount(FetchDescriptor<Skill>()) == 1)
            #expect(try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == 0)
        }
    }

    @Test("Older request and launch JSON without pending legacy state retains its nil contract")
    func oldPoliciesStillDecode() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, skill in
            let task = AgentTask(title: "Old legacy policy", goal: "Decode the prior shape", workspace: env.workspace)
            task.skills = [skill]
            let policy = TaskExecutionPolicySnapshotV1(task: task, pluginDefinitions: [package])
            var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
            json.removeValue(forKey: "pendingLegacyPluginState")
            let decoded = try JSONDecoder().decode(TaskExecutionPolicySnapshotV1.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded.pendingLegacyPluginState == nil)
            #expect(decoded.authoredSkills == policy.authoredSkills)
            let launch = AgentTaskLaunchSnapshot(task: task)
            var launchJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(launch)) as? [String: Any])
            launchJSON.removeValue(forKey: "pendingLegacyPluginState")
            let old = try JSONDecoder().decode(AgentTaskLaunchSnapshot.self, from: JSONSerialization.data(withJSONObject: launchJSON))
            #expect(old.pendingLegacyPluginState == nil)
            #expect(old.authoredSkills == launch.authoredSkills)
        }
    }
}
