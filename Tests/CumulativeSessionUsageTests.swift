import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Antigravity and Copilot report the whole provider session's usage on a resumed
/// launch (measured: a 5,180-output-token first turn followed by a one-word resume
/// reported 5,198, 2 turns, cumulative duration). Recording that as the run's usage
/// would count the earlier turns twice, so a resumed run records only the difference.
@Suite("Cumulative session usage")
@MainActor
struct CumulativeSessionUsageTests {
    private func makeContext() throws -> (ModelContext, ModelContainer) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return (container.mainContext, container)
    }

    private func record(
        _ runtime: AgentRuntimeID, input: Int, output: Int, to task: AgentTask, run: TaskRun, context: ModelContext,
        mode: AgentRuntimeRecordingMode = .followUp
    ) {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).recordWorkerStreamEvent(
            .agent(.stats(inputTokens: input, outputTokens: output, costUSD: nil, durationMs: nil, turns: nil)),
            mode: mode, task: task, run: run, modelContext: context, recordingState: AgentEventRecordingState()
        )
    }

    /// First turn records its own usage; the resumed run reports session totals.
    private func twoTurns(
        _ runtime: AgentRuntimeID, first: (Int, Int), cumulative: (Int, Int)
    ) throws -> (task: AgentTask, resumed: TaskRun, container: ModelContainer) {
        let (context, container) = try makeContext()
        let task = AgentTask(title: "Usage", goal: "Count once", runtime: runtime)
        context.insert(task)
        let firstRun = TaskRun(task: task)
        firstRun.providerSessionId = "session-1"
        context.insert(firstRun)
        record(runtime, input: first.0, output: first.1, to: task, run: firstRun, context: context, mode: .initial)

        let resumed = TaskRun(task: task)
        resumed.providerSessionId = "session-1" // preset to the resumed session, as the worker does
        context.insert(resumed)
        record(runtime, input: cumulative.0, output: cumulative.1, to: task, run: resumed, context: context)
        return (task, resumed, container)
    }

    @Test("A resumed Antigravity run records only what its own turn added")
    func antigravityResumeRecordsTheDifference() throws {
        let (_, resumed, container) = try twoTurns(.antigravityCLI, first: (13_895, 5_180), cumulative: (16_247, 5_198))
        defer { withExtendedLifetime(container) {} }
        #expect(resumed.inputTokens == 2_352)
        #expect(resumed.outputTokens == 18)
        #expect(resumed.tokensUsed == 2_370)
    }

    @Test("A resumed Copilot run is corrected the same way")
    func copilotResumeRecordsTheDifference() throws {
        let (_, resumed, container) = try twoTurns(.copilotCLI, first: (14_273, 1_075), cumulative: (28_897, 1_080))
        defer { withExtendedLifetime(container) {} }
        #expect(resumed.inputTokens == 14_624)
        #expect(resumed.outputTokens == 5)
    }

    @Test("A runtime that reports per-launch usage is recorded as reported")
    func perLaunchRuntimesAreUntouched() throws {
        let (_, resumed, container) = try twoTurns(.cursorCLI, first: (100, 10), cumulative: (138, 33))
        defer { withExtendedLifetime(container) {} }
        #expect(resumed.inputTokens == 138)
        #expect(resumed.outputTokens == 33)
    }

    @Test("Usage cannot go negative when a session's counters reset")
    func resetCountersClampAtZero() throws {
        let (_, resumed, container) = try twoTurns(.antigravityCLI, first: (500, 100), cumulative: (300, 50))
        defer { withExtendedLifetime(container) {} }
        #expect(resumed.inputTokens == 0)
        #expect(resumed.outputTokens == 0)
    }

    @Test("Only Antigravity and Copilot declare cumulative session usage")
    func descriptorFlags() {
        for runtime in [AgentRuntimeID.claudeCode, .codexCLI, .copilotCLI, .antigravityCLI, .cursorCLI, .openCodeCLI] {
            let flag = AgentRuntimeAdapterRegistry.adapter(for: runtime).descriptor.reportsCumulativeSessionUsage
            #expect(flag == (runtime == .copilotCLI || runtime == .antigravityCLI), "\(runtime.rawValue)")
        }
    }

    @Test("The monitor's token ceiling is raised by what the session's cumulative stream re-reports")
    func monitorCeilingIncludesTheBaseline() {
        // baseline 300 enters as a negative amount already spent: 1,000 + 300
        #expect(AgentRuntimeProcessRunner.remainingTokenBudget(1_000, alreadyUsed: 0 - 300) == 1_300)
        #expect(AgentRuntimeProcessRunner.remainingTokenBudget(Int.max, alreadyUsed: 0 - 300) == Int.max)
    }

    @Test("A resumed session's cumulative cost is reduced to what the run's own turn added")
    func resumedCostIsADelta() throws {
        let (context, container) = try makeContext()
        defer { withExtendedLifetime(container) {} }
        let task = AgentTask(title: "Cost", goal: "Count once", runtime: .copilotCLI)
        context.insert(task)
        func recordCost(_ cost: Double, run: TaskRun, mode: AgentRuntimeRecordingMode) {
            AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).recordWorkerStreamEvent(
                .agent(.stats(inputTokens: 10, outputTokens: 1, costUSD: cost, durationMs: nil, turns: nil)),
                mode: mode, task: task, run: run, modelContext: context, recordingState: AgentEventRecordingState()
            )
        }
        let first = TaskRun(task: task)
        first.providerSessionId = "session-1"
        context.insert(first)
        recordCost(1.00, run: first, mode: .initial)
        let resumed = TaskRun(task: task)
        resumed.providerSessionId = "session-1"
        context.insert(resumed)
        recordCost(1.25, run: resumed, mode: .followUp)

        #expect(first.costUSD == 1.00)
        #expect(resumed.costUSD == 0.25)
    }

    @Test("A Copilot session found only in its state directory becomes the task's, but never replaces a known one")
    func discoveredCopilotSessionIsAdopted() throws {
        let (context, container) = try makeContext()
        defer { withExtendedLifetime(container) {} }
        let task = AgentTask(title: "Adopt", goal: "Resume later", runtime: .copilotCLI)
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        task.sessionId = nil
        run.providerSessionId = nil
        let metrics = CopilotSessionMetrics(
            sessionID: "found-session", inputTokens: 1, outputTokens: 1, costUSD: nil, durationMs: nil, turns: nil
        )

        CopilotSessionMetricsReader.adoptSession(metrics, task: task, run: run)
        #expect(task.sessionId == "found-session")
        #expect(run.providerSessionId == "found-session")

        task.sessionId = "known"
        run.providerSessionId = "known-run"
        CopilotSessionMetricsReader.adoptSession(metrics, task: task, run: run)
        #expect(task.sessionId == "known")
        #expect(run.providerSessionId == "known-run")
    }

    @Test("The session baseline offsets the cumulative reported usage only, never the live estimate")
    func monitorBaselineOffsetsReportedUsageOnly() {
        let reported = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1_000, reportedUsageBaseline: 5_000)
        // 5,900 reported is 900 of this run once the 5,000 already in the session total is set aside
        #expect(!reported.processEvent(.usage(totalInputTokens: 5_500, totalOutputTokens: 400), process: nil))
        #expect(reported.processEvent(.usage(totalInputTokens: 5_900, totalOutputTokens: 400), process: nil))
        #expect(reported.budgetExceeded)

        // What the current process itself has produced is not offset: the configured ceiling still stops it.
        let estimated = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1_000, reportedUsageBaseline: 5_000)
        #expect(estimated.processEvent(.text(text: String(repeating: "word ", count: 6_000)), process: nil))
        #expect(estimated.budgetExceeded)
    }
}
