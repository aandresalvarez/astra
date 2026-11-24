import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Issue #477: a tool operation's identity and outcome have to survive
/// recording, so a result can be matched to its call after a task is reopened
/// and an operation that printed nothing still leaves evidence it finished.
@MainActor
@Suite("Tool operation recording")
struct ToolOperationRecordingTests {
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let task: AgentTask
        let run: TaskRun
        let state = AgentEventRecordingState()

        var context: ModelContext { container.mainContext }

        init() throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            task = AgentTask(title: "Operations", goal: "Run things")
            run = TaskRun(task: task)
            container.mainContext.insert(task)
            container.mainContext.insert(run)
        }

        func record(_ events: AgentEvent...) {
            for event in events {
                AgentEventRecorder.recordCodexEvent(event, to: task, run: run, modelContext: context, recordingState: state)
            }
        }

        func events(_ type: TaskEventType) -> [TaskEvent] {
            task.events.filter { $0.type == type.rawValue }.sorted { $0.timestamp < $1.timestamp }
        }

        var operations: [ToolOperationRecord] {
            events(TaskEventTypes.Tool.operation).flatMap { ToolOperationBatch.decode(from: $0.payload)?.operations ?? [] }
        }
    }

    @Test("A result is recorded with the call id and the rows of its call and its output")
    func resultKeepsCallIdentity() throws {
        let fixture = try Fixture()

        fixture.record(
            .toolUse(name: "Bash", id: "call-1", inputSummary: "swift build"),
            .toolResult(id: "call-1", content: "Build complete", isError: false)
        )

        let use = try #require(fixture.events(TaskEventTypes.Tool.use).first)
        let result = try #require(fixture.events(TaskEventTypes.Tool.result).first)
        let record = try #require(fixture.operations.first)
        #expect(fixture.operations.count == 1)
        #expect(record.callID == "call-1")
        #expect(record.tool == "Bash")
        #expect(record.outcome == .succeeded)
        #expect(record.hasOutput)
        #expect(record.useEventID == use.id)
        #expect(record.resultEventID == result.id)
        // The rows the existing readers parse are unchanged.
        #expect(use.payload == "Using tool: Bash: swift build")
        #expect(result.payload == "Build complete")
    }

    @Test("An operation that printed nothing still leaves durable evidence that it finished")
    func emptyResultIsStillRecorded() throws {
        let fixture = try Fixture()

        fixture.record(
            .toolUse(name: "write_file", id: "step-4", inputSummary: "notes.md"),
            .toolResult(id: "step-4", content: "", isError: false)
        )

        #expect(fixture.events(TaskEventTypes.Tool.result).isEmpty)
        let record = try #require(fixture.operations.first)
        #expect(record.outcome == .succeeded)
        #expect(!record.hasOutput)
        #expect(record.resultEventID == nil)
        #expect(record.useEventID == fixture.events(TaskEventTypes.Tool.use).first?.id)
        #expect(record.finishedAt != nil)
    }

    @Test("Results that arrive out of order are tied to their own calls")
    func outOfOrderResultsKeepTheirCalls() throws {
        let fixture = try Fixture()

        fixture.record(
            .toolUse(name: "Read", id: "a", inputSummary: "one.swift"),
            .toolUse(name: "Bash", id: "b", inputSummary: "swift test"),
            .toolResult(id: "b", content: "tests failed", isError: true),
            .toolResult(id: "a", content: "contents", isError: false)
        )

        let uses = fixture.events(TaskEventTypes.Tool.use)
        let readUse = try #require(uses.first { $0.payload.contains("Read") })
        let bashUse = try #require(uses.first { $0.payload.contains("Bash") })
        let byCall = Dictionary(uniqueKeysWithValues: fixture.operations.map { ($0.callID, $0) })
        #expect(byCall["a"]?.useEventID == readUse.id)
        #expect(byCall["a"]?.outcome == .succeeded)
        #expect(byCall["b"]?.useEventID == bashUse.id)
        #expect(byCall["b"]?.outcome == .failed)
        #expect(byCall["b"]?.resultEventID == fixture.events(TaskEventTypes.Tool.resultFailed).first?.id)
    }

    @Test("A provider repeating an open call updates one row instead of adding calls")
    func repeatedOpenCallIsOneOperation() throws {
        let fixture = try Fixture()

        fixture.record(.toolUse(name: "bash", id: "part-1", inputSummary: nil))
        let startedAt = try #require(fixture.events(TaskEventTypes.Tool.use).first?.timestamp)
        fixture.record(
            .toolUse(name: "bash", id: "part-1", inputSummary: "sleep 1"),
            .toolUse(name: "bash", id: "part-1", inputSummary: "sleep 1"),
            .toolResult(id: "part-1", content: "", isError: false)
        )

        let uses = fixture.events(TaskEventTypes.Tool.use)
        #expect(uses.count == 1)
        #expect(uses.first?.payload == "Using tool: bash: sleep 1")
        // The row keeps the time the call started.
        #expect(uses.first?.timestamp == startedAt)
        #expect(fixture.operations.count == 1)
    }

    @Test("An id that is only the tool's name does not merge two calls")
    func nameFallbackIDIsNotAnIdentity() throws {
        let fixture = try Fixture()

        // A parser with no call id to go on uses the tool's name; two
        // overlapping calls then share it.
        fixture.record(
            .toolUse(name: "shellToolCall", id: "shellToolCall", inputSummary: "make a"),
            .toolUse(name: "shellToolCall", id: "shellToolCall", inputSummary: "make b")
        )

        #expect(fixture.events(TaskEventTypes.Tool.use).map(\.payload).sorted() == [
            "Using tool: shellToolCall: make a", "Using tool: shellToolCall: make b"
        ])

        // Their results cannot say which call finished, so neither is named,
        // and neither outcome is pinned on the wrong call.
        fixture.record(
            .toolResult(id: "shellToolCall", content: "a failed", isError: true),
            .toolResult(id: "shellToolCall", content: "b done", isError: false)
        )
        #expect(fixture.operations.count == 2)
        #expect(fixture.operations.allSatisfy { $0.useEventID == nil })
        try fixture.context.save()
        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        #expect(operations.totalCount == 2)
        #expect(operations.finishedCount == 2)
        #expect(operations.failedCount == 1)
    }

    @Test("A denied call is closed by its denial, once, and is not left in flight")
    func deniedCallIsClosed() throws {
        let fixture = try Fixture()
        fixture.run.status = .running
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Permission denied: Bash is not allowed here","is_error":true}]}}"#

        fixture.record(.toolUse(name: "Bash", id: "toolu_1", inputSummary: "rm -rf build"))
        // Claude reports the denial as a denial plus a marker naming the call;
        // both arrive, and only one may close it.
        for parsed in StreamEventParser.parseAll(line: line) {
            for event in AgentEventRecorder.agentEvents(from: parsed) { fixture.record(event) }
        }

        let record = try #require(fixture.operations.first)
        #expect(fixture.operations.count == 1)
        #expect(record.outcome == .failed)
        #expect(record.providerStatus == ToolOperationRecord.deniedStatus)
        #expect(record.useEventID == fixture.events(TaskEventTypes.Tool.use).first?.id)
        #expect(record.failureSummary == "Bash was denied permission")
        try fixture.context.save()
        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        #expect(operations.inFlightCount == 0)
        #expect(operations.failedCount == 1)
    }

    @Test("A denial by tool name closes the run's one open call that had no id")
    func denialClosesAnIDLessCall() throws {
        let fixture = try Fixture()
        fixture.run.status = .running

        fixture.record(
            .toolUse(name: "shell", id: "", inputSummary: "rm -rf build"),
            .permissionRequested(tool: "shell", reason: "not allowed")
        )

        let record = try #require(fixture.operations.first)
        #expect(fixture.operations.count == 1)
        #expect(record.outcome == .failed)
        #expect(record.providerStatus == ToolOperationRecord.deniedStatus)
        #expect(record.tool == "shell")
        #expect(record.useEventID == fixture.events(TaskEventTypes.Tool.use).first?.id)
        try fixture.context.save()
        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        #expect(operations.inFlightCount == 0)
        #expect(operations.failedCount == 1)
    }

    @Test("A denial that names no open call adds no record")
    func denialWithoutAnOpenCallAddsNothing() throws {
        let fixture = try Fixture()

        fixture.record(
            .toolUse(name: "Bash", id: "a", inputSummary: "one"),
            .toolUse(name: "Bash", id: "b", inputSummary: "two"),
            // Two open Bash calls: the name alone does not say which.
            .permissionRequested(tool: "Bash", reason: "not allowed")
        )

        #expect(fixture.operations.isEmpty)
    }

    @Test("ASTRA's own notes in the tool rows are not provider operations")
    func astraNotesAreNotOperations() throws {
        let fixture = try Fixture()
        fixture.run.status = .running
        for payload in ["Isolation: copy -> /tmp/work", "Running validation tests...", "Running AI self-check..."] {
            fixture.context.insert(TaskEvent(task: fixture.task, eventType: TaskEventTypes.Tool.use, payload: payload, run: fixture.run))
        }
        fixture.record(.toolUse(name: "Bash", id: "open", inputSummary: "swift test"))
        try fixture.context.save()

        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations

        #expect(operations.totalCount == 1)
        #expect(operations.inFlight.map(\.tool) == ["Bash"])
    }

    @Test("A batch row stays under the size the task mirror exports whole")
    func batchRowsStayExportable() throws {
        let fixture = try Fixture()
        let longName = String(repeating: "mcp__server__tool_", count: 12)

        // Long names fill a row by size well before it reaches its count.
        for index in 0..<ToolOperationBatch.capacity {
            let id = "call-\(index)-\(UUID().uuidString)"
            fixture.record(
                .toolUse(name: longName, id: id, inputSummary: nil),
                .toolResult(id: id, content: "ok", isError: false)
            )
        }

        let rows = fixture.events(TaskEventTypes.Tool.operation)
        #expect(rows.count > 1)
        #expect(fixture.operations.count == ToolOperationBatch.capacity)
        #expect(rows.allSatisfy { $0.payload.count <= ToolOperationBatch.payloadCharacterLimit })
        #expect(rows.allSatisfy { ToolOperationBatch.decode(from: $0.payload) != nil })
    }

    @Test("A group larger than one record can list is still counted whole")
    func largeGroupIsCountedWhole() throws {
        let fixture = try Fixture()
        fixture.run.status = .running
        let count = ToolOperationRecord.candidatesPerRecord + 6

        for index in 0..<count { fixture.record(.toolUse(name: "tool", id: "", inputSummary: "call \(index)")) }
        // A call that joins once results have started belongs to the group too.
        fixture.record(.toolResult(id: "", content: "", isError: false))
        fixture.record(.toolUse(name: "tool", id: "", inputSummary: "late"))
        for _ in 0..<count { fixture.record(.toolResult(id: "", content: "", isError: false)) }

        #expect(fixture.operations.allSatisfy { ($0.candidateUseEventIDs?.count ?? 0) <= ToolOperationRecord.candidatesPerRecord })
        #expect(Set(fixture.operations.compactMap(\.groupID)).count == 1)
        try fixture.context.save()
        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        #expect(operations.totalCount == count + 1)
        #expect(operations.finishedCount == count + 1)
        #expect(operations.inFlightCount == 0)
    }

    @Test("A call id used again after its result is a new operation")
    func reusedCallIDAfterResultIsANewOperation() throws {
        let fixture = try Fixture()

        fixture.record(
            .toolUse(name: "bash", id: "bash", inputSummary: "one"),
            .toolResult(id: "bash", content: "1", isError: false),
            .toolUse(name: "bash", id: "bash", inputSummary: "two"),
            .toolResult(id: "bash", content: "2", isError: false)
        )

        #expect(fixture.events(TaskEventTypes.Tool.use).count == 2)
        #expect(fixture.operations.count == 2)
        #expect(Set(fixture.operations.compactMap(\.useEventID)).count == 2)
    }

    @Test("The provider's own exit code and status are kept as fields")
    func providerStatusAndExitCodeAreRecorded() throws {
        let fixture = try Fixture()
        let line = #"{"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","command":"swift test","exit_code":1,"status":"failed","aggregated_output":"Test failed"}}"#

        fixture.record(.toolUse(name: "command_execution", id: "cmd-1", inputSummary: "swift test"))
        for event in CodexStreamEventParser.parseIdentifiedAgentEvents(line: line) { fixture.record(event) }

        let record = try #require(fixture.operations.first)
        #expect(record.outcome == .failed)
        #expect(record.exitCode == 1)
        #expect(record.providerStatus == "failed")
        #expect(record.failureSummary == "command_execution failed · exit code 1")
    }

    @Test("A cancelled call stays a cancellation, though its result is an error")
    func cancelledCallStaysCancelled() throws {
        let fixture = try Fixture()
        let line = #"{"type":"item.completed","item":{"id":"cmd-9","type":"command_execution","command":"swift test","exit_code":130,"status":"cancelled","aggregated_output":""}}"#

        fixture.record(.toolUse(name: "command_execution", id: "cmd-9", inputSummary: "swift test"))
        for event in CodexStreamEventParser.parseIdentifiedAgentEvents(line: line) { fixture.record(event) }

        let record = try #require(fixture.operations.first)
        #expect(record.outcome == .cancelled)
        #expect(record.failureSummary == "command_execution was cancelled · exit code 130")
    }

    @Test("A result for a call never recorded as open lists no candidates and names no call")
    func unmatchedResultIsItsOwnOperation() throws {
        let fixture = try Fixture()
        fixture.run.status = .running

        fixture.record(
            .toolUse(name: "command_execution", id: "cmd-1", inputSummary: "swift test"),
            .toolResult(id: "item_6", content: "", isError: false)
        )

        let record = try #require(fixture.operations.first)
        #expect(record.useEventID == nil)
        #expect(record.candidateUseEventIDs == nil)
        try fixture.context.save()
        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        #expect(operations.totalCount == 2)
        #expect(operations.finishedCount == 1)
        #expect(operations.inFlight.map(\.tool) == ["command_execution"])
    }

    @Test("A status the provider reported as unknown is not recorded as success")
    func unknownProviderStatusStaysUnknown() throws {
        let fixture = try Fixture()

        fixture.record(
            .toolUse(name: "task", id: "t-1", inputSummary: nil),
            .operation(.finished(operationID: "t-1", outcome: .unknown, exitCode: nil, providerStatus: "deferred")),
            .toolResult(id: "t-1", content: "", isError: false)
        )

        #expect(fixture.operations.first?.outcome == .unknown)
        #expect(fixture.operations.first?.providerStatus == "deferred")
    }

    @Test("A result with no call id finishes the run's one open call that had no id either")
    func resultWithoutCallIDFinishesTheOnlyUnnamedCall() throws {
        let fixture = try Fixture()

        fixture.record(
            .toolUse(name: "tool", id: "", inputSummary: "something"),
            .toolResult(id: "", content: "done", isError: false)
        )

        let record = try #require(fixture.operations.first)
        #expect(record.callID.isEmpty)
        #expect(record.useEventID == fixture.events(TaskEventTypes.Tool.use).first?.id)
        #expect(record.resultEventID != nil)
    }

    @Test("With two unnamed calls open, an id-less result names neither, and still counts once")
    func ambiguousUnnamedResultNamesNoCall() throws {
        let fixture = try Fixture()
        fixture.run.status = .running

        fixture.record(
            .toolUse(name: "tool", id: "", inputSummary: "first"),
            .toolUse(name: "tool", id: "", inputSummary: "second"),
            .toolResult(id: "", content: "done", isError: false)
        )

        #expect(fixture.operations.first?.useEventID == nil)
        // The record lists the calls it may have been, so a reader can count
        // it against them and nothing else.
        #expect(Set(fixture.operations.first?.candidateUseEventIDs ?? []) == Set(fixture.events(TaskEventTypes.Tool.use).map(\.id)))
        try fixture.context.save()
        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        // Two calls, one of which finished; never three operations.
        #expect(operations.totalCount == 2)
        #expect(operations.finishedCount == 1)
        #expect(operations.inFlightCount == 1)
    }

    @Test("Partial output refreshes liveness and stores nothing")
    func progressSignalIsNotDurable() throws {
        let fixture = try Fixture()
        fixture.record(.toolUse(name: "Bash", id: "call-1", inputSummary: "swift test"))
        let before = fixture.task.events.count

        for _ in 0..<50 { fixture.record(.operation(.progress(operationID: "call-1"))) }

        #expect(fixture.task.events.count == before)
        #expect(fixture.operations.isEmpty)
        #expect(RunLiveActivityStore.shared.activity(for: fixture.run.id)?.activeOperationID == "call-1")
    }

    @Test("A background job ending is its own record, never an assistant update")
    func backgroundJobIsNotAssistantText() throws {
        let fixture = try Fixture()
        let line = #"{"type":"system.notification","data":{"content":"<system_notification>Shell completed</system_notification>","kind":{"type":"shell_completed","shellId":"job-1","exitCode":1}}}"#

        for event in CopilotStreamEventParser.parseIdentifiedAgentEvents(line: line) { fixture.record(event) }

        #expect(fixture.events(TaskEventTypes.Conversation.agentResponse).isEmpty)
        #expect(fixture.run.output.isEmpty)
        let event = try #require(fixture.events(TaskEventTypes.Tool.backgroundJob).first)
        let job = try #require(BackgroundJobRecord.decode(from: event.payload))
        #expect(job.jobID == "job-1")
        #expect(job.outcome == .failed)
        #expect(job.exitCode == 1)
        #expect(job.summary == "Shell completed")
        #expect(!event.payload.contains("<system_notification>"))
        // The job ending is not the launching call finishing.
        #expect(fixture.operations.isEmpty)
    }

    @Test("A run's records fill a row to its capacity and then start another")
    func recordsAreBatchedPerRun() throws {
        let fixture = try Fixture()
        let count = ToolOperationBatch.capacity + 3

        for index in 0..<count {
            fixture.record(
                .toolUse(name: "Read", id: "call-\(index)", inputSummary: "file-\(index)"),
                .toolResult(id: "call-\(index)", content: "ok", isError: false)
            )
        }

        let rows = fixture.events(TaskEventTypes.Tool.operation)
        #expect(rows.count == 2)
        #expect(fixture.operations.count == count)
        #expect(fixture.operations.map(\.callID) == (0..<count).map { "call-\($0)" })
    }

    @Test("Another run of the same task keeps its own records")
    func recordsAreScopedToTheirRun() throws {
        let fixture = try Fixture()
        let secondRun = TaskRun(task: fixture.task)
        fixture.context.insert(secondRun)

        fixture.record(
            .toolUse(name: "Read", id: "shared-id", inputSummary: "a"),
            .toolResult(id: "shared-id", content: "ok", isError: false)
        )
        AgentEventRecorder.recordCodexEvent(
            .toolResult(id: "shared-id", content: "late", isError: false),
            to: fixture.task, run: secondRun, modelContext: fixture.context, recordingState: fixture.state
        )

        let secondRunRecords = fixture.events(TaskEventTypes.Tool.operation)
            .filter { $0.run?.id == secondRun.id }
            .flatMap { ToolOperationBatch.decode(from: $0.payload)?.operations ?? [] }
        #expect(secondRunRecords.count == 1)
        // The first run's call must not be claimed by the second run's result.
        #expect(secondRunRecords.first?.useEventID == nil)
    }

    @Test("The stream ending clears the run's live activity")
    func streamEndClearsLiveActivity() throws {
        let fixture = try Fixture()
        fixture.record(.toolUse(name: "Bash", id: "call-1", inputSummary: "swift test"))
        #expect(RunLiveActivityStore.shared.activity(for: fixture.run.id) != nil)

        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state, task: fixture.task, run: fixture.run,
            modelContext: fixture.context, processExitedCleanly: true
        )

        #expect(RunLiveActivityStore.shared.activity(for: fixture.run.id) == nil)
    }

    // MARK: - Reopen: stored events → snapshot → presentation

    @Test("Reopening a task rebuilds the same operation history from its stored events")
    func reopenRebuildsOperationHistory() throws {
        let fixture = try Fixture()
        fixture.record(
            .toolUse(name: "Read", id: "a", inputSummary: "one.swift"),
            .toolUse(name: "Bash", id: "b", inputSummary: "swift test"),
            .toolResult(id: "b", content: "1 test failed", isError: true),
            .toolResult(id: "a", content: "", isError: false),
            .operation(.backgroundJobFinished(AgentBackgroundJobEvent(
                jobID: "job-1", kind: "shell_completed", outcome: .succeeded, exitCode: 0, summary: "Build finished"
            )))
        )
        fixture.run.status = .completed
        fixture.run.completedAt = Date()
        try fixture.context.save()

        // A fresh recording state knows nothing: everything below comes from
        // what was stored.
        let first = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run)
        let second = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run)

        #expect(first.operations == second.operations)
        #expect(first.operations.totalCount == 2)
        #expect(first.operations.finishedCount == 2)
        #expect(first.operations.failedCount == 1)
        #expect(first.operations.inFlightCount == 0)
        #expect(first.operations.summaryLine == "2 operations · 2 finished · 1 failed")
        // The agent said nothing, and what it said is still kept apart from
        // what was observed: the Updates tab lists the observed lines without
        // counting them as the agent's updates.
        #expect(first.progressMessages.isEmpty)
        let updates = try #require(first.tabDescriptors(hasPlanItems: false).first { $0.tab == .updates })
        #expect(updates.count == nil)
        #expect(!first.timeline.isEmpty)
        let lines = first.timeline.map(\.text)
        #expect(lines.contains("Bash failed — swift test"))
        #expect(lines.contains("Background job completed · exit code 0 — Build finished"))
        #expect(first.timeline.first { $0.text.hasPrefix("Bash failed") }?.origin == .observedFailure)
        // The failed result reaches the details with its original evidence.
        #expect(first.technicalOutputs.contains { $0.title == "Failed tool result" && $0.rawPayload.contains("1 test failed") })
        #expect(first.tools.first { $0.toolName == "Bash" }?.countLabel == "1 call · 1 failed")
    }

    @Test("A failed result stays visible when more than twelve later results exist")
    func failureSurvivesTheResultDisplayCap() throws {
        let fixture = try Fixture()
        fixture.record(
            .toolUse(name: "Bash", id: "early", inputSummary: "make"),
            .toolResult(id: "early", content: "make: *** [all] Error 2", isError: true)
        )
        for index in 0..<20 {
            fixture.record(
                .toolUse(name: "Read", id: "r-\(index)", inputSummary: "f\(index)"),
                .toolResult(id: "r-\(index)", content: "contents \(index)", isError: false)
            )
        }
        fixture.run.status = .completed
        try fixture.context.save()

        let presentation = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run)

        #expect(presentation.technicalOutputs.contains { $0.rawPayload.contains("Error 2") })
        #expect(presentation.timeline.contains { $0.text == "Bash failed — make" })
        // What is shown is told apart from what was recorded.
        let logs = try #require(presentation.tabDescriptors(hasPlanItems: false).first { $0.tab == .logs })
        #expect(logs.total == 21)
        #expect((logs.count ?? 0) < 21)
        #expect(logs.countText == "\(logs.count ?? 0) of 21")
    }

    @Test("While a run is going, calls without a result are in flight; once it ends they are not")
    func inFlightOperationsFollowTheRunStatus() throws {
        let fixture = try Fixture()
        fixture.run.status = .running
        fixture.record(
            .toolUse(name: "Read", id: "done", inputSummary: "a.swift"),
            .toolResult(id: "done", content: "ok", isError: false),
            .toolUse(name: "Bash", id: "open", inputSummary: "swift test")
        )
        try fixture.context.save()

        let running = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        #expect(running.inFlightCount == 1)
        #expect(running.inFlight.first?.tool == "Bash")
        #expect(running.summaryLine == "2 operations · 1 finished · 1 in flight")
        #expect(running.currentActivityLine(now: Date())?.hasPrefix("Running Bash — swift test") == true)

        fixture.run.status = .failed
        try fixture.context.save()
        let ended = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations
        #expect(ended.inFlightCount == 0)
        #expect(ended.currentActivityLine(now: Date()) == nil)
        #expect(ended.freshnessLine(now: Date(), live: nil) == nil)
    }

    @Test("A run recorded before operation records makes no claim about what finished")
    func legacyHistoryMakesNoOutcomeClaims() throws {
        let fixture = try Fixture()
        // The rows an older build wrote: text payloads and nothing else.
        for (type, payload) in [
            ("tool.use", "Using tool: Read: a.swift"), ("tool.result", "ok"),
            ("tool.use", "Using tool: Bash: swift test")
        ] {
            fixture.context.insert(TaskEvent(task: fixture.task, type: type, payload: payload, run: fixture.run))
        }
        fixture.run.status = .running
        try fixture.context.save()

        let operations = TaskThreadSnapshot(task: fixture.task).activityPresentation(for: fixture.run).operations

        #expect(operations.totalCount == 2)
        #expect(!operations.hasOperationRecords)
        #expect(operations.inFlightCount == 0)
        #expect(operations.summaryLine == "2 operations")
    }
}
