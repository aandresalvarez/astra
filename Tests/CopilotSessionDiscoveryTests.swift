import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Copilot's stream can omit its session id (and its usage), so ASTRA reads the session the launch left in
/// `session-state`. Session discovery is separate from the usage fallback, and a fresh launch adopts only a
/// session it wrote itself.
@Suite("Copilot session discovery")
@MainActor
struct CopilotSessionDiscoveryTests {
    private struct Fixture {
        let context: ModelContext
        let container: ModelContainer
        let home: String
        let task: AgentTask
        let run: TaskRun
        let startedAt: Date
    }

    private func makeFixture() throws -> Fixture {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Discover", goal: "Resume later", runtime: .copilotCLI)
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let home = NSTemporaryDirectory() + "copilot-discovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return Fixture(context: context, container: container, home: home, task: task, run: run, startedAt: Date())
    }

    /// A session that mentions the task and recorded final usage, last written at `modifiedAt`.
    private func writeSession(
        _ sessionID: String, in fixture: Fixture, modifiedAt: Date, input: Int = 10, output: Int = 5
    ) throws {
        let directory = (fixture.home as NSString).appendingPathComponent("session-state/\(sessionID)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let eventsPath = (directory as NSString).appendingPathComponent("events.jsonl")
        let usage = #"{"inputTokens":\#(input),"outputTokens":\#(output),"cacheReadTokens":0,"cacheWriteTokens":0}"#
        try [
            #"{"type":"user.message","data":{"content":"Task thread: \#(fixture.task.id.uuidString)"}}"#,
            #"{"type":"session.shutdown","data":{"totalApiDurationMs":42,"modelMetrics":{"gpt-5":{"requests":{"count":1,"cost":1},"usage":\#(usage)}}}}"#
        ].joined(separator: "\n").write(toFile: eventsPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: eventsPath)
    }

    private func postProcess(_ fixture: Fixture, mode: AgentRuntimeRecordingMode = .initial) {
        AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).recordPostProcessEvents(context: AgentRuntimePostProcessContext(
            homeDirectory: fixture.home,
            task: fixture.task,
            run: fixture.run,
            runStartedAt: fixture.startedAt,
            modelContext: fixture.context,
            recordingState: AgentEventRecordingState(),
            recordingMode: mode,
            onEvent: { _ in }
        ))
    }

    private func statsEvents(_ task: AgentTask) -> [TaskEvent] {
        task.events.filter { $0.type == "task.stats" }
    }

    @Test("A session is adopted even when the stream already reported the run's usage")
    func sessionAdoptedWhenUsageAlreadyRecorded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        fixture.run.inputTokens = 20
        fixture.run.outputTokens = 5
        fixture.run.tokensUsed = 25
        try writeSession("fresh-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(1))

        postProcess(fixture)

        #expect(fixture.run.providerSessionId == "fresh-session")
        #expect(fixture.task.sessionId == "fresh-session")
        #expect(fixture.run.tokensUsed == 25)
        #expect(statsEvents(fixture.task).isEmpty)
    }

    @Test("A fresh launch neither adopts nor bills a session last written before it started")
    func preRunSessionIsNotAdopted() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        try writeSession("previous-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(-30))

        postProcess(fixture)

        #expect(fixture.run.providerSessionId == nil)
        #expect(fixture.task.sessionId == nil)
        #expect(fixture.run.tokensUsed == 0)
        #expect(statsEvents(fixture.task).isEmpty)
    }

    @Test("A session another run recorded or the task already names is not a fresh launch's output")
    func claimedSessionsAreNotAdopted() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        let earlier = TaskRun(task: fixture.task)
        fixture.context.insert(earlier)
        earlier.providerSessionId = "earlier-run-session"
        fixture.task.sessionId = "task-named-session"
        try writeSession("earlier-run-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(1))
        try writeSession("task-named-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(2))

        postProcess(fixture)

        #expect(fixture.run.providerSessionId == nil)
        #expect(fixture.task.sessionId == "task-named-session")
        #expect(fixture.run.tokensUsed == 0)
    }

    @Test("A fresh launch adopts and bills the session it wrote, not an older one")
    func freshLaunchAdoptsItsOwnSession() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        fixture.task.sessionId = "task-named-session"
        try writeSession("task-named-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(-10), input: 99, output: 99)
        try writeSession("fresh-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(1))

        postProcess(fixture)

        #expect(fixture.run.providerSessionId == "fresh-session")
        #expect(fixture.task.sessionId == "fresh-session")
        #expect(fixture.run.inputTokens == 10)
        #expect(fixture.run.outputTokens == 5)
    }

    @Test("A resumed run reads usage from its own session, not a newer one")
    func resumedRunReadsItsOwnSession() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        fixture.task.sessionId = "own-session"
        fixture.run.providerSessionId = "own-session"
        try writeSession("own-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(1))
        try writeSession("newer-session", in: fixture, modifiedAt: fixture.startedAt.addingTimeInterval(2), input: 99, output: 99)

        postProcess(fixture, mode: .followUp)

        #expect(fixture.run.providerSessionId == "own-session")
        #expect(fixture.task.sessionId == "own-session")
        #expect(fixture.run.inputTokens == 10)
        #expect(fixture.run.outputTokens == 5)
    }

    @Test("A resumed session the Copilot CLI cannot load is cleared so the retry starts fresh")
    func rejectedResumeSessionIsCleared() {
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)
        for error in [
            "Error: Session 'c0ffee00-0000-4000-8000-000000000000' was found but could not be loaded.\nunsupported schema",
            "Error: No session or task matched 'c0ffee00-0000-4000-8000-000000000000'",
            "Error: No session, task, or name matched 'c0ffee00'. Use --resume without an ID to pick one."
        ] {
            #expect(adapter.shouldClearStaleSessionOnFailure(
                phase: "resume", result: AgentProcessResult(exitCode: 1, error: error)), "\(error)")
        }
        #expect(!adapter.shouldClearStaleSessionOnFailure(
            phase: "resume", result: AgentProcessResult(exitCode: 1, error: "network timeout")))
        #expect(!adapter.shouldClearStaleSessionOnFailure(
            phase: "run", result: AgentProcessResult(exitCode: 1, error: "Error: No session or task matched 'x'")))
    }
}
