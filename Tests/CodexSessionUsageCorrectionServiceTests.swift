import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Before Codex declared cumulative session usage, each resumed run stored the thread's running
/// total as its own usage (prod task E0F780F8: 20.9M input recorded against 7.9M real). The
/// correction rebuilds each run's share from the raw report its `task.stats` event kept.
@Suite("Codex session usage correction")
@MainActor
struct CodexSessionUsageCorrectionServiceTests {
    private typealias Service = CodexSessionUsageCorrectionService

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask

        /// A run a pre-fix build recorded: the raw report stored as the run's usage, as the old recorder did.
        @discardableResult
        func legacyRun(_ session: String, at offset: TimeInterval, input: Int, output: Int) -> TaskRun {
            let run = makeRun(session, at: offset)
            run.inputTokens = input
            run.outputTokens = output
            run.tokensUsed = input + output
            task.tokensUsed += input + output
            let stats = TaskEvent(
                task: task, eventType: TaskEventTypes.Task.stats,
                payload: "tokens: \(input + output) (in: \(input), out: \(output))", run: run
            )
            stats.timestamp = run.startedAt
            context.insert(stats)
            run.status = .completed
            return run
        }

        /// A run the fixed recorder records from Codex's cumulative report.
        @discardableResult
        func recordedRun(_ session: String, at offset: TimeInterval, input: Int, output: Int) -> TaskRun {
            let run = makeRun(session, at: offset)
            AgentRuntimeAdapterRegistry.adapter(for: .codexCLI).recordWorkerStreamEvent(
                .agent(.stats(inputTokens: input, outputTokens: output, costUSD: nil, durationMs: nil, turns: nil)),
                mode: task.runs.count == 1 ? .initial : .followUp,
                task: task, run: run, modelContext: context, recordingState: AgentEventRecordingState()
            )
            run.status = .completed
            return run
        }

        func makeRun(_ session: String, at offset: TimeInterval) -> TaskRun {
            let run = TaskRun(task: task)
            run.providerSessionId = session
            run.startedAt = Date(timeIntervalSince1970: 1_800_000_000 + offset)
            context.insert(run)
            return run
        }

        var resetMarkers: [TaskEvent] {
            task.events.filter { $0.type == ProviderSessionUsageEpoch.resetEventType }
        }

        var supersededMarkers: [TaskEvent] {
            task.events.filter { $0.type == Service.supersededResetEventType }
        }

        var correctionEvents: [TaskEvent] {
            task.events.filter { $0.type == Service.correctedEventType }
        }
    }

    private func makeFixture(runtime: AgentRuntimeID = .codexCLI) throws -> Fixture {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let task = AgentTask(title: "Usage", goal: "Count once", runtime: runtime)
        container.mainContext.insert(task)
        return Fixture(container: container, context: container.mainContext, task: task)
    }

    private static let prodSession: [(Int, Int)] = [
        (482_000, 1_566), (543_000, 1_851), (2_680_000, 16_925),
        (2_800_000, 17_334), (6_510_000, 47_077), (7_900_000, 49_691)
    ]

    @Test("A legacy Codex session's runs are rewritten to their own turns and sum to the session total")
    func legacySessionReadsPerTurnUsage() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let runs = Self.prodSession.enumerated().map { index, usage in
            fixture.legacyRun("01a15ac1", at: Double(index) * 60, input: usage.0, output: usage.1)
        }
        #expect(fixture.task.tokensUsed == 20_915_000 + 134_444)
        let lastActivity = Date(timeIntervalSince1970: 1_800_000_500)
        fixture.task.updatedAt = lastActivity

        let outcome = await Service.correct(modelContext: fixture.context)

        #expect(outcome == .init(tasksCorrected: 1, runsCorrected: 5, sessionsSkipped: 0, completed: true))
        #expect(runs.map(\.inputTokens) == [482_000, 61_000, 2_137_000, 120_000, 3_710_000, 1_390_000])
        #expect(runs.map(\.outputTokens) == [1_566, 285, 15_074, 409, 29_743, 2_614])
        #expect(runs.allSatisfy { $0.tokensUsed == $0.inputTokens + $0.outputTokens })
        #expect(fixture.task.tokensUsed == 7_900_000 + 49_691)
        #expect(fixture.resetMarkers.isEmpty)
        let event = try #require(fixture.correctionEvents.first)
        #expect(event.payload.contains("\"input_before\":20915000"))
        #expect(event.payload.contains("\"input_after\":7900000"))
        #expect(event.payload.contains("\"session_id_prefix\":\"01a15ac1\""))
        // A history repair is not activity, so the task keeps its place in recency order.
        #expect(fixture.task.updatedAt == lastActivity)

        // Idempotent: a second pass finds the session already in its corrected state.
        let second = await Service.correct(modelContext: fixture.context)
        #expect(second == .init(tasksCorrected: 0, runsCorrected: 0, sessionsSkipped: 0, completed: true))
        #expect(runs.map(\.inputTokens) == [482_000, 61_000, 2_137_000, 120_000, 3_710_000, 1_390_000])
        #expect(fixture.task.tokensUsed == 7_900_000 + 49_691)
        #expect(fixture.correctionEvents.count == 1)
    }

    /// The first report after the fix is below the legacy runs' sum, so the recorder counted it in full
    /// behind a reset marker. The marker is spurious: left in place, the next run would be measured
    /// against that run alone and count everything before it a second time.
    @Test("The first fixed run's spurious reset is undone, and later runs record correctly")
    func spuriousTransitionResetIsUndone() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let legacy = [(22_903, 5), (45_832, 11), (70_565, 17)].enumerated().map { index, usage in
            fixture.legacyRun("thread-1", at: Double(index) * 60, input: usage.0, output: usage.1)
        }
        let transition = fixture.recordedRun("thread-1", at: 180, input: 95_298, output: 23)
        #expect(transition.inputTokens == 95_298)
        #expect(fixture.resetMarkers.map(\.run?.id) == [transition.id])

        await Service.correct(modelContext: fixture.context)

        #expect((legacy + [transition]).map(\.inputTokens) == [22_903, 22_929, 24_733, 24_733])
        #expect((legacy + [transition]).map(\.outputTokens) == [5, 6, 6, 6])
        #expect(fixture.resetMarkers.isEmpty)
        // Kept as evidence under a type the epoch accounting does not read.
        #expect(fixture.supersededMarkers.map(\.run?.id) == [transition.id])
        #expect(fixture.task.tokensUsed == 95_298 + 23)

        let next = fixture.recordedRun("thread-1", at: 240, input: 120_000, output: 30)
        #expect(next.inputTokens == 120_000 - 95_298)
        #expect(next.outputTokens == 7)
        #expect(fixture.task.tokensUsed == 120_000 + 30)
    }

    /// When a turn adds more than the legacy runs' sum, the first fixed report does not read as a reset:
    /// it is measured against that inflated sum and comes out short, while the legacy runs stay inflated.
    @Test("A short first fixed run is restored to its own turn")
    func shortTransitionRunIsRestored() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let first = fixture.legacyRun("01a15ac1", at: 0, input: 482_000, output: 1_566)
        let second = fixture.legacyRun("01a15ac1", at: 60, input: 543_000, output: 1_851)
        let transition = fixture.recordedRun("01a15ac1", at: 120, input: 2_680_000, output: 16_925)
        #expect(transition.inputTokens == 2_680_000 - 1_025_000)
        #expect(fixture.resetMarkers.isEmpty)

        await Service.correct(modelContext: fixture.context)

        #expect([first, second, transition].map(\.inputTokens) == [482_000, 61_000, 2_137_000])
        #expect([first, second, transition].map(\.outputTokens) == [1_566, 285, 15_074])
        #expect(fixture.task.tokensUsed == 2_680_000 + 16_925)
    }

    @Test("Paging past the batch size reaches every task once")
    func pagingReachesEveryTask() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let other = AgentTask(title: "Second", goal: "Count once", runtime: .codexCLI)
        fixture.context.insert(other)
        let second = Fixture(container: fixture.container, context: fixture.context, task: other)
        // Each task's two runs land on different pages of size 1, interleaved with the other task's.
        let firstRuns = [(100, 1), (300, 3)].enumerated().map { index, usage in
            fixture.legacyRun("thread-1", at: Double(index) * 120, input: usage.0, output: usage.1)
        }
        let secondRuns = [(1_000, 10), (1_600, 16)].enumerated().map { index, usage in
            second.legacyRun("thread-2", at: 60 + Double(index) * 120, input: usage.0, output: usage.1)
        }

        let outcome = await Service.correct(modelContext: fixture.context, batchSize: 1)

        #expect(outcome == .init(tasksCorrected: 2, runsCorrected: 2, sessionsSkipped: 0, completed: true))
        #expect(firstRuns.map(\.inputTokens) == [100, 200])
        #expect(secondRuns.map(\.inputTokens) == [1_000, 600])
        #expect(fixture.correctionEvents.count == 1)
        #expect(second.correctionEvents.count == 1)
    }

    @Test("A session recorded entirely by the fixed recorder is left untouched")
    func fixedSessionIsUntouched() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let runs = Self.prodSession.enumerated().map { index, usage in
            fixture.recordedRun("01a15ac1", at: Double(index) * 60, input: usage.0, output: usage.1)
        }
        let before = runs.map(\.inputTokens)

        let outcome = await Service.correct(modelContext: fixture.context)

        #expect(outcome == .init(tasksCorrected: 0, runsCorrected: 0, sessionsSkipped: 0, completed: true))
        #expect(runs.map(\.inputTokens) == before)
        #expect(fixture.correctionEvents.isEmpty)
    }

    @Test("A legacy counter drop starts a new epoch with a reset marker, and sessions are corrected apart")
    func legacyCounterDropIsMarked() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let runs = [(500, 100), (800, 150), (300, 40), (450, 60)].enumerated().map { index, usage in
            fixture.legacyRun("thread-1", at: Double(index) * 60, input: usage.0, output: usage.1)
        }
        let other = [(1_000, 10), (1_500, 20)].enumerated().map { index, usage in
            fixture.legacyRun("thread-2", at: 30 + Double(index) * 60, input: usage.0, output: usage.1)
        }

        await Service.correct(modelContext: fixture.context)

        #expect(runs.map(\.inputTokens) == [500, 300, 300, 150])
        #expect(runs.map(\.outputTokens) == [100, 50, 40, 20])
        #expect(other.map(\.inputTokens) == [1_000, 500])
        #expect(fixture.resetMarkers.map(\.run?.id) == [runs[2].id])
        #expect(fixture.task.tokensUsed == 800 + 150 + 450 + 60 + 1_500 + 20)

        // The marker is what keeps the next fixed run measured from the drop on.
        let next = fixture.recordedRun("thread-1", at: 300, input: 600, output: 70)
        #expect(next.inputTokens == 150)
        #expect(next.outputTokens == 10)
    }

    @Test("A session with a run whose report is gone is skipped, not guessed at")
    func sessionWithoutReportsIsSkipped() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let first = fixture.legacyRun("thread-1", at: 0, input: 1_000, output: 10)
        let unreported = fixture.makeRun("thread-1", at: 60)
        unreported.inputTokens = 2_000
        unreported.outputTokens = 20
        unreported.tokensUsed = 2_020
        unreported.status = .completed

        let outcome = await Service.correct(modelContext: fixture.context)

        #expect(outcome == .init(tasksCorrected: 0, runsCorrected: 0, sessionsSkipped: 1, completed: true))
        #expect([first, unreported].map(\.inputTokens) == [1_000, 2_000])
        #expect(fixture.correctionEvents.isEmpty)
    }

    @Test("A launch that failed before Codex answered does not break the session")
    func zeroUsageRunIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let first = fixture.legacyRun("thread-1", at: 0, input: 1_000, output: 10)
        let failed = fixture.makeRun("thread-1", at: 60)
        failed.status = .failed
        failed.typedStopReason = .workspaceNotFound
        let third = fixture.legacyRun("thread-1", at: 120, input: 2_500, output: 25)

        await Service.correct(modelContext: fixture.context)

        #expect([first, failed, third].map(\.inputTokens) == [1_000, 0, 1_500])
    }

    @Test("A session with a run still in progress is left for a later pass")
    func runningSessionIsSkipped() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.legacyRun("thread-1", at: 0, input: 1_000, output: 10)
        let running = fixture.legacyRun("thread-1", at: 60, input: 2_000, output: 20)
        running.status = .running

        let defaults = InMemoryDefaults()
        let ran = await Service.correctIfNeeded(modelContext: fixture.context, currentBuild: "42", defaults: defaults)

        // Deferred, not skipped: the gate stays open so the next launch corrects it.
        #expect(!ran)
        #expect(defaults.string(forKey: AppStorageKeys.completedCodexSessionUsageCorrectionBuild) != "42")
        #expect(running.inputTokens == 2_000)

        running.status = .completed
        let retried = await Service.correctIfNeeded(modelContext: fixture.context, currentBuild: "42", defaults: defaults)
        #expect(retried)
        #expect(running.inputTokens == 1_000)
    }

    @Test("Other runtimes' sessions are not touched")
    func otherRuntimesAreUntouched() async throws {
        let fixture = try makeFixture(runtime: .copilotCLI)
        defer { withExtendedLifetime(fixture.container) {} }
        let runs = [(1_000, 10), (2_000, 20)].enumerated().map { index, usage in
            fixture.legacyRun("thread-1", at: Double(index) * 60, input: usage.0, output: usage.1)
        }

        let outcome = await Service.correct(modelContext: fixture.context)

        #expect(outcome == .init(tasksCorrected: 0, runsCorrected: 0, sessionsSkipped: 0, completed: true))
        #expect(runs.map(\.inputTokens) == [1_000, 2_000])
    }

    @Test("Stats payloads yield the provider's report; estimates are not reports")
    func statsPayloadParsing() {
        #expect(Service.report(fromStatsPayload: "tokens: 1576 (in: 1500, out: 76)") == .init(input: 1_500, output: 76))
        #expect(Service.report(fromStatsPayload: "tokens: 1576 (in: 1500, out: 76) | cost: $0.0100 | turns: 2")
            == .init(input: 1_500, output: 76))
        #expect(Service.report(fromStatsPayload: "estimated tokens: 90 (in: 80, out: 10) | provider usage unavailable") == nil)
        #expect(Service.report(fromStatsPayload: "cost: $0.0100 | duration: 1200ms") == nil)
    }

    @Test("The build gate runs the correction once per build")
    func buildGate() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let defaults = InMemoryDefaults()
        fixture.legacyRun("thread-1", at: 0, input: 1_000, output: 10)
        let second = fixture.legacyRun("thread-1", at: 60, input: 2_500, output: 25)
        defaults.set("42", forKey: AppStorageKeys.completedCodexSessionUsageCorrectionBuild)

        let skipped = await Service.correctIfNeeded(modelContext: fixture.context, currentBuild: "42", defaults: defaults)
        #expect(!skipped)
        #expect(second.inputTokens == 2_500)

        let ran = await Service.correctIfNeeded(modelContext: fixture.context, currentBuild: "43", defaults: defaults)
        #expect(ran)
        #expect(second.inputTokens == 1_500)
        #expect(defaults.string(forKey: AppStorageKeys.completedCodexSessionUsageCorrectionBuild) == "43")
    }

    /// A workspace imported after the startup pass, or replaced by an older export, brings
    /// legacy runs in on the same build.
    @Test("Importing a workspace with Codex session runs re-opens the gate")
    func importedCodexRunsReopenTheGate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-codex-usage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = AppStorageKeys.completedCodexSessionUsageCorrectionBuild
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let source = try makeFixture()
        defer { withExtendedLifetime(source.container) {} }
        let workspace = Workspace(name: "Codex", primaryPath: root.path)
        source.context.insert(workspace)
        source.task.workspace = workspace
        source.legacyRun("thread-1", at: 0, input: 1_000, output: 10)
        source.legacyRun("thread-1", at: 60, input: 2_500, output: 25)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: source.context))

        UserDefaults.standard.set("42", forKey: key)
        let destination = try makeFixture()
        defer { withExtendedLifetime(destination.container) {} }
        _ = WorkspaceConfigManager.importWorkspace(from: config, modelContext: destination.context)

        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    @Test("An import while the pass runs keeps the gate open")
    func importDuringThePassKeepsTheGateOpen() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        // Enough tasks that the pass yields many times before it finishes.
        for index in 0..<20 {
            let task = AgentTask(title: "T\(index)", goal: "Count once", runtime: .codexCLI)
            fixture.context.insert(task)
            let other = Fixture(container: fixture.container, context: fixture.context, task: task)
            other.legacyRun("thread-\(index)", at: Double(index), input: 100, output: 1)
            other.legacyRun("thread-\(index)", at: Double(index) + 100, input: 300, output: 3)
        }
        let defaults = InMemoryDefaults()
        let key = AppStorageKeys.completedCodexSessionUsageCorrectionBuild
        let pass = Task { await Service.correctIfNeeded(modelContext: fixture.context, currentBuild: "42", defaults: defaults) }
        var polls = 0
        while defaults.string(forKey: key)?.hasPrefix("42:pending:") != true, polls < 1_000 {
            await Task.yield()
            polls += 1
        }
        #expect(defaults.string(forKey: key)?.hasPrefix("42:pending:") == true)
        defaults.removeObject(forKey: key) // what WorkspaceConfigManager does on import

        let recorded = await pass.value

        #expect(!recorded)
        #expect(defaults.string(forKey: key) == nil)
    }

    @Test("A start time shared by more than a page of runs is read whole")
    func tiedStartTimesBeyondAPage() async throws {
        let fixture = try makeFixture()
        defer { withExtendedLifetime(fixture.container) {} }
        func task(_ title: String) -> Fixture {
            let task = AgentTask(title: title, goal: "Count once", runtime: .codexCLI)
            fixture.context.insert(task)
            return Fixture(container: fixture.container, context: fixture.context, task: task)
        }
        let (a, b, c) = (task("A"), task("B"), task("C"))
        // Four runs start at the same instant; C is reachable only through that group.
        a.legacyRun("thread-a", at: 0, input: 100, output: 1)
        let aSecond = a.legacyRun("thread-a", at: 10, input: 300, output: 3)
        b.legacyRun("thread-b", at: 0, input: 200, output: 2)
        let bSecond = b.legacyRun("thread-b", at: 10, input: 500, output: 5)
        c.legacyRun("thread-c", at: 0, input: 400, output: 4)
        let unreported = c.makeRun("thread-c", at: 0)
        unreported.inputTokens = 900
        unreported.tokensUsed = 900
        unreported.status = .completed

        let outcome = await Service.correct(modelContext: fixture.context, batchSize: 2)

        #expect(outcome == .init(tasksCorrected: 2, runsCorrected: 2, sessionsSkipped: 1, completed: true))
        #expect(aSecond.inputTokens == 200)
        #expect(bSecond.inputTokens == 300)
    }
}
