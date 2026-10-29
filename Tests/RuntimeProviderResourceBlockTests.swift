import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Provider shared-state blocks explain retained ownership", .serialized)
@MainActor
struct RuntimeProviderResourceBlockTests {
    private func retainedOwner(_ h: HeadlessChatHarness, key: AgentRuntimeSharedStateKey,
                               missingClaims: Bool = false) throws -> RuntimeExecutionOwnerRecord {
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Previous unverified execution", model: "test")
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        record.providerSharedStateKey = missingClaims ? nil : key.rawValue
        record.providerSharedStateReleased = false
        record.resourcesReleased = false
        record.resourceClaims = missingClaims ? nil : [.init(taskID: task.id, resourceKey: h.workspaceURL.path,
            accessMode: .write, runMode: "task")]
        let store = RuntimeExecutionOwner.store(in: h.context)
        // Missing legacy claims intentionally fence every provider-settings
        // key. This fixture has its own explicit registry namespace; remove
        // its global scan hint before publishing that ambiguous record so
        // parallel tests do not inherit its quarantine.
        if missingClaims { RuntimeProviderResourceRegistry.unregister(store.root) }
        let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
        try lease.save(record)
        return record
    }

    @Test("Registered, foreign and legacy owners produce a typed block without releasing anything",
           arguments: ["registered", "foreign", "legacy"])
    func typedBlock(lookup: String) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            identifier: h.rootURL.appendingPathComponent("shared-settings.json").path)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let record = try retainedOwner(h, key: key, missingClaims: lookup == "legacy")
        let gate = AgentRuntimeSharedStateGate(processLockRoot: h.rootURL.appendingPathComponent("leases"),
            registeredStoreRoots: [store.root])
        var block: RuntimeProviderResourceRegistry.Block?
        if lookup == "foreign" {
            // A protected pointer must explain the same refusal after restart,
            // even when its journal is absent from the in-memory root registry.
            let reference = RuntimeProviderOwnershipReference(journalRoot: store.root.path,
                taskID: record.taskID, ownerID: record.ownerID)
            let lease = try await ProviderSharedStateProcessLock.acquire(key, root: h.rootURL.appendingPathComponent("leases"))
            try lease.handoff(key, reference: reference, prepare: {})
            do { try lease.handoff(key, reference: nil, prepare: {}); Issue.record("Unverified owner was released") }
            catch let error as RuntimeProviderResourceRegistry.Block { block = error }
        } else {
            do {
                let lease = try await gate.acquire(key)
                await gate.release(lease)
                Issue.record("Unverified owner admitted a competing acquisition")
            } catch let error as RuntimeProviderResourceRegistry.Block { block = error }
        }
        let found = try #require(block)
        #expect(found.taskID == record.taskID && found.ownerID == record.ownerID)
        #expect(found.key == key && found.missingClaims == (lookup == "legacy"))
        #expect(found.localizedDescription.contains("Google Antigravity CLI did not start"))
        #expect(found.localizedDescription.contains(record.taskID.uuidString))
        #expect(found.localizedDescription.contains("shared-settings.json"))
        #expect(found.localizedDescription.contains("will not restart automatically"))
        #expect(try store.read(taskID: record.taskID, taskOwnerID: record.taskOwnerID) == record)
    }

    @Test("A blocked production runner never plans or launches and preserves its explanation after reopen")
    func runnerPausesBeforeLaunch() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            identifier: h.rootURL.appendingPathComponent("shared-settings.json").path)
        let previous = try retainedOwner(h, key: key)
        let path = h.rootURL.appendingPathComponent("independent")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Independent workspace", primaryPath: path.path)
        h.context.insert(workspace)
        let task = AgentTask(title: "Waiting on shared configuration", goal: "Synthetic", workspace: workspace,
            runtime: .antigravityCLI)
        task.status = .running
        h.context.insert(task)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task)
        h.context.insert(run)
        try owner.bind(run: run)
        let limits = owner.record.limits
        let plans = AgentLockedBuffer()
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        runner.configureExecutionOwner(owner)
        defer { runner.configureExecutionOwner(nil) }
        let result = await runner.runRuntimeProcess(adapter: SharedStateBlockedFixtureAdapter(key: key, plans: plans),
            prompt: "Synthetic", task: task, workspacePath: path.path, executablePath: "/usr/bin/false",
            homeDirectory: path.path, permissionPolicy: .restricted, timeoutSeconds: 10, maxRunSeconds: 60,
            onLine: { _, _ in Issue.record("Blocked provider emitted output") })
        #expect(result.runtimeStopReason == RuntimeProviderResourceRegistry.Block.stopReason)
        #expect(result.runtimeStopped && result.executionStopProof == nil)
        #expect(plans.value.isEmpty && owner.record.providerProcess == nil)
        #expect(owner.record.limits.tokenCeiling == limits.tokenCeiling)
        #expect(owner.record.limits.turnsRemaining == limits.turnsRemaining)
        #expect(owner.record.limits.tokensSpent == limits.tokensSpent && owner.record.limits.costSpent == limits.costSpent)
        #expect(owner.record.limits.secondsRemaining <= limits.secondsRemaining && owner.record.limits.secondsRemaining > 0)
        #expect(!AgentRuntimeWorker.isTerminalRuntimeStop(RuntimeProviderResourceRegistry.Block.stopReason))
        try #require(RuntimeStopOutcome.apply(result, task: task, run: run, modelContext: h.context, phase: .run))
        owner.finish()
        try h.context.save()
        #expect(task.status == .pendingUser && run.status == .failed)
        #expect(owner.record.state == .notStarted && owner.persistedResourceRelease)
        #expect(try RuntimeExecutionOwner.store(in: h.context).read(taskID: previous.taskID, taskOwnerID: previous.taskOwnerID) == previous)
        let message = try #require(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context))
        #expect(message == result.runtimeStopMessage)
        #expect(!message.contains("Agent exited") && !message.contains("error 0"))

        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: Array(h.container.configurations))
        let restored = try #require(try reopened.mainContext.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        #expect(restored.status == .pendingUser)
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: restored, context: reopened.mainContext) == message)
        #expect(restored.runs.count == 1)
        // A later run replaces the display fact; the old error is never used
        // as authority or shown as the current block after another attempt.
        let later = TaskRun(task: task)
        later.startedAt = run.startedAt.addingTimeInterval(1)
        later.status = .failed
        later.stopReason = "different_stop"
        h.context.insert(later)
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context) == nil)
    }
}

private struct SharedStateBlockedFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    let key: AgentRuntimeSharedStateKey
    let plans: AgentLockedBuffer
    var id: AgentRuntimeID { .antigravityCLI }
    var descriptor: AgentRuntimeDescriptor { AgentRuntimeAdapterRegistry.descriptor(for: id) }
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func sharedLaunchStateKey(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeSharedStateKey? { key }
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        plans.append("unexpected plan")
        return .init(runtime: id, executablePath: "/usr/bin/false", arguments: [],
            currentDirectory: context.workspacePath, environment: [:], browserShimDirectory: nil,
            providerVersion: nil, parsesJSONLines: true)
    }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] { [] }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}
