import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Preparation settlement and remaining limits", .serialized)
@MainActor
struct RuntimePreparationSettlementTests {
    @Test("Cancelling a fallback cannot claim the earlier provider never started")
    func cancelledFallbackRetainsLaunchEvidence() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .cursorCLI, goal: "Synthetic", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        try owner.prepareLaunch()
        let process = AgentExecutionScopedProcess(executablePath: "/usr/bin/true", arguments: [],
            currentDirectory: h.workspaceURL.path, environment: [:])
        try process.run(); defer { process.terminate() }
        try owner.launched(process)
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!process.isRunning)
        owner.stopped(proof: process.stopProof(executionID: owner.record.executionID,
            toolsStopped: true, remoteWorkExcluded: true), turns: 1, tokens: 1, seconds: 0.01)
        try owner.prepareLaunch()
        owner.requestCancellation(); owner.didNotLaunch()
        try owner.beginSettlement(); try owner.completeSettlement(localWorkStopped: true, toolsStopped: true)
        owner.finish()
        #expect(owner.record.hasProviderLaunch && owner.record.providerLaunchCount == 1)
        #expect(!task.events.contains { $0.type == "system.info" && $0.payload.contains("cancelled before the provider started") })
    }

    @Test("Finishing before the runner charges preparation once and preserves the remaining allowance", arguments: [false, true])
    func earlyFinishChargesTime(cancelled: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        if cancelled { owner.requestCancellation() }
        try owner.beginSettlement()
        try await Task.sleep(for: .milliseconds(20))
        try owner.completeSettlement(localWorkStopped: true, toolsStopped: true)
        owner.finish()
        let remaining = owner.record.limits.secondsRemaining
        #expect(remaining < 59.99 && remaining > 0)
        owner.finish()
        #expect(owner.record.limits.secondsRemaining == remaining)
        let saved = try #require(try RuntimeExecutionOwner.store(in: ModelContext(h.container))
            .read(taskID: task.id, taskOwnerID: task.persistentModelID))
        #expect(saved.limits.secondsRemaining == remaining && saved.canReplace)
        let retry = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { retry.finish() }
        #expect(retry.record.limits.secondsRemaining == remaining)
    }

    @Test("Stop stays in cleanup until preparation and relevant tools are joined", arguments: ["pending", "local", "tools", "joined"])
    func cancellationWaitsForSettlement(phase: String) throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        owner.requestCancellation(); try owner.beginSettlement()
        run.status = .cancelled; run.completedAt = Date()
        if phase != "pending" {
            try owner.completeSettlement(localWorkStopped: phase != "local", toolsStopped: phase != "tools")
            owner.finish()
        }
        let events = task.events.map(TaskEventSnapshot.init(event:))
        let snapshot = TaskRunSnapshot(input: .init(run: run))
        let detail = try #require(RuntimeLaunchPresentation.terminalDetail(run: snapshot, events: events))
        #expect(detail.id == (phase == "joined" ? "runtime-unlaunched-terminal" : "runtime-unlaunched-stopping"))
        #expect(detail.summary.contains("new instruction") == (phase == "joined"))
        let label = RuntimeLaunchPresentation.durationLabel(run: snapshot, events: events, now: Date(), format: { "\($0)s" })
        #expect(label?.contains("cancelled before provider start") == (phase == "joined"))
    }
}
