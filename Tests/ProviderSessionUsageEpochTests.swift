import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// A resumed provider session's cumulative report can come in below what earlier runs recorded when the
/// provider restarts its counters (compaction, a counter reset). That report is all the usage since the
/// restart, so it starts a new accounting epoch: it counts in full, and later runs of the session measure
/// their reports against the runs since the restart rather than the session's whole history.
@Suite("Provider session usage epochs")
@MainActor
struct ProviderSessionUsageEpochTests {
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let runtime: AgentRuntimeID

        /// A run of the shared provider session, started `offset` seconds after the first.
        func run(at offset: TimeInterval) -> TaskRun {
            let run = TaskRun(task: task)
            run.runtimeID = runtime.rawValue
            run.providerSessionId = "session-1"
            run.startedAt = Date(timeIntervalSince1970: 1_800_000_000 + offset)
            context.insert(run)
            return run
        }

        func report(_ input: Int, _ output: Int, cost: Double? = nil, run: TaskRun, mode: AgentRuntimeRecordingMode = .followUp) {
            AgentRuntimeAdapterRegistry.adapter(for: runtime).recordWorkerStreamEvent(
                .agent(.stats(inputTokens: input, outputTokens: output, costUSD: cost, durationMs: nil, turns: nil)),
                mode: mode, task: task, run: run, modelContext: context, recordingState: AgentEventRecordingState()
            )
        }

        var resetMarkers: [TaskEvent] {
            task.events.filter { $0.type == ProviderSessionUsageEpoch.resetEventType }
        }
    }

    private func makeFixture(_ runtime: AgentRuntimeID = .antigravityCLI) throws -> Fixture {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let task = AgentTask(title: "Usage", goal: "Count once", runtime: runtime)
        container.mainContext.insert(task)
        return Fixture(container: container, context: container.mainContext, task: task, runtime: runtime)
    }

    @Test("After a counter reset, the next run of the session is measured against the new epoch only")
    func runAfterResetUsesTheEpochBaseline() throws {
        for runtime in [AgentRuntimeID.antigravityCLI, .copilotCLI] {
            let fixture = try makeFixture(runtime)
            defer { withExtendedLifetime(fixture.container) {} }
            let first = fixture.run(at: 0)
            fixture.report(500, 100, run: first, mode: .initial)
            let reset = fixture.run(at: 60)
            fixture.report(300, 50, run: reset)
            let next = fixture.run(at: 120)
            fixture.report(400, 70, run: next)

            #expect(reset.inputTokens == 300 && reset.outputTokens == 50, "\(runtime.rawValue)")
            // 400/70 is 100/20 more than the reset run recorded; the first run's 500/100 is history.
            #expect(next.inputTokens == 100 && next.outputTokens == 20, "\(runtime.rawValue)")
            #expect(fixture.task.tokensUsed == 600 + 350 + 120, "\(runtime.rawValue)")
            #expect(fixture.resetMarkers.count == 1, "\(runtime.rawValue)")
            #expect(fixture.resetMarkers.first?.run?.id == reset.id, "\(runtime.rawValue)")
        }
    }

    @Test("A run whose session reset counts its later reports in full and is marked once")
    func resetRunStaysInItsOwnEpoch() throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let first = fixture.run(at: 0)
        fixture.report(500, 100, run: first, mode: .initial)
        let reset = fixture.run(at: 60)
        fixture.report(300, 50, run: reset)
        // Grown past the pre-reset totals within the same run: still all usage since the restart.
        fixture.report(600, 120, run: reset)

        #expect(reset.inputTokens == 600)
        #expect(reset.outputTokens == 120)
        #expect(fixture.task.tokensUsed == 600 + 720)
        #expect(fixture.resetMarkers.count == 1)
    }

    @Test("The reset marker records what was reported against which baseline")
    func resetMarkerPayload() throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.report(500, 100, run: fixture.run(at: 0), mode: .initial)
        fixture.report(300, 50, run: fixture.run(at: 60))

        let payload = try #require(fixture.resetMarkers.first?.payload)
        let fields = try JSONDecoder().decode([String: String].self, from: Data(payload.utf8))
        #expect(fields == [
            "session_id_prefix": "session-",
            "reported_input": "300",
            "reported_output": "50",
            "baseline_input": "500",
            "baseline_output": "100"
        ])
    }

    @Test("A reset report's cost counts in full instead of being reduced by the earlier epoch's cost")
    func resetCostCountsInFull() throws {
        let fixture = try makeFixture(.copilotCLI)
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.report(500, 100, cost: 1.00, run: fixture.run(at: 0), mode: .initial)
        let reset = fixture.run(at: 60)
        fixture.report(300, 50, cost: 0.40, run: reset)

        #expect(abs(reset.costUSD - 0.40) < 0.0001)
        #expect(abs(fixture.task.costUSD - 1.40) < 0.0001)
    }

    @Test("Without a reset the baseline is every earlier run of the session, and nothing is marked")
    func noResetKeepsTheWholeSessionBaseline() throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.report(100, 20, run: fixture.run(at: 0), mode: .initial)
        fixture.report(130, 45, run: fixture.run(at: 60))
        let third = fixture.run(at: 120)

        #expect(ProviderSessionUsageEpoch.baseline(for: third, in: fixture.task) == .init(input: 130, output: 45))
        #expect(fixture.resetMarkers.isEmpty)
    }

    @Test("Runtimes that report per-launch usage never get a session baseline")
    func perLaunchRuntimesHaveNoBaseline() throws {
        let fixture = try makeFixture(.cursorCLI)
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.report(500, 100, run: fixture.run(at: 0), mode: .initial)
        let next = fixture.run(at: 60)
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: fixture.task) == .zero)
        fixture.report(300, 50, run: next)
        #expect(next.inputTokens == 300)
        #expect(fixture.resetMarkers.isEmpty)
    }

    @Test("A baseline's run share is what a report adds to it, or the whole report once any counter went backwards")
    func runShareContract() {
        let baseline = ProviderSessionUsageBaseline(input: 500, output: 100)
        func share(_ input: Int, _ output: Int) -> [Int] {
            let share = baseline.runShare(input: input, output: output)
            return [share.input, share.output]
        }
        #expect(share(650, 130) == [150, 30])
        #expect(share(500, 100) == [0, 0])
        #expect(share(300, 50) == [300, 50])
        // Either counter restarting is a reset, even while the other one still grows.
        #expect(share(300, 150) == [300, 150])
        #expect(share(650, 40) == [650, 40])
        // A component the provider does not report (zero) is not evidence of a reset.
        #expect(share(650, 0) == [150, 0])
        #expect(!baseline.isReset(input: 0, output: 0))
        let fromZero = ProviderSessionUsageBaseline.zero.runShare(input: 7, output: 3)
        #expect(fromZero.input == 7 && fromZero.output == 3)
    }

    @Test("The process monitor counts a reset report in full against the token budget")
    func monitorCountsResetReportInFull() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1_000, reportedUsageBaseline: .init(input: 5_000, output: 400))
        // Below the 5,400 the session already recorded: the counters restarted, so all 1,200 are this run's.
        #expect(monitor.processEvent(.usage(totalInputTokens: 1_200, totalOutputTokens: 0), process: nil))
        #expect(monitor.budgetExceeded)

        let result = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1_000, reportedUsageBaseline: .init(input: 5_000, output: 400))
        #expect(result.processEvent(
            .result(text: nil, costUSD: nil, totalInputTokens: 1_100, totalOutputTokens: 50, durationMs: nil, numTurns: nil, isError: false),
            process: nil
        ))
        #expect(result.budgetExceeded)
    }

    @Test("Once a process reports a reset, its later reports are not offset by the old baseline")
    func monitorResetIsSticky() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1_000, reportedUsageBaseline: .init(input: 5_000))
        #expect(!monitor.processEvent(.usage(totalInputTokens: 800, totalOutputTokens: 0), process: nil))
        // 5,500 since the restart is over budget, even though it is only 500 above the pre-reset baseline.
        #expect(monitor.processEvent(.usage(totalInputTokens: 5_500, totalOutputTokens: 0), process: nil))
        #expect(monitor.budgetExceeded)
    }
}
