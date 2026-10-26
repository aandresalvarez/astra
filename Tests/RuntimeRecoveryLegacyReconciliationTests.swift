import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Legacy execution reconciliation", .serialized)
@MainActor
struct RuntimeRecoveryLegacyReconciliationTests {
    /// A run an older ASTRA settled before this process started, with no journal receipt.
    private func legacyRun(_ task: AgentTask, context: ModelContext, endedSecondsBeforeLaunch: TimeInterval = 60) throws -> TaskRun {
        let launched = try #require(RuntimeRecoveryLegacyReconciliation.appStartedAt)
        let run = TaskRun(task: task)
        run.status = .completed
        run.typedStopReason = .completed
        run.startedAt = launched.addingTimeInterval(-endedSecondsBeforeLaunch - 60)
        run.completedAt = launched.addingTimeInterval(-endedSecondsBeforeLaunch)
        context.insert(run)
        return run
    }

    private func reconciliationEvents(_ task: AgentTask) -> Int {
        task.events.filter { $0.payload.contains("older ASTRA version that kept no execution receipt") }.count
    }

    @Test("An upgrade does not strand a task whose earlier runs an older version settled")
    func settledLegacyHistoryAdmitsOneTrackedOwner() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .completed; task.sessionId = "legacy-session"; task.tokensUsed = 600
        _ = try legacyRun(task, context: h.context, endedSecondsBeforeLaunch: 3600)
        let latest = try legacyRun(task, context: h.context)
        try h.context.save()

        #expect(!RuntimeExecutionOwner.requiresExistingReceipt(task))
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context) == nil)
        if case .legacy = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else {
            Issue.record("Settled pre-journal history blocked Retry")
        }
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60,
            newUserTurn: true, newUserRequest: true))
        #expect(!owner.isRecovery)
        #expect(owner.record.legacySettledRunID == latest.id)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.legacySettledRunID == latest.id)
        #expect(reconciliationEvents(task) == 1)
        owner.finish()

        // The receipt that owner wrote, not the history, governs the next turn.
        let next = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60,
            newUserTurn: true, newUserRequest: true))
        #expect(next.record.legacySettledRunID == nil)
        next.finish()
        #expect(reconciliationEvents(task) == 1)
        #expect(task.runs.count == 2 && task.tokensUsed == 600)

        // Reconciliation happens once: losing the receipt now blocks like any tracked task.
        do {
            let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id)
            try FileManager.default.removeItem(at: lease.recordURL)
        }
        #expect(RuntimeExecutionOwner.requiresExistingReceipt(task))
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60,
            newUserTurn: true, newUserRequest: true) == nil)
        #expect(reconciliationEvents(task) == 1)
    }

    @Test("Pre-journal history stays blocked without an older version's own settlement",
          arguments: ["appRestarted", "connectionLost", "noStopReason", "noCompletion", "earlierRunLive",
                      "endedAfterLaunch", "earlierRunContainerized", "unreadableEnvironment", "trackedByJournal", "sessionOnly"])
    func unsettledLegacyHistoryStaysBlocked(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .completed; task.tokensUsed = 600
        if fault == "sessionOnly" {
            task.sessionId = "legacy-session"
        } else {
            let earlier = try legacyRun(task, context: h.context, endedSecondsBeforeLaunch: 3600)
            let latest = try legacyRun(task, context: h.context)
            switch fault {
            case "appRestarted": latest.typedStopReason = .appRestarted
            case "connectionLost": latest.typedStopReason = .runtimeConnectionLost
            case "noStopReason": latest.typedStopReason = nil
            case "noCompletion": latest.completedAt = nil
            case "earlierRunLive": earlier.status = .running
            case "endedAfterLaunch": latest.completedAt = Date()
            case "earlierRunContainerized":
                var container = WorkspaceExecutionEnvironment.host
                container.kind = .dockerImage
                earlier.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(container)
            case "unreadableEnvironment": earlier.executionEnvironmentSnapshotJSON = "{not json"
            case "trackedByJournal":
                h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: "{}"))
            default: Issue.record("Unknown fault \(fault)")
            }
        }
        try h.context.save()

        #expect(RuntimeExecutionOwner.requiresExistingReceipt(task))
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context)?.contains("receipt is missing") == true)
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else {
            Issue.record("Unsettled pre-journal history (\(fault)) bypassed Retry")
        }
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60,
            newUserTurn: true, newUserRequest: true) == nil)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == nil)
        #expect(reconciliationEvents(task) == 0 && task.tokensUsed == 600)
    }
}
