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
}
