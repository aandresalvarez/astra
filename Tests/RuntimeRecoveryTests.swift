import Foundation
import os
import Testing
import SwiftData
import ASTRACore
import ASTRAModels
@testable import ASTRA

private final class RecoveryTestState: @unchecked Sendable {
    struct Value { var time = 0.0; var signals = 0; var admissions = 0; var reports: [RuntimeRecoveryReport] = [] }
    let value = OSAllocatedUnfairLock(initialState: Value())
    var snapshot: Value { value.withLock { $0 } }
    func report(_ report: RuntimeRecoveryReport) { value.withLock { $0.reports.append(report) } }
}

private actor RecoveryAdmissionGate {
    var continuation: CheckedContinuation<Bool, Never>?
    var started: Bool { continuation != nil }
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: true); continuation = nil }
}

@Suite("Safe same-process automatic recovery")
struct RuntimeRecoveryTests {
    private func observation(_ revision: Int = 0) -> RuntimeSupervisionObservation {
        .init(progressRevision: revision, quietSeconds: 600, stdoutBytes: 0, stderrBytes: 0,
            unknownFrames: 0, activeTools: [], managedJobs: [], recentOutput: "")
    }
    private let stop = RuntimeSupervisionSession.Decision.stop(reason: "provider_supervisor_stalled", message: "Stalled")
    private func make(_ state: RecoveryTestState, pid: Int32? = 123,
                      authorize: (@Sendable (RuntimeRecoveryReport) async -> Bool)? = nil) -> RuntimeRecoverySession {
        .init(context: .init(authorize: authorize ?? { _ in state.value.withLock { $0.admissions += 1 }; return true },
                            report: { state.report($0) }), graceSeconds: 5, authorizationSeconds: 2,
              now: { state.snapshot.time }, suspendedPID: { pid }, resume: { _, _ in
                  state.value.withLock { $0.signals += 1 }; return true
              })
    }
    private func waitFor(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }

    @Test("Repeated watchdog callbacks apply one action and wait for actual progress")
    func onceOnly() async throws {
        let state = RecoveryTestState(), session = make(state), attempt = UUID()
        for _ in 0..<50 { #expect(session.tick(observation(), decision: stop, attemptID: attempt)) }
        try await waitFor { state.snapshot.signals == 1 }
        #expect(state.snapshot.admissions == 1)
        #expect(!state.snapshot.reports.contains { $0.phase == .progress })
        #expect(!session.tick(observation(1), decision: .keepRunning, attemptID: attempt))
        #expect(state.snapshot.reports.last?.phase == .progress)
        #expect(!session.tick(observation(1), decision: stop, attemptID: attempt))
        #expect(state.snapshot.signals == 1)
    }

    @Test("Unknown or runnable processes never receive recovery signals")
    func missingReceipt() {
        let state = RecoveryTestState(), session = make(state, pid: nil)
        #expect(!session.tick(observation(), decision: stop, attemptID: UUID()))
        #expect(state.snapshot.signals == 0 && state.snapshot.admissions == 0)
        #expect(state.snapshot.reports.last?.phase == .blocked)
    }

    @Test("Budget, inconclusive and policy stops cannot trigger recovery",
          arguments: ["provider_supervision_budget_unavailable", "provider_supervision_inconclusive", "policy_violation"])
    func otherStops(reason: String) {
        let state = RecoveryTestState(), session = make(state)
        #expect(!session.tick(observation(), decision: .stop(reason: reason, message: "Stopped"), attemptID: UUID()))
        #expect(state.snapshot.signals == 0 && state.snapshot.admissions == 0)
    }

    @Test("Cancelled, stale and expired admissions cannot signal after a late save", arguments: ["cancel", "progress", "deadline"])
    func lateAdmission(action: String) async throws {
        let state = RecoveryTestState(), gate = RecoveryAdmissionGate()
        let session = make(state, authorize: { _ in await gate.wait() })
        let attempt = UUID()
        #expect(session.tick(observation(), decision: stop, attemptID: attempt))
        try await waitFor { await gate.started }
        switch action {
        case "cancel": session.finish()
        case "progress": _ = session.tick(observation(1), decision: .keepRunning, attemptID: attempt)
        default:
            state.value.withLock { $0.time = 3 }
            #expect(!session.tick(observation(), decision: stop, attemptID: attempt))
        }
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(state.snapshot.signals == 0)
        #expect(!session.tick(observation(), decision: stop, attemptID: attempt))
    }

    @Test("Admission failure and lack of new progress fail closed", arguments: [false, true])
    func failure(admitted: Bool) async throws {
        let state = RecoveryTestState(), session = make(state, authorize: { _ in admitted })
        let attempt = UUID()
        #expect(session.tick(observation(), decision: stop, attemptID: attempt))
        try await waitFor { !state.snapshot.reports.isEmpty }
        state.value.withLock { $0.time = 10 }
        #expect(!session.tick(observation(), decision: stop, attemptID: attempt))
        #expect(state.snapshot.signals == (admitted ? 1 : 0))
        #expect(state.snapshot.reports.last?.phase == (admitted ? .expired : .blocked))
        #expect(session.stopMessage != nil)
    }

    @Test("An immediate terminal response is recorded even before the next watchdog tick")
    func immediateExit() async throws {
        let state = RecoveryTestState(), session = make(state)
        _ = session.tick(observation(), decision: stop, attemptID: UUID())
        try await waitFor { state.snapshot.signals == 1 }
        session.finish(progressRevision: 1)
        #expect(state.snapshot.reports.last?.phase == .progress)
    }

    @Test("An inconclusive investigation can safely resume the original suspended process, with its own deadline")
    func inconclusiveRecovery() async throws {
        let state = RecoveryTestState(), session = make(state), attempt = UUID()
        #expect(!session.tick(observation(), decision: .keepRunning, attemptID: attempt))
        #expect(state.snapshot.signals == 0)
        #expect(session.tick(observation(), decision: .keepRunning, attemptID: attempt, investigationCompleted: true))
        try await waitFor { state.snapshot.signals == 1 }
        state.value.withLock { $0.time = 10 }
        #expect(!session.tick(observation(), decision: .keepRunning, attemptID: attempt))
        guard case .stop(let reason, _) = session.stopDecision else { Issue.record("Recovery must expire independently of the model's longer grace"); return }
        #expect(reason == "provider_recovery_failed")
        _ = session.tick(observation(1), decision: .keepRunning, attemptID: attempt)
        #expect(session.stopDecision == nil)
        #expect(state.snapshot.signals == 1)
    }

    @Test("An inconclusive assessment without OS suspension leaves the normal grace period intact")
    func inconclusiveWithoutSuspension() {
        let state = RecoveryTestState(), session = make(state, pid: nil)
        #expect(!session.tick(observation(), decision: .keepRunning, attemptID: UUID(), investigationCompleted: true))
        #expect(session.stopDecision == nil)
        #expect(state.snapshot.admissions == 0 && state.snapshot.reports.isEmpty)
    }
}

@Suite("Durable recovery admission", .serialized)
@MainActor
struct RuntimeRecoveryServiceTests {
    @Test("A saved intent blocks duplicate recovery across contexts and operation IDs")
    func durableOnceOnly() throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .running
        let run = TaskRun(task: task); harness.context.insert(run)
        let report = RuntimeRecoveryReport(operationID: UUID(), attemptID: UUID(), processID: 123, phase: .intent, message: "Test")
        #expect(RuntimeRecoveryService.authorize(report, task: task, run: run, modelContext: harness.context))
        let reopened = ModelContext(harness.container)
        let restored = try #require(reopened.fetch(FetchDescriptor<AgentTask>()).first)
        let restoredRun = try #require(restored.runs.first)
        let duplicate = RuntimeRecoveryReport(operationID: UUID(), attemptID: UUID(), processID: 123, phase: .intent, message: "Duplicate")
        #expect(!RuntimeRecoveryService.authorize(duplicate, task: restored, run: restoredRun, modelContext: reopened))
        #expect(restored.events.filter { $0.type == TaskEventTypes.System.runtimeRecovery.rawValue }.count == 1)
    }

    @Test("Save failures and stale or cancelled task owners cannot authorize recovery", arguments: ["save", "cancel", "stale"])
    func rejectsUnowned(action: String) throws {
        let harness = try HeadlessChatHarness(); defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .running
        let run = TaskRun(task: task); harness.context.insert(run)
        if action == "cancel" { task.status = .cancelled }
        if action == "stale" {
            let later = TaskRun(task: task); later.startedAt = run.startedAt.addingTimeInterval(1)
            harness.context.insert(later)
        }
        enum SaveFailure: Error { case failed }
        let report = RuntimeRecoveryReport(operationID: UUID(), attemptID: UUID(), processID: 123, phase: .intent, message: "Test")
        #expect(!RuntimeRecoveryService.authorize(report, task: task, run: run, modelContext: harness.context,
            save: action == "save" ? { throw SaveFailure.failed } : nil))
        try harness.context.save()
        #expect(task.events.filter { $0.type == TaskEventTypes.System.runtimeRecovery.rawValue }.isEmpty)
    }
}
