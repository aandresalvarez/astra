import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRACore
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Legacy queued plugin activation coherence")
@MainActor
struct PluginLegacyLaunchCoherenceTests {
    @Test("An old request without frozen definitions cannot accept a renamed definition with its old settings and bindings")
    func renamedDefinitionDoesNotBorrowLiveAcceptance() throws {
        let env = try PluginOperationsTests.Environment()
        let v1 = PluginOperationsTests.package(version: "1.0.0")
        try env.install(v1)
        try PluginOperations.setSetting("PROJECT", to: "submitted-project", of: v1.skills[0],
            pluginID: v1.id, in: env.workspace, modelContext: env.context)
        let old = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        let record = PluginActivationRecord(old)
        let account = try #require(old.bindings.first?.account)
        var v2 = v1
        v2.version = "2.0.0"
        v2.skills[0].id = "summary-agent"
        v2.skills[0].name = "Summary Agent"
        v2.skills[0].replaces = ["report-agent"]
        v2.connectors[0].id = "tracker"
        v2.connectors[0].replaces = ["connector:tracker:tracker-api"]
        try env.importUpdate(v2)
        #expect(old.recordedVersion == v2.version)
        #expect(old.configuration(forComponent: "skill:summary-agent")["PROJECT"] == "submitted-project")

        let legacyLaunch = Workspace(name: "Legacy request", primaryPath: env.workspace.primaryPath)
        WorkspaceCapabilityActivation.copyActivations([record], of: env.workspace, to: legacyLaunch,
            accountsByID: [account.id: TaskExecutionLaunchSnapshotApplicator.detachedConnector(account)], definitionsFrozen: false)
        let copied = try #require(WorkspaceCapabilityActivation.activations(of: legacyLaunch).first)
        #expect(copied.recordedVersion == record.recordedVersion)
        #expect(copied.recordedDigest == record.recordedDigest)
        #expect(copied.knownComponentIDs == record.knownComponentIDs)
        #expect(copied.configKeys == record.configKeys && copied.configValues == record.configValues)
        #expect(copied.bindings.map(\.componentID) == record.bindings.map(\.componentID))
        #expect(PluginRuntimeProjection.project(workspace: legacyLaunch, packages: [v2], definitions: [v2]).skills.isEmpty)
        #expect(PluginRuntimeProjection.runnable([v2], in: legacyLaunch).isEmpty)
        let legacyTask = AgentTask(title: "Dispatch old request", goal: "Run report", workspace: legacyLaunch)
        let problems = CapabilityRuntimeIntegrityService.issues(for: legacyTask, packages: [v2], checkExecutables: false)
        #expect(problems.contains { $0.packageID == v1.id && $0.resourceKind == .policy
            && $0.message.contains("queued request") })

        // A modern request has both pieces of the original contract and can
        // run its submitted definition after the same update.
        let frozenLaunch = Workspace(name: "Frozen request", primaryPath: env.workspace.primaryPath)
        WorkspaceCapabilityActivation.copyActivations([record], of: env.workspace, to: frozenLaunch,
            accountsByID: [account.id: TaskExecutionLaunchSnapshotApplicator.detachedConnector(account)], definitionsFrozen: true)
        let skill = try #require(PluginRuntimeProjection.project(workspace: frozenLaunch,
            packages: [v1], definitions: [v1]).skills.first)
        #expect(skill.environmentVariables["PROJECT"] == "submitted-project")
        let frozenTask = AgentTask(title: "Frozen contract", goal: "Run report", workspace: frozenLaunch)
        #expect(!CapabilityRuntimeIntegrityService.issues(for: frozenTask, packages: [v1], checkExecutables: false)
            .contains { $0.message.contains("queued request") })
        #expect(legacyLaunch.modelContext == nil && frozenLaunch.modelContext == nil)
    }
    @Test("An enabled queued activation whose definition disappeared is a launch error")
    func missingDefinitionIsNotSilentlyOmitted() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let records = WorkspaceCapabilityActivation.activations(of: env.workspace).map(PluginActivationRecord.init)
        let launch = Workspace(name: "Legacy missing definition", primaryPath: "")
        WorkspaceCapabilityActivation.copyActivations(records, of: env.workspace, to: launch, accountsByID: [:])
        let task = AgentTask(title: "Missing plugin", goal: "Use submitted plugin", workspace: launch)
        let problems = CapabilityRuntimeIntegrityService.issues(for: task, packages: [], checkExecutables: false)
        #expect(problems.count == 1)
        #expect(problems.first?.packageID == package.id)
        #expect(problems.first?.resourceKind == .policy)
    }

    @Test("An unchanged definition still admits a legacy queued activation")
    func unchangedLegacyDefinitionRemainsRunnable() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let records = WorkspaceCapabilityActivation.activations(of: env.workspace).map(PluginActivationRecord.init)
        let launch = Workspace(name: "Unchanged contract", primaryPath: "")
        WorkspaceCapabilityActivation.copyActivations(records, of: env.workspace, to: launch, accountsByID: [:])
        let task = AgentTask(title: "Original plugin", goal: "Run report", workspace: launch)
        #expect(PluginRuntimeProjection.runnable([package], in: launch).map(\.id) == [package.id])
        #expect(!CapabilityRuntimeIntegrityService.issues(for: task, packages: [package], checkExecutables: false)
            .contains { $0.message.contains("queued request") })
    }

}
