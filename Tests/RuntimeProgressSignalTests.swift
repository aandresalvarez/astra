import Testing
import Foundation
import SwiftData
import ASTRAPersistence
import ASTRAModels
@testable import ASTRA
import ASTRACore

private final class ProgressSignalMockProcess: AgentRuntimeProcessControl {
    private(set) var didTerminate = false
    private(set) var didRequestGracefulStop = false
    /// Recorded so a test can prove the graceful stop happened *before* the
    /// signal, not merely that both happened.
    private(set) var gracefulStopPrecededTerminate = false
    /// Whether there is a stdin channel to close. A provider launched without
    /// one reports that it could not be asked, and the watchdog must not wait
    /// for an answer that cannot come.
    var hasGracefulStopChannel = true

    var isRunning: Bool { !didTerminate }
    var terminationStatus: Int32 { didTerminate ? 143 : 0 }

    func terminate() {
        if didRequestGracefulStop, !didTerminate {
            gracefulStopPrecededTerminate = true
        }
        didTerminate = true
    }

    func requestGracefulStop() -> Bool {
        didRequestGracefulStop = true
        return hasGracefulStopChannel
    }
}

private func makeMonitor(
    noSemanticProgressTimeoutSeconds: TimeInterval = 0,
    idleTimeoutSeconds: TimeInterval = 600,
    maxRunSeconds: TimeInterval? = nil
) -> AgentRuntimeWorker.ProcessMonitor {
    AgentRuntimeWorker.ProcessMonitor(
        tokenBudget: Int.max,
        idleTimeoutSeconds: idleTimeoutSeconds,
        noSemanticProgressTimeoutSeconds: noSemanticProgressTimeoutSeconds,
        maxRunSeconds: maxRunSeconds
    )
}

/// Drives the watchdog past its one free extension so a test can assert on the
/// terminal decision rather than the escalation step.
@discardableResult
private func evaluateUntilStopped(
    _ monitor: AgentRuntimeWorker.ProcessMonitor,
    process: AgentRuntimeProcessControl,
    attempts: Int = 4
) -> Bool {
    for _ in 0..<attempts where monitor.evaluateWatchdogTimeoutForTesting(process: process) {
        return true
    }
    return false
}

// MARK: - Phase 1: no runtime hides work behind a liveness-only frame

@Suite("Runtime progress classification")
@MainActor
struct RuntimeProgressClassificationTests {

    @Test("Every progress-bearing control type classifies as actionable progress")
    func progressBearingControlTypesAreActionable() {
        for type in RuntimeProgressSignals.progressBearingControlTypes {
            #expect(
                AgentRuntimeWorker.ProcessMonitor.progressKind(for: .control(type: type)) == .actionableProgress,
                "\(type) must count as progress; classifying it as liveness kills runs mid-write"
            )
        }
    }

    @Test("Copilot streams tool arguments through a control frame that counts as progress")
    func copilotToolCallDeltaIsActionableProgress() {
        // Copilot's equivalent of Claude's `input_json_delta`: one tool call's
        // arguments arrive as many deltas before `tool.execution_start`. This is
        // the same shape of bug that killed a run mid-`Write` on claude_code.
        let line = #"{"type":"assistant.tool_call_delta","delta":{"arguments":"{\"path\":\"/tmp/SPECS.md\""}}"#
        let parsed = CopilotStreamEventParser.parseAll(line: line)
        let control = parsed.compactMap { event -> String? in
            guard case .control(let type) = event else { return nil }
            return type
        }

        #expect(control.contains("assistant.tool_call_delta"))
        for event in parsed {
            #expect(AgentRuntimeWorker.ProcessMonitor.progressKind(for: event) == .actionableProgress)
        }
    }

    @Test("Copilot live tool output counts as progress")
    func copilotPartialToolOutputIsActionableProgress() {
        for type in ["tool.execution_partial_result", "tool.execution_progress"] {
            let parsed = CopilotStreamEventParser.parseAll(line: #"{"type":"\#(type)"}"#)
            #expect(!parsed.isEmpty)
            for event in parsed {
                #expect(
                    AgentRuntimeWorker.ProcessMonitor.progressKind(for: event) == .actionableProgress,
                    "\(type) is stdout from a running tool — the most direct evidence of work there is"
                )
            }
        }
    }

    @Test("Genuinely contentless frames stay liveness")
    func contentlessFramesStayLiveness() {
        // The widening must not swallow the distinction it is built on: a frame
        // that carries no work still has to look like idle chatter.
        for type in ["assistant.turn_start", "assistant.idle", "system.status", "stream_event.content_block_delta"] {
            #expect(AgentRuntimeWorker.ProcessMonitor.progressKind(for: .control(type: type)) == .providerLiveness)
        }
    }
}

// MARK: - Phase 2: unrecognised traffic is not evidence of idleness

@Suite("Unrecognised stream traffic")
@MainActor
struct UnrecognizedStreamTrafficTests {

    @Test("Unknown frames in the silence window defer the semantic kill")
    func unknownFramesDeferSemanticKill() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        // Establish progress, then go quiet except for frames the parser cannot
        // classify. The provider is plainly still emitting; the taxonomy just
        // cannot say what. That is a parser gap, not a stalled run.
        _ = monitor.processEvent(.text(text: "starting"), process: process)
        _ = monitor.processEvent(.unknown(type: "provider.new_frame_shape"), process: process)

        #expect(evaluateUntilStopped(monitor, process: process) == false)
        #expect(process.didTerminate == false)
        #expect(monitor.runtimeStopReason == nil)
        #expect(monitor.unrecognizedEventCount == 1)
    }

    @Test("Recognised silence after unknown traffic still stops the run")
    func recognizedSilenceAfterUnknownTrafficStillStops() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.unknown(type: "provider.new_frame_shape"), process: process)
        // A later recognised progress event resets the window, so the unknown
        // frame is no longer inside it and the watchdog regains its standing.
        _ = monitor.processEvent(.text(text: "hello"), process: process)

        #expect(evaluateUntilStopped(monitor, process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_semantic_progress_stalled")
    }

    /// Ordering is by event sequence, never by clock. `Date()` resolves to
    /// about a microsecond, and two back-to-back `processEvent` calls routinely
    /// land in the same tick — on the machine this was measured on, 98.5% of
    /// consecutive `Date()` pairs compared *equal*. A timestamp comparison
    /// therefore scored an unknown frame as inside the window it preceded, and
    /// the watchdog stood down for the rest of the run. The test above lost
    /// that race once in a parallel full-suite run and passed in isolation;
    /// this one runs the same sequence back-to-back often enough that a
    /// clock-based implementation cannot pass it, whatever the machine.
    @Test("An unknown frame that preceded progress is outside the window, every time")
    func unknownBeforeProgressIsAlwaysOutsideTheWindow() {
        for _ in 0..<100 {
            let monitor = makeMonitor()
            let process = ProgressSignalMockProcess()
            _ = monitor.processEvent(.unknown(type: "provider.new_frame_shape"), process: process)
            _ = monitor.processEvent(.text(text: "hello"), process: process)
            #expect(evaluateUntilStopped(monitor, process: process) == true)
        }
    }

    /// The mirror image, which a `>` on timestamps would get wrong instead: an
    /// unknown frame that *followed* progress is inside the window even when
    /// it shares the progress frame's timestamp.
    @Test("An unknown frame that followed progress is inside the window, every time")
    func unknownAfterProgressIsAlwaysInsideTheWindow() {
        for _ in 0..<100 {
            let monitor = makeMonitor()
            let process = ProgressSignalMockProcess()
            _ = monitor.processEvent(.text(text: "hello"), process: process)
            _ = monitor.processEvent(.unknown(type: "provider.new_frame_shape"), process: process)
            #expect(evaluateUntilStopped(monitor, process: process) == false)
            #expect(process.didTerminate == false)
        }
    }

    @Test("The outer idle timeout still bounds a stream of pure unknowns")
    func unknownTrafficStillBoundedByOuterIdleTimeout() {
        // Deferring is not forgiving. The backstop has to remain reachable, or
        // a provider emitting junk forever would be immortal.
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: 0, idleTimeoutSeconds: 0)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.unknown(type: "provider.new_frame_shape"), process: process)

        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)
        #expect(monitor.timedOut)
    }
}

// MARK: - Phase 3: raw volume is progress the parser cannot hide

@Suite("Stream volume progress signal")
@MainActor
struct StreamVolumeProgressTests {

    @Test("Enough raw output counts as progress on its own")
    func streamVolumeEstablishesProgress() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        monitor.recordStreamVolume(bytes: RuntimeProgressSignals.semanticProgressByteThreshold)

        #expect(monitor.streamBytesObserved == RuntimeProgressSignals.semanticProgressByteThreshold)
        // Reaching the after-progress guard (rather than the metadata-only or
        // liveness-only guards) proves the bytes registered as real progress.
        #expect(evaluateUntilStopped(monitor, process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_semantic_progress_stalled")
    }

    @Test("Volume below the threshold is not progress")
    func belowThresholdVolumeIsNotProgress() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        monitor.recordStreamVolume(bytes: RuntimeProgressSignals.semanticProgressByteThreshold - 1)
        _ = monitor.processEvent(.systemInit(model: "claude-opus-5", sessionId: "s1"), process: process)

        #expect(monitor.streamBytesObserved == RuntimeProgressSignals.semanticProgressByteThreshold - 1)
        // Not enough bytes to earn progress, so this has to read as a provider
        // that only ever emitted lifecycle metadata. Landing on the
        // stalled-after-progress reason instead would mean sub-threshold volume
        // had quietly been credited.
        #expect(evaluateUntilStopped(monitor, process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_no_semantic_progress")
    }

    @Test("Volume accumulates across lines before crossing the threshold")
    func volumeAccumulatesAcrossLines() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()
        let chunk = 1_024

        for _ in 0..<(RuntimeProgressSignals.semanticProgressByteThreshold / chunk) {
            monitor.recordStreamVolume(bytes: chunk)
        }

        #expect(evaluateUntilStopped(monitor, process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_semantic_progress_stalled")
    }
}

// MARK: - Phase 4: a bound that silence detection cannot launder

@Suite("Run cost bounds")
@MainActor
struct RunCostBoundTests {

    @Test("A busy run still hits the wall clock")
    func busyRunHitsWallClock() {
        // The whole point: this provider is streaming happily, so every
        // silence-based timeout is satisfied. Only the wall clock can stop it.
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: 600, maxRunSeconds: 0.01)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "still working"), process: process)
        Thread.sleep(forTimeInterval: 0.05)

        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_run_wall_clock_exceeded")
        #expect(process.didTerminate)
    }

    /// The ceiling exists to bound what stream volume can launder, and a
    /// managed workspace job is not that: its liveness is a heartbeat file
    /// that must keep changing, it has its own stall bound, and this monitor
    /// already allows it six hours of quiet. Counting its time would kill a
    /// run for having waited on the job it was told to wait on — at the
    /// moment the job returned, before the provider could read the result.
    /// So the wall clock pauses while a job is active and resumes after.
    @Test("Time inside a managed workspace job does not count against the wall clock")
    func managedJobTimeIsExcludedFromWallClock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-wall-clock-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let heartbeat = root.appendingPathComponent("heartbeat.json", isDirectory: false)
        let result = root.appendingPathComponent("result.json", isDirectory: false)
        let formatter = ISO8601DateFormatter()
        try #"{"status":"running","timestamp":"\#(formatter.string(from: Date()))"}"#
            .write(to: heartbeat, atomically: true, encoding: .utf8)

        let ceiling: TimeInterval = 0.3
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: 600, maxRunSeconds: ceiling)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "Started the build as a managed workspace job"), process: process)
        _ = monitor.processEvent(
            .toolResult(
                toolId: "job-start",
                content: """
                job_id: build
                status: running
                runtime: docker
                command: make all
                heartbeat: \(heartbeat.path)
                result: \(result.path)
                """
            ),
            process: process
        )
        // The first poll that sees the job opens the exclusion.
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)

        // Wall time is now past the ceiling, and all of it was inside the job.
        Thread.sleep(forTimeInterval: ceiling * 2)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(monitor.runtimeStopReason == nil)

        // The job returns. The provider's own clock has barely started, so it
        // gets to read the result rather than being killed on the spot.
        try #"{"status":"succeeded","timestamp":"\#(formatter.string(from: Date()))"}"#
            .write(to: result, atomically: true, encoding: .utf8)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(monitor.runtimeStopReason == nil)

        // And the ceiling is a pause, not a waiver: it resumes once the job is gone.
        Thread.sleep(forTimeInterval: ceiling * 2)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_run_wall_clock_exceeded")
        #expect(process.didTerminate)
    }

    @Test("The wall clock does not fire early")
    func wallClockDoesNotFireEarly() {
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: 600, maxRunSeconds: 3600)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "working"), process: process)

        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(monitor.runtimeStopReason == nil)
    }

    @Test("An unset token budget resolves to a finite default")
    func unsetTokenBudgetIsBounded() {
        #expect(RuntimeProgressSignals.defaultTokenBudget < Int.max)
        #expect(AgentRuntimeProcessRunner.effectiveTokenBudget(
            baseBudget: 0,
            usesAgentTeam: false,
            teamSize: 1
        ) == RuntimeProgressSignals.defaultTokenBudget)
        // Above the worst run actually observed in production (17.3M tokens),
        // so nothing that completes today starts failing.
        #expect(RuntimeProgressSignals.defaultTokenBudget > 17_300_000)
    }
}

// MARK: - Phase 5: a breach is not automatically a death sentence

@Suite("Watchdog escalation")
@MainActor
struct WatchdogEscalationTests {

    @Test("The first breach extends the window instead of killing")
    func firstBreachExtendsWindow() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "hello"), process: process)

        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(process.didTerminate == false)
        #expect(monitor.runtimeStopReason == nil)
    }

    @Test("The second breach stops the run")
    func secondBreachStopsRun() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "hello"), process: process)
        _ = monitor.evaluateWatchdogTimeoutForTesting(process: process)

        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_semantic_progress_stalled")
        #expect(process.didTerminate)
    }

    @Test("Progress between breaches restores the full extension budget")
    func progressRestoresExtensionBudget() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "hello"), process: process)
        _ = monitor.evaluateWatchdogTimeoutForTesting(process: process)
        // Real progress means the earlier breach was a false positive, so the
        // run should not carry a strike into the next quiet stretch.
        _ = monitor.processEvent(.text(text: "more output"), process: process)

        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(process.didTerminate == false)
    }

    @Test("An extension outranks the generic idle backstop while it is live")
    func extensionSuppressesGenericIdleTimeout() {
        // The semantic window is always <= the idle window, and defaults to
        // exactly equal whenever the idle window is under 180s — which is what
        // every short-timeout task gets. Without the reprieve covering both
        // clocks, the extension is granted and then overruled by the backstop
        // in the very same evaluation, so escalation buys the run nothing and
        // the stop is reported as a bare "timeout" instead of naming the cause.
        // Both windows equal and short, which is what `min(idleTimeout, 180)`
        // produces for any task under three minutes. Real sleeps, because the
        // reprieve is a wall-clock deadline.
        let window: TimeInterval = 0.4
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: window, idleTimeoutSeconds: window)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.systemInit(model: "claude-opus-5", sessionId: "s1"), process: process)

        Thread.sleep(forTimeInterval: window + 0.1)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(process.didTerminate == false)
        #expect(monitor.timedOut == false)

        Thread.sleep(forTimeInterval: window + 0.1)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_no_semantic_progress")
        // The specific diagnosis has to survive: "emitted startup metadata and
        // then went quiet" is actionable, "timeout" is not.
        #expect(monitor.timedOut == false)
    }

    @Test("The provider is asked to wind down before it is signalled")
    func gracefulStopPrecedesTermination() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "hello"), process: process)
        evaluateUntilStopped(monitor, process: process)

        #expect(process.didTerminate)
        #expect(process.didRequestGracefulStop)
        #expect(process.gracefulStopPrecededTerminate)
    }
}

// MARK: - Cross-cutting: replay a real stream shape end to end

@Suite("Runtime stream replay")
@MainActor
struct RuntimeStreamReplayTests {

    /// Replays the stream shape that actually killed task 4DD4B29F: the agent
    /// spent five minutes composing one large `Write`, which reaches ASTRA as
    /// thousands of tool-input deltas and nothing else. Before the fix this
    /// looked like a dead run.
    @Test("A long tool-input stream is never mistaken for a stall")
    func longToolInputStreamSurvives() {
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: 0)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "I'll rewrite SPECS.md now."), process: process)
        _ = monitor.processEvent(
            .control(type: StreamEventParser.toolInputDeltaControlType),
            process: process
        )

        // Every delta must leave the run credited with progress, whatever the
        // watchdog is doing on its own schedule.
        #expect(
            AgentRuntimeWorker.ProcessMonitor.progressKind(
                for: .control(type: StreamEventParser.toolInputDeltaControlType)
            ) == .actionableProgress
        )
        // And they must not read as a repetition loop: one Write is thousands
        // of identical-looking frames.
        #expect(
            AgentRuntimeWorker.ProcessMonitor.repetitionSignature(
                .control(type: StreamEventParser.toolInputDeltaControlType)
            ) == nil
        )
    }

    @Test("A provider streaming only unparsed bytes is not killed as idle")
    func unparsedByteStreamSurvives() {
        // The general case behind the specific bug: ASTRA cannot decode any of
        // this, but a megabyte of output is not an idle process.
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        for _ in 0..<64 {
            monitor.recordStreamVolume(bytes: 4_096)
            _ = monitor.processEvent(.unknown(type: "provider.v2_frame"), process: process)
        }

        #expect(evaluateUntilStopped(monitor, process: process) == false)
        #expect(process.didTerminate == false)
        #expect(monitor.streamBytesObserved == 64 * 4_096)
    }

    @Test("A truly silent provider is still killed")
    func silentProviderStillKilled() {
        // The control that keeps every other test in this suite honest.
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.systemInit(model: "claude-opus-5", sessionId: "s1"), process: process)

        #expect(evaluateUntilStopped(monitor, process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_no_semantic_progress")
        #expect(process.didTerminate)
    }
}

// MARK: - Phase 6: deliverable detection covers ordinary requests

@Suite("Deliverable expectation coverage")
@MainActor
struct DeliverableExpectationCoverageTests {

    private func task(_ goal: String, title: String = "Task") -> AgentTask {
        AgentTask(
            title: title,
            goal: goal,
            workspace: Workspace(name: "Deliverable", primaryPath: "/tmp/deliverable")
        )
    }

    @Test("The real BigQuery task goal is recognised as expecting an artifact")
    func bigQueryGoalExpectsArtifact() {
        // Verbatim from task 4DD4B29F, typos and all. The keyword whitelist
        // missed it entirely: "local app" is not "demo app", and "UI" was not
        // in the vocabulary at all.
        let goal = """
        I want to create a UI that conects to the Bigquery tables , to facilitate the searhc \
        process for all of the users of this .. propsoes some idas about how to build it .. \
        wit hthe minimun infrastructure and so it works in windows and mac.. aslo it should be \
        a local app so they can installe it a n start making questions to the historical sales \
        force cases
        """

        #expect(TaskDeliverableExpectation.requiresStandaloneArtifact(task(goal)))
    }

    @Test("Common artifact requests are recognised")
    func commonArtifactRequestsRecognised() {
        for goal in [
            "build a dashboard for the sales data",
            "create a UI for browsing the support tickets",
            "build a local app so the team can install it",
            "make a website for the reading group",
            "generate a prototype of the new onboarding flow",
            "create a spreadsheet of the vendor quotes",
            "make a csv of the results"
        ] {
            #expect(
                TaskDeliverableExpectation.requiresStandaloneArtifact(task(goal)),
                "expected an artifact for: \(goal)"
            )
        }
    }

    /// The two mistakes do not cost the same. A missed artifact request only
    /// tightens a watchdog window; an invented one rewrites the prompt around
    /// a file the user never asked for and then blocks completion when it does
    /// not appear. So a noun that names a shape of *answer* as readily as a
    /// file — a report, a document, a diagram, a data format — must not be
    /// enough on its own, or "make the API return json" becomes a task that
    /// owes a deliverable and fails for want of one.
    @Test("Answer-shaped nouns do not owe a file")
    func answerShapedNounsDoNotOweAFile() {
        for goal in [
            "write a report summarising the findings",
            "create a document describing the migration",
            "make the API return json instead of xml",
            "create a diagram of the auth flow",
            "write sql to count the active users",
            "generate a summary in markdown",
            // The two phrasings the PR review used to describe this exact
            // false positive: inline text a user reads, not a file on disk.
            "write a sql query that lists the overdue invoices",
            "generate json for this response"
        ] {
            #expect(
                TaskDeliverableExpectation.requiresStandaloneArtifact(task(goal)) == false,
                "unexpected artifact expectation for: \(goal)"
            )
        }
    }

    /// Where a false positive actually lands, asserted at both consumers: the
    /// prompt tells the provider its first action must be a file write, and
    /// completion is blocked when that file never appears. A request that is
    /// plainly a code change must get neither, so the vocabulary cannot widen
    /// again without this failing.
    @Test("A code-change request neither rewrites the prompt nor blocks completion")
    func codeChangeRequestIsNotAnArtifactTask() throws {
        let fixture = try insertedTask(goal: "make the API return json instead of xml")
        withExtendedLifetime(fixture.container) {
            fixture.run.setOutput("Switched the serializer to JSON and updated the tests.")

            #expect(!AgentPromptBuilder.buildPrompt(for: fixture.task).contains("Artifact first-action requirement:"))
            #expect(!TaskCompletionPolicy.decideSuccessfulCompletion(task: fixture.task, run: fixture.run).shouldBlockCompletion)
        }
    }

    /// The inverse, so the test above is not passing by accident of the
    /// harness: an unmistakable artifact request still gets both.
    @Test("An artifact request still rewrites the prompt and gates completion")
    func artifactRequestIsStillAnArtifactTask() throws {
        let fixture = try insertedTask(goal: "build a local app so the team can install it")
        withExtendedLifetime(fixture.container) {
            fixture.run.setOutput("I'll create it.")

            #expect(AgentPromptBuilder.buildPrompt(for: fixture.task).contains("Artifact first-action requirement:"))
            let decision = TaskCompletionPolicy.decideSuccessfulCompletion(task: fixture.task, run: fixture.run)
            #expect(decision.shouldBlockCompletion)
            #expect(decision.gate == .manualArtifactRequirement)
        }
    }

    /// The consumers read relationships, so the task has to live in a store —
    /// and the store has to outlive the assertions. A container that goes out
    /// of scope resets its context, and every model it handed out dies with
    /// it, which SwiftData reports as a fatal error rather than a failure.
    private struct InsertedTask {
        let container: ModelContainer
        let task: AgentTask
        let run: TaskRun
    }

    private func insertedTask(goal: String) throws -> InsertedTask {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Deliverable", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(title: "Task", goal: goal, workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()
        return InsertedTask(container: container, task: task, run: run)
    }

    @Test("Short nouns match as whole words only")
    func shortNounsMatchWholeWordsOnly() {
        // "ui" hides inside "build", "guide" and "require"; "app" inside
        // "happens" and "appropriate". Substring matching here would mark
        // nearly every task as owing a file.
        for goal in [
            "create a guide explaining what happens when the build requires approval",
            "write an explanation of appropriate escalation paths"
        ] {
            #expect(
                TaskDeliverableExpectation.requiresStandaloneArtifact(task(goal)) == false,
                "unexpected artifact expectation for: \(goal)"
            )
        }
    }

    @Test("Informational requests still expect nothing on disk")
    func informationalRequestsUnchanged() {
        for goal in [
            "explain the Masterball puzzle",
            "what are the tradeoffs between the two approaches",
            "review the auth code and tell me what you find"
        ] {
            #expect(
                TaskDeliverableExpectation.requiresStandaloneArtifact(task(goal)) == false,
                "unexpected artifact expectation for: \(goal)"
            )
        }
    }
}

// MARK: - Review follow-ups: the watchdog's own edge cases

@Suite("Watchdog deadline coincidence")
@MainActor
struct WatchdogDeadlineCoincidenceTests {

    /// `noSemanticProgressTimeoutSeconds` defaults to `min(idleTimeout, 180)`,
    /// so every task with an idle timeout of three minutes or less has both
    /// deadlines land on the same instant. The stalled-after-progress branch
    /// used to require `anyIdleDuration < idleTimeoutSeconds` — a precedence
    /// rule meant to leave a completely silent provider to the idle branch —
    /// and that predicate is false exactly when the two deadlines coincide. The
    /// run then fell through to the idle branch and was killed outright on its
    /// first breach, never receiving the extension this watchdog exists to
    /// grant, and the kill was reported as a bare timeout.
    @Test("A stall after real progress still earns its extension when both deadlines coincide")
    func coincidingDeadlinesStillExtend() {
        let window: TimeInterval = 0.4
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: window, idleTimeoutSeconds: window)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "real work happened here"), process: process)

        Thread.sleep(forTimeInterval: window + 0.1)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(process.didTerminate == false)
        #expect(monitor.timedOut == false)

        Thread.sleep(forTimeInterval: window + 0.1)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)
        // Named, not a bare timeout: "produced work and then stopped advancing"
        // is a different diagnosis from "never said anything".
        #expect(monitor.runtimeStopReason == "provider_semantic_progress_stalled")
        #expect(monitor.timedOut == false)
    }

    /// The precedence rule still has to hold where it was meant to apply: when
    /// the idle window is genuinely longer, a provider that has gone completely
    /// silent belongs to the idle branch, not to this one.
    @Test("A wider idle window keeps the two branches distinct")
    func distinctDeadlinesKeepPrecedence() {
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: 0.2, idleTimeoutSeconds: 3600)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "real work happened here"), process: process)

        // First breach: the extension, not the idle backstop, even though the
        // provider has been silent — the semantic deadline is the earlier one.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        #expect(process.didTerminate == false)

        // The extension runs another `noSemanticProgressTimeoutSeconds`, and
        // the idle window is nowhere near expiry, so what fires second is still
        // the semantic branch rather than a bare idle timeout.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)
        #expect(monitor.runtimeStopReason == "provider_semantic_progress_stalled")
        #expect(monitor.timedOut == false)
    }
}

@Suite("Watchdog stop classification")
@MainActor
struct WatchdogStopClassificationTests {

    /// The wall clock is deterministic and unappealable — no answer from the
    /// user makes four hours have been three. If its reason is not a declared
    /// `TaskRunStopReason`, `isTerminalRuntimeStop` cannot classify it and the
    /// worker parks the task in `pendingUser`, waiting for a review that can
    /// never change the outcome.
    @Test("The wall-clock stop is a declared, terminal stop reason")
    func wallClockStopIsTerminal() {
        let monitor = makeMonitor(noSemanticProgressTimeoutSeconds: 600, maxRunSeconds: 0.01)
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "still working"), process: process)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == true)

        let reason = monitor.runtimeStopReason ?? ""
        #expect(reason == TaskRunStopReason.providerRunWallClockExceeded.rawValue)
        #expect(TaskRunStopReason(rawValue: reason) != nil)
        #expect(AgentRuntimeWorker.isTerminalRuntimeStop(reason))
    }

    /// Every other stop this watchdog can reach has to classify too, or the
    /// same silent parking happens one branch over.
    @Test("Every watchdog stop reason is terminal")
    func everyWatchdogStopIsTerminal() {
        for reason in [
            "provider_no_semantic_progress",
            "provider_no_actionable_progress",
            "provider_semantic_progress_stalled",
            "provider_active_tool_stalled",
            "provider_workspace_job_stalled",
            "provider_run_wall_clock_exceeded"
        ] {
            #expect(AgentRuntimeWorker.isTerminalRuntimeStop(reason), "not terminal: \(reason)")
        }
    }
}

@Suite("Watchdog graceful stop")
@MainActor
struct WatchdogGracefulStopTests {

    /// `requestGracefulStop` closes stdin so an interactive stream-JSON provider
    /// can notice the run is over and flush the result it is already holding.
    /// Sending SIGTERM in the next statement took that back — the default
    /// disposition for SIGTERM is to die, so a provider whose event loop had not
    /// yet reached the EOF was killed before it could write anything.
    @Test("A provider that exits on the graceful stop is never signalled")
    func gracefulExitSkipsTermination() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "hello"), process: process)
        _ = monitor.evaluateWatchdogTimeoutForTesting(process: process, awaitGracefulExit: { true })

        #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process, awaitGracefulExit: { true }) == true)
        #expect(process.didRequestGracefulStop)
        #expect(process.didTerminate == false)
    }

    /// And the grace period is bounded, so a wedged provider is not held onto.
    @Test("A provider that ignores the graceful stop is still signalled")
    func ignoredGracefulStopStillTerminates() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        _ = monitor.processEvent(.text(text: "hello"), process: process)
        evaluateUntilStopped(monitor, process: process)

        #expect(process.didRequestGracefulStop)
        #expect(process.didTerminate)
        #expect(process.gracefulStopPrecededTerminate)
        #expect(AgentRuntimeWorker.ProcessMonitor.gracefulStopGraceSeconds > 0)
    }

    /// The grace period is owed only when there was a channel to close. Every
    /// provider launched without a stdin pipe used to pay it anyway: two
    /// seconds of polling for an EOF that was never sent, on every kill.
    @Test("A provider with no stdin channel is signalled without waiting")
    func noChannelSkipsTheWait() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()
        process.hasGracefulStopChannel = false
        var waited = false

        _ = monitor.processEvent(.text(text: "hello"), process: process)
        _ = monitor.evaluateWatchdogTimeoutForTesting(process: process, awaitGracefulExit: { waited = true; return false })
        let stopped = monitor.evaluateWatchdogTimeoutForTesting(process: process, awaitGracefulExit: { waited = true; return false })

        #expect(stopped)
        #expect(process.didRequestGracefulStop, "It is still asked; there is just nothing to wait for")
        #expect(process.didTerminate)
        #expect(waited == false)
    }
}

@Suite("Watchdog deferral tracing")
@MainActor
struct WatchdogDeferralTracingTests {

    /// The unrecognised-stream deferral advances no clock and records no state,
    /// so every poll after the first is identical to it. The watchdog polls at
    /// least every 30 seconds and the outer idle timeout keeps being refreshed
    /// by the very traffic being deferred on, so an untraced-once deferral turns
    /// one useful "the parser is behind" line into hundreds over a long run.
    @Test("A deferral traces once per silence window, not once per poll")
    func deferralTracesOncePerWindow() {
        let monitor = makeMonitor()
        let process = ProgressSignalMockProcess()

        for _ in 0..<64 {
            monitor.recordStreamVolume(bytes: 4_096)
            _ = monitor.processEvent(.unknown(type: "provider.v2_frame"), process: process)
        }

        for _ in 0..<5 {
            #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        }
        let afterFivePolls = monitor.unrecognizedDeferralTraceCount
        #expect(afterFivePolls > 0, "the deferral never traced at all")

        for _ in 0..<45 {
            #expect(monitor.evaluateWatchdogTimeoutForTesting(process: process) == false)
        }
        #expect(monitor.unrecognizedDeferralTraceCount == afterFivePolls)
        #expect(process.didTerminate == false)
    }
}

// MARK: - Review follow-ups: raw stream volume is counted at the pipe

@Suite("Stream volume accounting")
struct StreamVolumeAccountingTests {

    /// Why the byte counter cannot live in the per-line handler: the buffer only
    /// calls it once it finds a newline. A provider streaming one very large
    /// frame — a big tool result, or a JSON object written incrementally — puts
    /// nothing through it for as long as that frame takes, so the tally stays
    /// flat while the pipe is visibly busy and the watchdog reads the run as
    /// silent.
    @Test("A frame with no newline yields no line callbacks")
    func partialFrameProducesNoLineCallbacks() {
        let buffer = AgentLockedBuffer()
        var handled: [String] = []

        buffer.synchronized {
            buffer.appendAndProcessLinesLocked(String(repeating: "x", count: 512 * 1_024)) { handled.append($0) }
        }

        #expect(handled.isEmpty)
        #expect(buffer.value.utf8.count == 512 * 1_024)
    }

    /// So the counter is at the pipe, where bytes arrive when they arrive — and
    /// at the final EOF drain, because `stream_bytes` is also what the exit
    /// audit reports and a tally that stops short of EOF understates every short
    /// run. Pinned in the source: the two call sites are the whole fix, and
    /// nothing observable distinguishes them from the per-line version until a
    /// provider happens to send a multi-megabyte frame.
    @Test("Stream volume is recorded off the pipe, not per parsed line")
    func streamVolumeIsRecordedAtThePipe() throws {
        let runnerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Runtime")
            .appendingPathComponent("AgentRuntimeProcessRunner.swift")
        let source = try String(contentsOf: runnerURL, encoding: .utf8)

        #expect(source.contains("monitor.recordStreamVolume(bytes: data.count)"))
        #expect(source.contains("monitor.recordStreamVolume(bytes: finalStdoutData.count)"))
        #expect(!source.contains("monitor.recordStreamVolume(bytes: line.utf8.count)"))
    }
}
