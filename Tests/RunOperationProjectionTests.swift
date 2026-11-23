import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Issue #477: progress is derived from recorded evidence, and states only
/// what that evidence supports.
@Suite("Run operation projection")
struct RunOperationProjectionTests {
    private typealias Event = RunOperationProjection.Event

    /// Builds a run's stored events with one-second spacing.
    private struct History {
        private(set) var events: [Event] = []
        private var clock = Date(timeIntervalSince1970: 1_000)
        private var pendingRecords: [ToolOperationRecord] = []

        @discardableResult
        mutating func add(_ type: String, _ payload: String) -> UUID {
            let id = UUID()
            clock = clock.addingTimeInterval(1)
            events.append(Event(id: id, type: type, payload: payload, timestamp: clock))
            return id
        }

        @discardableResult
        mutating func use(_ tool: String, _ detail: String? = nil) -> UUID {
            add("tool.use", "Using tool: \(tool)" + (detail.map { ": \($0)" } ?? ""))
        }

        /// Finishes a call the way the recorder does: an optional result row,
        /// then its record.
        mutating func finish(
            _ use: UUID?,
            tool: String? = nil,
            output: String? = "ok",
            outcome: AgentOperationOutcome = .succeeded,
            exitCode: Int? = nil,
            candidates: [UUID]? = nil,
            group: UUID? = nil
        ) {
            var result: UUID?
            if let output {
                result = add(outcome == .failed ? "tool.result.failed" : "tool.result", output)
            } else {
                clock = clock.addingTimeInterval(1)
            }
            let record = ToolOperationRecord(
                callID: "call", tool: tool, outcome: outcome, exitCode: exitCode,
                hasOutput: output != nil, useEventID: use, resultEventID: result, finishedAt: clock,
                groupID: group ?? (candidates == nil ? nil : UUID()), candidateUseEventIDs: candidates
            )
            add(ToolOperationRecord.eventType, TaskEvent.payloadString(ToolOperationBatch(operations: [record])))
        }

        mutating func say(_ text: String) { add("agent.response", text) }

        /// Records as a provider with no call ids leaves them.
        mutating func clearRecordCallIDs() {
            events = events.map { event in
                guard event.type == ToolOperationRecord.eventType,
                      let batch = ToolOperationBatch.decode(from: event.payload) else { return event }
                let records = batch.operations.map {
                    ToolOperationRecord(
                        callID: "", tool: $0.tool, outcome: $0.outcome, exitCode: $0.exitCode,
                        providerStatus: $0.providerStatus, hasOutput: $0.hasOutput, useEventID: $0.useEventID,
                        resultEventID: $0.resultEventID, finishedAt: $0.finishedAt,
                        candidateUseEventIDs: $0.candidateUseEventIDs
                    )
                }
                return Event(id: event.id, type: event.type,
                             payload: TaskEvent.payloadString(ToolOperationBatch(operations: records)), timestamp: event.timestamp)
            }
        }

        /// The same rows as an older build would have left them.
        mutating func dropRecords() { events.removeAll { $0.type == ToolOperationRecord.eventType } }
    }

    @Test("Each call takes the outcome its own record gives, however the results were ordered")
    func operationsAreCorrelatedByRecord() {
        var history = History()
        let read = history.use("Read", "one.swift")
        let bash = history.use("Bash", "swift test")
        history.finish(bash, tool: "Bash", output: "failed", outcome: .failed, exitCode: 1)
        history.finish(read, tool: "Read", output: nil)

        let projection = RunOperationProjection(events: history.events)

        #expect(projection.operations.map(\.tool) == ["Read", "Bash"])
        #expect(projection.operations.map(\.outcome) == [.succeeded, .failed])
        #expect(projection.operations[1].exitCode == 1)
        #expect(projection.finishedCount == 2)
        #expect(projection.failedCount == 1)
        #expect(projection.openOperations.isEmpty)
        #expect(projection.failedUseEventIDs == [bash])
        // Only the result that kept output counts as one.
        #expect(projection.resultsWithOutput == 1)
    }

    @Test("A failure is a milestone of its own, with its exit code and what was run")
    func failureIsAMilestone() throws {
        var history = History()
        let bash = history.use("Bash", "swift test")
        history.finish(bash, tool: "Bash", output: "1 failed", outcome: .failed, exitCode: 1)

        let milestone = try #require(RunOperationProjection(events: history.events).milestones.first)

        #expect(milestone.kind == .operationFailed)
        #expect(milestone.text == "Bash failed · exit code 1 — swift test")
        #expect(milestone.evidenceEventID == history.events.first { $0.type == "tool.result.failed" }?.id)
    }

    @Test("A long stretch of work between agent messages is summarized, failures counted")
    func silentStretchIsSummarized() throws {
        var history = History()
        history.say("Starting the investigation.")
        for index in 0..<6 {
            let use = history.use(index < 4 ? "Read" : "Bash", "item \(index)")
            history.finish(use, tool: index < 4 ? "Read" : "Bash", outcome: index == 5 ? .failed : .succeeded)
        }
        history.say("Found the cause.")

        let projection = RunOperationProjection(events: history.events)
        let summary = try #require(projection.milestones.first { $0.kind == .workSummary })

        #expect(summary.text == "6 operations: Read ×4, Bash ×2 · 1 failed")
        #expect(projection.milestones.filter { $0.kind == .operationFailed }.count == 1)
        // It is placed where the work ended, before the message that follows.
        #expect(summary.timestamp < (projection.lastAgentMessageAt ?? .distantPast))
    }

    @Test("A few calls between messages are not worth a summary line")
    func shortStretchHasNoSummary() {
        var history = History()
        for _ in 0..<(RunOperationProjection.workSummaryThreshold - 1) {
            let use = history.use("Read")
            history.finish(use, tool: "Read")
            history.say("Noted.")
        }

        #expect(RunOperationProjection(events: history.events).milestones.isEmpty)
    }

    @Test("A background job ending is a milestone stating the job's outcome")
    func backgroundJobIsAMilestone() throws {
        var history = History()
        let job = BackgroundJobRecord(AgentBackgroundJobEvent(
            jobID: "job-1", kind: "shell_completed", outcome: .failed, exitCode: 2, summary: "Shell completed"
        ))
        history.add(BackgroundJobRecord.eventType, TaskEvent.payloadString(job))

        let milestone = try #require(RunOperationProjection(events: history.events).milestones.first)

        #expect(milestone.kind == .backgroundJob(.failed))
        #expect(milestone.text == "Background job failed · exit code 2 — Shell completed")
    }

    @Test("A call with no record yet is open; in a history with unrecorded results nothing is claimed")
    func openOperationsNeedCorrelation() {
        var recorded = History()
        let done = recorded.use("Read")
        recorded.finish(done, tool: "Read")
        recorded.use("Bash", "swift test")
        #expect(RunOperationProjection(events: recorded.events).openOperations.map(\.tool) == ["Bash"])

        var beforeFirstResult = History()
        beforeFirstResult.use("Bash", "swift build")
        #expect(RunOperationProjection(events: beforeFirstResult.events).openOperations.count == 1)

        var legacy = History()
        legacy.use("Read")
        legacy.add("tool.result", "ok")
        legacy.use("Bash")
        let projection = RunOperationProjection(events: legacy.events)
        #expect(projection.openOperations.isEmpty)
        #expect(!projection.hasOperationRecords)
        #expect(projection.operations.allSatisfy { $0.outcome == nil })
    }

    @Test("A legacy failed result is still a milestone, without a guessed call")
    func legacyFailureIsStillShown() throws {
        var history = History()
        history.use("Bash", "make")
        history.add("tool.result.failed", #"{"version":2,"toolID":"x","message":"Error 2"}"#)

        let projection = RunOperationProjection(events: history.events)

        #expect(projection.milestones.map(\.text) == ["Tool failed"])
        #expect(projection.failedCount == 0)
    }

    @Test("A record naming a call outside the loaded rows is still a finished operation")
    func orphanRecordIsCounted() throws {
        var history = History()
        // The call's row lies outside the loaded window, or an export left it out.
        history.finish(UUID(), tool: "Bash", output: "boom", outcome: .failed, exitCode: 3)

        let projection = RunOperationProjection(events: history.events)

        #expect(projection.operations.count == 1)
        #expect(projection.operations.first?.startedAt == nil)
        #expect(projection.failedCount == 1)
        #expect(projection.resultsWithOutput == 1)
        #expect(projection.milestones.map(\.text) == ["Bash failed · exit code 3"])
    }

    @Test("A record naming no call adds its outcome to a call already counted")
    func unattributedRecordIsNotASecondOperation() {
        var history = History()
        let first = history.use("bash", "make a")
        let second = history.use("bash", "make b")
        let unrelated = history.use("Read", "notes.md")
        // Two calls shared the id, so the record names its candidates instead.
        history.finish(nil, tool: "bash", output: "ok", candidates: [first, second])

        let projection = RunOperationProjection(events: history.events)

        #expect(projection.totalCount == 3)
        #expect(projection.finishedCount == 1)
        // One of the pair is still open, which one is unknown: counted, not
        // listed. The unrelated call is untouched.
        #expect(projection.unidentifiedOpenCount == 1)
        #expect(projection.openOperations.map(\.id) == [unrelated])
    }

    @Test("A call that joins a group later is counted with it, not as a second group")
    func lateMemberJoinsItsGroup() {
        var history = History()
        let group = UUID()
        let first = history.use("bash", "a")
        let second = history.use("bash", "b")
        history.finish(nil, tool: "bash", candidates: [first, second], group: group)
        // A third call opens under the same id before the group has emptied.
        let third = history.use("bash", "c")
        history.finish(nil, tool: "bash", candidates: [third], group: group)
        history.finish(nil, tool: "bash", candidates: [], group: group)

        let projection = RunOperationProjection(events: history.events)

        #expect(projection.totalCount == 3)
        #expect(projection.finishedCount == 3)
        #expect(projection.unidentifiedOpenCount == 0)
        #expect(projection.openOperations.isEmpty)
    }

    @Test("A group's results never finish more calls than the group had")
    func groupClosuresAreBounded() {
        var history = History()
        let first = history.use("bash", "a")
        let second = history.use("bash", "b")
        let group = UUID()
        history.finish(nil, tool: "bash", candidates: [first, second], group: group)
        history.finish(nil, tool: "bash", candidates: [], group: group)

        let projection = RunOperationProjection(events: history.events)

        #expect(projection.totalCount == 2)
        #expect(projection.finishedCount == 2)
        #expect(projection.unidentifiedOpenCount == 0)
        #expect(projection.openOperations.isEmpty)
        // Their records are evidence, so the summary states what finished.
        #expect(projection.hasOperationRecords)
        #expect(RunOperationsPresentation(run: Self.run(status: .completed), projection: projection).summaryLine
            == "2 operations · 2 finished")
    }

    @Test("A call that finished without output moves the last recorded activity to its finish")
    func silentCompletionIsRecordedActivity() throws {
        var history = History()
        let use = history.use("Bash", "true")
        history.finish(use, tool: "Bash", output: nil)

        let projection = RunOperationProjection(events: history.events)
        let record = try #require(history.events.last)

        #expect(projection.lastOperationEventAt == ToolOperationBatch.decode(from: record.payload)?.operations.first?.finishedAt)
        #expect(projection.lastOperationEventAt.map { $0 > history.events[0].timestamp } == true)
    }

    @Test("A result with no recorded call is an operation of its own, and closes no other call")
    func idLessRecordIsNotASecondOperation() {
        // Codex reports a `file_change` only by its result: no call was ever
        // open for it. It must not close the command that is still running.
        var history = History()
        let command = history.use("command_execution", "swift test")
        history.finish(nil, tool: "file_change", output: "failed", outcome: .failed, exitCode: 2)
        history.clearRecordCallIDs()

        let projection = RunOperationProjection(events: history.events)

        #expect(projection.totalCount == 2)
        #expect(projection.finishedCount == 1)
        #expect(projection.failedCount == 1)
        #expect(projection.finishedCount <= projection.totalCount)
        #expect(projection.openOperations.map(\.id) == [command])
        #expect(projection.milestones.map(\.text) == ["file_change failed · exit code 2"])
    }

    @Test("The same history always yields the same milestone ids")
    func milestoneIDsAreStable() {
        var history = History()
        for _ in 0..<6 {
            let use = history.use("Bash", "x")
            history.finish(use, tool: "Bash", outcome: .failed, exitCode: 1)
        }

        let first = RunOperationProjection(events: history.events)
        let second = RunOperationProjection(events: history.events)

        #expect(first == second)
        #expect(Set(first.milestones.map(\.id)).count == first.milestones.count)
    }

    // MARK: - Answer selection

    /// The two cases below end with a long draft, a file write, and a short
    /// sign-off: one answer, as long as the write's result is read as the
    /// write's. Paired by arrival order it was taken for an earlier read's,
    /// counted as work, and the draft was dropped from the answer.
    private static func answerRows(_ history: History) -> [[UUID]]? {
        RunAnswerSelectionPolicy.legacySelection(
            history.events.map { RunAnswerSelectionPolicy.Event(id: $0.id, type: $0.type, payload: $0.payload) }
        )?.answer
    }

    @Test("A call that finished without output does not answer a later call's result")
    func silentCallDoesNotStealALaterResult() throws {
        var history = History()
        let read = history.use("Read", "notes.swift")
        history.finish(read, tool: "Read", output: nil)
        history.say(String(repeating: "Draft. ", count: 200))
        let write = history.use("Write", "answer.md")
        history.finish(write, tool: "Write", output: "written")
        history.say("Saved.")
        let messages = history.events.filter { $0.type == "agent.response" }.map(\.id)

        #expect(Self.answerRows(history) == [[messages[0]], [messages[1]]])

        // The same rows without records keep the old reading: nothing says
        // the read finished, so the write's result is taken for the read's.
        history.dropRecords()
        #expect(Self.answerRows(history) == [[messages[1]]])
    }

    @Test("A result that arrives before an older call's is still its own call's")
    func outOfOrderResultIsClassifiedByItsCall() throws {
        var history = History()
        let read = history.use("Read", "slow.swift")
        history.say(String(repeating: "Draft. ", count: 200))
        let write = history.use("Write", "answer.md")
        history.finish(write, tool: "Write", output: "written")
        history.say("Saved.")
        // The read's result arrives last of all.
        history.finish(read, tool: "Read", output: "contents")
        let messages = history.events.filter { $0.type == "agent.response" }.map(\.id)

        #expect(Self.answerRows(history) == [[messages[0]], [messages[1]]])

        history.dropRecords()
        #expect(Self.answerRows(history) == [[messages[1]]])
    }

    @Test("Part of a history is counted as part, never stated as the run's total")
    func partialHistoryIsLabelled() {
        var history = History()
        let use = history.use("Read")
        history.finish(use, tool: "Read")
        let events = history.events.map { TaskEventSnapshotBuilder.event($0) }

        let whole = RunOperationsPresentation(run: Self.run(status: .completed), events: events)
        let partial = RunOperationsPresentation(run: Self.run(status: .completed), events: events, historyIsPartial: true)

        #expect(whole.summaryLine == "1 operation · 1 finished")
        #expect(partial.summaryLine == "1 operation in the loaded history · 1 finished")
    }

    // MARK: - Presentation

    @Test("Observed milestones join the agent's messages in time order, the agent first at a tie")
    func timelineMergesByTime() {
        let base = Date(timeIntervalSince1970: 5_000)
        let agent = [
            TaskRunProgressMessage(id: UUID(), text: "Looking.", timestamp: base),
            TaskRunProgressMessage(id: UUID(), text: "Fixing.", timestamp: base.addingTimeInterval(20))
        ]
        var history = History()
        let use = history.use("Bash", "swift test")
        history.finish(use, tool: "Bash", output: "failed", outcome: .failed, exitCode: 1)
        let projection = RunOperationProjection(events: history.events.map {
            RunOperationProjection.Event(id: $0.id, type: $0.type, payload: $0.payload, timestamp: base.addingTimeInterval(10))
        })
        let operations = RunOperationsPresentation(run: Self.run(status: .completed), projection: projection)

        let timeline = operations.timeline(merging: agent)

        #expect(timeline.map(\.text) == ["Looking.", "Bash failed · exit code 1 — swift test", "Fixing."])
        #expect(timeline.map(\.origin) == [.agent, .observedFailure, .agent])
        #expect(RunOperationsPresentation.empty.timeline(merging: agent) == agent)
    }

    @Test("Freshness is stated as what it is: live traffic, or the last recorded event")
    func freshnessDistinguishesLiveFromRecorded() {
        let now = Date(timeIntervalSince1970: 9_000)
        var history = History()
        history.say("Starting.")
        history.use("Bash", "swift test")
        let projection = RunOperationProjection(events: history.events.map {
            RunOperationProjection.Event(id: $0.id, type: $0.type, payload: $0.payload, timestamp: now.addingTimeInterval(-600))
        })
        let running = RunOperationsPresentation(run: Self.run(status: .running), projection: projection)

        let live = RunLiveActivity(lastTrafficAt: now.addingTimeInterval(-12))
        #expect(running.freshnessLine(now: now, live: live) == "Last activity 12s ago · last update from the agent 10m ago")
        // After a relaunch there is no live stream to speak of.
        #expect(running.freshnessLine(now: now, live: nil) == "Last recorded activity 10m ago · last update from the agent 10m ago")

        let ended = RunOperationsPresentation(run: Self.run(status: .completed), projection: projection)
        #expect(ended.freshnessLine(now: now, live: live) == nil)
        #expect(ended.inFlightCount == 0)
    }

    @Test("Ages read as seconds, minutes, then hours")
    func ageFormatting() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(RunOperationsPresentation.age(since: now.addingTimeInterval(-5), now: now) == "5s")
        #expect(RunOperationsPresentation.age(since: now.addingTimeInterval(-125), now: now) == "2m")
        #expect(RunOperationsPresentation.age(since: now.addingTimeInterval(-3_600), now: now) == "1h")
        #expect(RunOperationsPresentation.age(since: now.addingTimeInterval(-3_900), now: now) == "1h 5m")
        #expect(RunOperationsPresentation.age(since: now.addingTimeInterval(30), now: now) == "0s")
    }

    private static func run(status: RunStatus) -> TaskRunSnapshot {
        let task = AgentTask(title: "Task", goal: "Goal")
        let run = TaskRun(task: task)
        run.status = status
        return TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))
    }
}

private enum TaskEventSnapshotBuilder {
    static func event(_ event: RunOperationProjection.Event) -> TaskEventSnapshot {
        let task = AgentTask(title: "Task", goal: "Goal")
        let stored = TaskEvent(task: task, type: event.type, payload: event.payload)
        // Records name rows by id, so the rebuilt rows keep theirs.
        stored.id = event.id
        stored.timestamp = event.timestamp
        return TaskEventSnapshot(event: stored)
    }
}

@Suite("Run live activity")
struct RunLiveActivityStoreTests {
    @Test("Each run has its own live activity, and none after its stream ends")
    func liveActivityIsScopedToItsRun() {
        let store = RunLiveActivityStore()
        let (first, second) = (UUID(), UUID())
        let start = Date(timeIntervalSince1970: 1_000)

        store.observe(.toolUse(name: "Bash", id: "call-1", inputSummary: nil), runID: first, at: start)
        store.observe(.control(type: "tool.execution_partial_result"), runID: first, at: start.addingTimeInterval(30))

        #expect(store.activity(for: first)?.lastTrafficAt == start.addingTimeInterval(30))
        #expect(store.activity(for: first)?.lastOperationSignalAt == start)
        #expect(store.activity(for: first)?.activeOperationID == "call-1")
        #expect(store.activity(for: second) == nil)

        store.observe(.toolResult(id: "call-1", content: "", isError: false), runID: first, at: start.addingTimeInterval(40))
        #expect(store.activity(for: first)?.activeOperationID == nil)

        store.finish(runID: first)
        #expect(store.activity(for: first) == nil)
    }

    @Test("Live operation activity after a warning is recovery, not a stall")
    func liveActivityRecoversFromAWarning() {
        let now = Date(timeIntervalSince1970: 60_000)
        let task = AgentTask(title: "Task", goal: "Goal")
        task.status = .running
        let run = TaskRun(task: task)
        run.status = .running
        run.startedAt = now.addingTimeInterval(-1_200)
        let warning = TaskEvent(task: task, type: "permission.denied", payload: "Permission denied for tool: Bash. blocked", run: run)
        warning.timestamp = now.addingTimeInterval(-600)
        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: [warning], runs: [run])

        let stalled = TaskRuntimeHealth.evaluate(taskStatus: .running, snapshot: snapshot, now: now)
        let recovering = TaskRuntimeHealth.evaluate(
            taskStatus: .running, snapshot: snapshot, now: now,
            liveActivity: RunLiveActivity(lastTrafficAt: now, lastOperationSignalAt: now.addingTimeInterval(-15))
        )

        #expect(stalled.state == .possiblyStalled)
        #expect(recovering.state == .recoveredWarning)
    }

    @Test("Live operation activity keeps a streaming run from reading as quiet")
    func liveActivityKeepsHealthActive() {
        let now = Date(timeIntervalSince1970: 50_000)
        let task = AgentTask(title: "Task", goal: "Goal")
        task.status = .running
        let run = TaskRun(task: task)
        run.status = .running
        run.startedAt = now.addingTimeInterval(-1_200)
        let stale = TaskEvent(task: task, type: "tool.use", payload: "Using tool: Bash: swift test", run: run)
        stale.timestamp = now.addingTimeInterval(-900)
        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: [stale], runs: [run])

        let withoutLive = TaskRuntimeHealth.evaluate(taskStatus: .running, snapshot: snapshot, now: now)
        let withLive = TaskRuntimeHealth.evaluate(
            taskStatus: .running,
            snapshot: snapshot,
            now: now,
            liveActivity: RunLiveActivity(lastTrafficAt: now, lastOperationSignalAt: now.addingTimeInterval(-20))
        )

        #expect(withoutLive.state == .quiet)
        #expect(withLive.state == .active)
        #expect(withLive.lastRuntimeProgressAt == now.addingTimeInterval(-20))
    }

    @Test("A failed result and an operation record count as runtime progress")
    func failedResultsAreProgress() {
        let now = Date(timeIntervalSince1970: 50_000)
        for type in ["tool.result.failed", ToolOperationRecord.eventType, BackgroundJobRecord.eventType] {
            let task = AgentTask(title: "Task", goal: "Goal")
            task.status = .running
            let run = TaskRun(task: task)
            run.status = .running
            run.startedAt = now.addingTimeInterval(-1_200)
            let event = TaskEvent(task: task, type: type, payload: "{}", run: run)
            event.timestamp = now.addingTimeInterval(-30)
            let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: [event], runs: [run])

            #expect(TaskRuntimeHealth.evaluate(taskStatus: .running, snapshot: snapshot, now: now).state == .active, "\(type)")
        }
    }
}
