import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Runtime waits for relevant plugin operation recovery", .serialized)
struct PluginOperationRuntimeAdmissionTests {
    @Test("Actual capability preflight distinguishes pending, completed and unrelated changes",
          arguments: ["pending", "completed", "other-plugin", "other-workspace", "global-definition", "prepared-files", "unknown-save"])
    func preflightWaitsForRelevantRecovery(scenario: String) throws {
        let previous = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previous) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        _ = try env.enable("admission-fixture-value")
        let task = AgentTask(title: "Run accepted plugin", goal: "Use the configured plugin", workspace: env.workspace)
        task.status = .running
        let run = TaskRun(task: task)
        env.context.insert(task)
        env.context.insert(run)
        let files = PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore())
        var prepared: PluginFileOperationJournal.Prepared?
        if scenario == "prepared-files" {
            prepared = try files.prepare(storeIdentity: #require(PersistentStoreIdentity.current(for: env.context)),
                pluginIDs: [env.package.id], changes: [.init(root: .library, name: "admission-sentinel.json",
                    replacement: PluginFileImage(isDirectory: false, directories: [], files: ["": Data("pending".utf8)]))])
        }
        defer { if let prepared { try? files.discard(prepared) } }
        let pluginIDs = scenario == "other-plugin" || scenario == "prepared-files" ? ["unrelated-plugin"] : [env.package.id]
        let workspaceIDs = scenario == "other-workspace" || scenario == "global-definition" ? [UUID()] : [env.workspace.id]
        if scenario == "unknown-save" {
            enum ReadFailure: Error { case unavailable }
            let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: pluginIDs,
                workspaceIDs: workspaceIDs, modelContext: env.context, persist: { _ in },
                readSaved: { _, _ in throw ReadFailure.unavailable })
            guard case .indeterminate = outcome else { Issue.record("Fixture did not preserve its unknown save"); return }
        } else {
            let outcome = PluginOperationCommit.save(kind: .configure, pluginIDs: pluginIDs,
                workspaceIDs: workspaceIDs, manifestDigest: scenario == "global-definition" ? String(repeating: "a", count: 64) : nil,
                modelContext: env.context)
            guard case .committed(let receipt, _) = outcome else { Issue.record("Fixture did not save its change"); return }
            if scenario == "completed" {
                #expect(PluginOperationRecovery.resumePending(modelContext: env.context).completed == 1)
                #expect(try PluginOperationCommit.read(receipt.id, container: env.context.container)?.completedAt != nil)
            }
        }
        let result = AgentRuntimeLaunchPreflight.preflightCapabilitiesBeforeLaunchResult(
            task: task, run: run, modelContext: env.context, phase: "run")
        let shouldWait = ["pending", "global-definition", "prepared-files", "unknown-save"].contains(scenario)
        #expect(result.didPass == !shouldWait)
        if shouldWait {
            #expect(result.detail?.localizedCaseInsensitiveContains("recover") == true)
        }
    }
}
