import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeAgentEventRecorderContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [config]
    )
}

private enum AgentEventRecorderTestProvider: String, CaseIterable {
    case claude
    case copilot
    case antigravity
    case codex
    case cursor
    case openCode

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .copilot: "Copilot"
        case .antigravity: "Antigravity"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        }
    }

    @MainActor
    func recordStart(
        sessionID: String,
        to task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    ) {
        let event = AgentEvent.started(sessionID: sessionID, model: "test-model")
        switch self {
        case .claude:
            AgentEventRecorder.recordClaudeEvent(
                event,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .copilot:
            AgentEventRecorder.recordCopilotEvent(
                event,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .antigravity:
            AgentEventRecorder.recordAntigravityEvent(
                event,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .codex:
            AgentEventRecorder.recordCodexEvent(
                event,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .cursor:
            AgentEventRecorder.recordCursorEvent(
                event,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        case .openCode:
            AgentEventRecorder.recordOpenCodeEvent(
                event,
                to: task,
                run: run,
                modelContext: modelContext,
                recordingState: recordingState
            )
        }
    }
}

@Suite("Agent Event Recorder")
@MainActor
struct AgentEventRecorderTests {
    @Test("Every provider start survives the run lifecycle event and duplicate frames persist once")
    func duplicateProviderStartsCreateOneLifecycleEvent() throws {
        for provider in AgentEventRecorderTestProvider.allCases {
            let container = try makeAgentEventRecorderContainer()
            let context = container.mainContext
            let task = AgentTask(title: "Lifecycle", goal: "Record one provider start")
            let run = TaskRun(task: task)
            let sessionID = "\(provider.rawValue)-session"
            context.insert(task)
            context.insert(run)
            context.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.Task.started,
                payload: "\(provider.displayName) started for task.",
                run: run
            ))
            let recordingState = AgentEventRecordingState()

            provider.recordStart(
                sessionID: sessionID,
                to: task,
                run: run,
                modelContext: context,
                recordingState: recordingState
            )
            provider.recordStart(
                sessionID: sessionID,
                to: task,
                run: run,
                modelContext: context,
                recordingState: recordingState
            )
            provider.recordStart(
                sessionID: sessionID,
                to: task,
                run: run,
                modelContext: context,
                recordingState: AgentEventRecordingState()
            )

            #expect(task.sessionId == sessionID)
            #expect(run.providerSessionId == sessionID)
            let providerStarts = task.events.filter {
                $0.type == TaskEventTypes.Task.started.rawValue
                    && $0.payload.hasPrefix("\(provider.displayName) stream started")
            }
            #expect(providerStarts.count == 1)
            #expect(task.events.filter { $0.type == TaskEventTypes.Task.started.rawValue }.count == 2)
        }
    }

    @Test("Failed tool results are stored separately from successful output")
    func failedToolResultIsStructured() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        AgentEventRecorder.recordClaudeEvent(
            .toolResult(id: "tool_pr", content: "gh pr create failed", isError: true),
            to: task,
            run: run,
            modelContext: context
        )

        let event = try #require(task.events.first { $0.type == TaskEventTypes.Tool.resultFailed.rawValue })
        let payload = try #require(try? TaskEventPayloadCodec.makeDecoder().decode(
            ToolResultFailurePayload.self,
            from: Data(event.payload.utf8)
        ))
        #expect(payload.toolID == "tool_pr")
        #expect(payload.message == "gh pr create failed")
        #expect(!task.events.contains { $0.type == TaskEventTypes.Tool.result.rawValue })
    }

    /// Task FA7E7423 logged three `task.failed reason=agent_reported_error`
    /// lines at the same millisecond on a run that ended
    /// `run_status=completed exit_code=0 has_error=false`, and the diagnostics
    /// report read them back as three failed tasks. A mid-stream error is
    /// evidence; the verdict belongs to whoever writes the run's exit status.
    @Test("A mid-stream agent error is recorded as evidence, not as a task-level failure")
    func midStreamAgentErrorIsNotAuditedAsTaskFailed() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Advisory", goal: "Finish despite an item error")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        AgentEventRecorder.recordCodexEvent(
            .failed(message: "item error: tool call could not be parsed"),
            to: task,
            run: run,
            modelContext: context
        )

        // The user still sees it in the transcript.
        let errorEvent = try #require(task.events.first { $0.type == TaskEventTypes.System.error.rawValue })
        #expect(errorEvent.payload == "item error: tool call could not be parsed")

        AppLogger.flushForTesting()
        let messages = AppLogger.entries
            .filter { $0.taskID == task.id }
            .map(\.message)
        #expect(messages.contains { $0.contains(AuditEvent.runtimeAgentReportedError.rawValue) })
        #expect(!messages.contains { $0.contains(AuditEvent.taskFailed.rawValue) })
    }

    @Test("Claude cumulative text replay appends only unseen suffix")
    func claudeCumulativeTextReplayAppendsOnlyUnseenSuffix() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Streaming", goal: "Record streamed text")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        AgentEventRecorder.recordClaudeEvent(
            .text(text: "REM"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        AgentEventRecorder.recordClaudeEvent(
            .text(text: "REMEMBERED"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        AgentEventRecorder.recordClaudeEvent(
            .text(text: "REMEMBERED"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )

        #expect(run.output == "REMEMBERED")
        let responseEvents = task.events.filter { $0.type == "agent.response" }
        #expect(responseEvents.count == 1)
        #expect(responseEvents.first?.payload == "REMEMBERED")
    }

    @Test("Provider cumulative text replay appends only unseen suffix")
    func providerCumulativeTextReplayAppendsOnlyUnseenSuffix() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Streaming", goal: "Record provider text")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        AgentEventRecorder.recordCopilotEvent(
            .text(text: "The page"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        AgentEventRecorder.recordCopilotEvent(
            .text(text: "The page is ready."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )

        #expect(run.output == "The page is ready.")
        let responseEvents = task.events.filter { $0.type == "agent.response" }
        #expect(responseEvents.count == 1)
        #expect(responseEvents.first?.payload == "The page is ready.")
    }

    @Test("Codex multiple completed messages keep the final answer, not the preamble")
    func codexMultipleCompletedMessagesKeepFinalAnswer() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Second pass review")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        // Codex emits a preamble agent_message before doing the work...
        AgentEventRecorder.recordCodexEvent(
            .completed(summary: "I'll do a second review pass from the repository itself."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        // ...an interim progress note...
        AgentEventRecorder.recordCodexEvent(
            .completed(summary: "The checkout is clean, reviewing the current tree."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        // ...and finally the actual review (last-completed-wins).
        AgentEventRecorder.recordCodexEvent(
            .completed(summary: "**Findings**\n1. High: resume flows can leave tasks stuck running."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )

        #expect(run.output == "**Findings**\n1. High: resume flows can leave tasks stuck running.")
    }

    @Test("Codex ASTRA_EVENT-wrapped final answer is unwrapped into output")
    func codexProtocolWrappedCompletedMessageIsUnwrapped() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Second pass review")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        AgentEventRecorder.recordCodexEvent(
            .completed(summary: "I'll do a second review pass."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        let wrapped = #"ASTRA_EVENT {"v":1,"type":"complete","summary":"done"}"# + "\n\n**Findings**\n1. High issue."
        AgentEventRecorder.recordCodexEvent(
            .completed(summary: wrapped),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )

        #expect(run.output.contains("**Findings**"))
        #expect(run.output.contains("High issue."))
        #expect(!run.output.contains("ASTRA_EVENT"))
    }

    @Test("Claude result summaries keep the last completed transcript output")
    func claudeResultSummariesKeepLastCompletedOutput() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Second pass review")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        func recordClaudeResult(
            text: String,
            totalInputTokens: Int,
            totalOutputTokens: Int
        ) {
            let parsed = ParsedEvent.result(
                text: text,
                costUSD: nil,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                durationMs: nil,
                numTurns: nil,
                isError: false
            )
            for agentEvent in AgentEventRecorder.agentEvents(from: parsed) {
                AgentEventRecorder.recordClaudeEvent(
                    agentEvent,
                    to: task,
                    run: run,
                    modelContext: context,
                    recordingState: recordingState
                )
            }
        }

        recordClaudeResult(
            text: "I'll do a second review pass from the repository itself.",
            totalInputTokens: 1,
            totalOutputTokens: 1
        )
        recordClaudeResult(
            text: "**Findings**\n1. High: resume flows can leave tasks stuck running.",
            totalInputTokens: 2,
            totalOutputTokens: 3
        )

        #expect(run.output == "**Findings**\n1. High: resume flows can leave tasks stuck running.")
        #expect(run.tokensUsed == 5)
        #expect(run.inputTokens == 2)
        #expect(run.outputTokens == 3)
    }

    @Test("Completed summary never clobbers streamed text output")
    func completedSummaryDoesNotClobberStreamedText() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Streaming", goal: "Record streamed text")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        AgentEventRecorder.recordCopilotEvent(
            .text(text: "Streamed answer body."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        // A trailing completed envelope must not overwrite assembled deltas.
        AgentEventRecorder.recordCopilotEvent(
            .completed(summary: "Done."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )

        #expect(run.output == "Streamed answer body.")
    }

    @Test("Completed envelope after streamed text does not clobber, even when a completed seeded output first")
    func completedAfterStreamedTextDoesNotClobberAcrossSeededCompleted() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Streaming", goal: "Record interleaved output")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        // A completed preamble seeds output (and marks the completed-source flag)...
        AgentEventRecorder.recordCopilotEvent(
            .completed(summary: "Preamble. "),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        // ...then real streamed deltas append (clearing the flag)...
        AgentEventRecorder.recordCopilotEvent(
            .text(text: "Streamed body."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        // ...so a trailing completed envelope must not overwrite the stream.
        AgentEventRecorder.recordCopilotEvent(
            .completed(summary: "Envelope echo that should be ignored."),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )

        #expect(run.output == "Preamble. Streamed body.")
    }

    @Test("Claude follow-up token accounting accumulates across runs")
    func claudeFollowUpTokenAccountingAccumulates() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Follow-up", goal: "Continue the task")
        let firstRun = TaskRun(task: task)
        context.insert(task)
        context.insert(firstRun)

        let recordingState = AgentEventRecordingState()
        for agentEvent in AgentEventRecorder.agentEvents(from: .usage(totalInputTokens: 10, totalOutputTokens: 5)) {
            AgentEventRecorder.recordClaudeEvent(
                agentEvent,
                to: task,
                run: firstRun,
                modelContext: context,
                recordingMode: .initial,
                recordingState: recordingState
            )
        }
        #expect(task.tokensUsed == 15)
        #expect(firstRun.tokensUsed == 15)

        // A follow-up run continues the same task and must add to, not
        // replace, the task's accumulated token total.
        let secondRun = TaskRun(task: task)
        context.insert(secondRun)
        for agentEvent in AgentEventRecorder.agentEvents(from: .usage(totalInputTokens: 20, totalOutputTokens: 8)) {
            AgentEventRecorder.recordClaudeEvent(
                agentEvent,
                to: task,
                run: secondRun,
                modelContext: context,
                recordingMode: .followUp,
                recordingState: recordingState
            )
        }

        #expect(secondRun.tokensUsed == 28)
        #expect(task.tokensUsed == 15 + 28)
    }

    @Test("Claude multiple result envelopes keep the final answer, not the preamble")
    func claudeMultipleResultEnvelopesKeepFinalAnswer() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Second pass review")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let recordingState = AgentEventRecordingState()
        func recordResult(_ text: String) {
            let parsed = ParsedEvent.result(
                text: text, costUSD: nil, totalInputTokens: 1, totalOutputTokens: 1,
                durationMs: nil, numTurns: nil, isError: false
            )
            for agentEvent in AgentEventRecorder.agentEvents(from: parsed) {
                AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context, recordingState: recordingState)
            }
        }

        // Claude can stream several "result"-shaped envelopes before the
        // definitive answer; the last one must win, mirroring Codex.
        recordResult("I'll do a second review pass from the repository itself.")
        recordResult("The checkout is clean, reviewing the current tree.")
        recordResult("**Findings**\n1. High: resume flows can leave tasks stuck running.")

        #expect(run.output == "**Findings**\n1. High: resume flows can leave tasks stuck running.")
    }

    @Test("Failed Claude result still preserves token/cost accounting and output text")
    func failedClaudeResultPreservesAccountingAndOutput() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Errored run", goal: "Should still record its final accounting")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let parsed = ParsedEvent.result(
            text: "Ran out of context before finishing.",
            costUSD: 0.42,
            totalInputTokens: 100,
            totalOutputTokens: 50,
            durationMs: 1234,
            numTurns: 3,
            isError: true
        )
        for agentEvent in AgentEventRecorder.agentEvents(from: parsed) {
            AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context)
        }

        #expect(run.tokensUsed == 150)
        #expect(run.costUSD == 0.42)
        #expect(run.output == "Ran out of context before finishing.")
    }

    @Test("Claude Edit tool use preserves old/new string diff through the shared recorder")
    func claudeEditToolUsePreservesDiff() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Edit", goal: "Modify a file")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let parsed = ParsedEvent.toolUse(
            name: "Edit",
            id: "tool-1",
            input: [
                "file_path": "/tmp/example.swift",
                "old_string": "let x = 1",
                "new_string": "let x = 2"
            ]
        )
        let agentEvents = AgentEventRecorder.agentEvents(from: parsed)
        // A Write/Edit tool use must still surface as a generic tool-use
        // event (for the transcript/audit trail) in addition to the precise
        // .fileChange it maps to.
        #expect(agentEvents.count == 2)
        guard case .toolUse(let toolName, let toolID, _) = agentEvents.first else {
            Issue.record("Expected Edit tool use to also emit .toolUse")
            return
        }
        #expect(toolName == "Edit")
        #expect(toolID == "tool-1")
        guard case .fileChange(let path, let kind, _, let oldString, let newString, let toolUseID) = agentEvents.last else {
            Issue.record("Expected Edit tool use to map to .fileChange")
            return
        }
        #expect(path == "/tmp/example.swift")
        #expect(kind == "Edit")
        #expect(oldString == "let x = 1")
        #expect(newString == "let x = 2")
        #expect(toolUseID == "tool-1")

        for agentEvent in agentEvents {
            AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context)
        }

        #expect(run.fileChanges.count == 1)
        #expect(run.fileChanges.first?.oldString == "let x = 1")
        #expect(run.fileChanges.first?.newString == "let x = 2")
    }

    @Test("A Claude Write is recorded when its result succeeds, not when the tool is called")
    func claudeWriteWaitsForItsResult() throws {
        let fixture = try makeToolFixture()
        record(.toolUse(name: "Write", id: "tool-w", input: ["file_path": "/tmp/report.md", "content": "rows"]), in: fixture)

        #expect(fixture.run.fileChanges.isEmpty)
        #expect(fixture.task.artifacts.isEmpty)

        record(.toolResult(toolId: "tool-w", content: "File created", isError: false), in: fixture)

        #expect(fixture.run.fileChanges.map(\.path) == ["/tmp/report.md"])
        #expect(fixture.run.fileChanges.map(\.kind) == [.write])
        #expect(fixture.task.artifacts.map(\.path) == ["/tmp/report.md"])
    }

    @Test("A Claude Write whose result is an error leaves no file change and no artifact")
    func claudeFailedWriteIsNotRecorded() throws {
        let fixture = try makeToolFixture()
        record(.toolUse(name: "Write", id: "tool-w", input: ["file_path": "/tmp/denied.md", "content": "x"]), in: fixture)
        record(.toolResult(toolId: "tool-w", content: "Permission denied", isError: true), in: fixture)

        #expect(fixture.run.fileChanges.isEmpty)
        #expect(fixture.task.artifacts.isEmpty)
        #expect(fixture.task.events.contains { $0.type == TaskEventTypes.Tool.resultFailed.rawValue })
    }

    @Test("A Claude Write denied by permission leaves no file change")
    func claudePermissionDeniedWriteIsNotRecorded() throws {
        let fixture = try makeToolFixture()
        record(.toolUse(name: "Write", id: "tool_denied", input: ["file_path": "/tmp/denied.md", "content": "x"]), in: fixture)
        // Claude's parser turns a denied tool_result into a denial carrying
        // the tool-use id, not an error result.
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool_denied","is_error":true,"content":"Permission denied"}]}}"#
        for parsed in StreamEventParser.parseAll(line: line) {
            record(parsed, in: fixture)
        }
        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state,
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            processExitedCleanly: true
        )

        #expect(fixture.run.fileChanges.isEmpty)
        #expect(fixture.task.artifacts.isEmpty)
    }

    @Test("A batch of Claude results keeps the successful write beside a denied one")
    func claudeMixedDenialBatchKeepsTheSuccessfulWrite() throws {
        let fixture = try makeToolFixture()
        record(.toolUse(name: "Write", id: "tool_ok", input: ["file_path": "/tmp/kept.md", "content": "x"]), in: fixture)
        record(.toolUse(name: "Write", id: "tool_denied", input: ["file_path": "/tmp/denied.md", "content": "y"]), in: fixture)
        // The successful result comes first, so a line-wide reading would
        // name its call as the denied one.
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool_ok","content":"File created successfully at: /tmp/kept.md"},{"type":"tool_result","tool_use_id":"tool_denied","is_error":true,"content":"Permission denied"}]}}"#
        let parsed = StreamEventParser.parseAll(line: line)
        for event in parsed {
            record(event, in: fixture)
        }
        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state,
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            processExitedCleanly: true
        )

        #expect(fixture.run.fileChanges.map(\.path) == ["/tmp/kept.md"])
        #expect(parsed.contains {
            if case .permissionDenied(let tool, _) = $0 { return tool == "tool_denied" }
            return false
        })
    }

    @Test("A write left without a result is dropped when the provider reported the turn failed")
    func unresolvedToolFileChangesAreDroppedAfterAReportedFailure() throws {
        let fixture = try makeToolFixture()
        record(.toolUse(name: "Write", id: "tool-w", input: ["file_path": "/tmp/failed.md", "content": "x"]), in: fixture)
        // Codex reports a failed turn and still exits 0.
        fixture.state.recordAgentReportedError(for: fixture.run)

        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state,
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            processExitedCleanly: true
        )

        #expect(fixture.run.fileChanges.isEmpty)
        #expect(fixture.task.artifacts.isEmpty)
    }

    @Test("A Claude Edit keeps its diff when its result succeeds and is dropped when it fails")
    func claudeEditFollowsItsResult() throws {
        let fixture = try makeToolFixture()
        func edit(_ id: String, _ old: String, _ new: String) -> ParsedEvent {
            .toolUse(name: "Edit", id: id, input: ["file_path": "/tmp/plan.md", "old_string": old, "new_string": new])
        }
        record(edit("edit-ok", "v1", "v2"), in: fixture)
        record(edit("edit-bad", "missing", "v3"), in: fixture)
        record(.toolResult(toolId: "edit-bad", content: "old_string not found", isError: true), in: fixture)
        record(.toolResult(toolId: "edit-ok", content: "Edited", isError: false), in: fixture)

        #expect(fixture.run.fileChanges.map(\.newString) == ["v2"])
        #expect(fixture.run.fileChanges.first?.oldString == "v1")
    }

    @Test("A tool file change whose result never arrived is kept when the run's events are drained")
    func unresolvedToolFileChangesAreCommittedAtRunEnd() throws {
        let fixture = try makeToolFixture()
        record(.toolUse(name: "Write", id: "tool-w", input: ["file_path": "/tmp/late.md", "content": "x"]), in: fixture)
        #expect(fixture.run.fileChanges.isEmpty)

        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state,
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            processExitedCleanly: true
        )

        #expect(fixture.run.fileChanges.map(\.path) == ["/tmp/late.md"])
        // Committed once: a second drain finds nothing left.
        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state,
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            processExitedCleanly: true
        )
        #expect(fixture.run.fileChanges.count == 1)
    }

    @Test("Changes left without a result are committed in the order their calls came")
    func unresolvedToolFileChangesKeepCallOrder() throws {
        let fixture = try makeToolFixture()
        func edit(_ id: String, _ old: String, _ new: String) -> ParsedEvent {
            .toolUse(name: "Edit", id: id, input: ["file_path": "/tmp/plan.md", "old_string": old, "new_string": new])
        }
        record(edit("z-first", "v1", "v2"), in: fixture)
        record(edit("a-second", "v2", "v3"), in: fixture)

        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state,
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            processExitedCleanly: true
        )

        #expect(fixture.run.fileChanges.map(\.newString) == ["v2", "v3"])
    }

    @Test("A file change with no tool-use id is recorded at once, as providers without ids need")
    func fileChangeWithoutToolIDIsRecordedImmediately() throws {
        let fixture = try makeToolFixture()
        AgentEventRecorder.recordCodexEvent(
            .fileChange(path: "/tmp/codex.md", kind: "modified", summary: "Patched"),
            to: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            recordingState: fixture.state
        )

        #expect(fixture.run.fileChanges.map(\.path) == ["/tmp/codex.md"])
    }

    @Test("A Codex patch is visible at its start and recorded only when it completes")
    func codexFileChangesFollowTheirCompletion() throws {
        let started = #"{"type":"item.started","item":{"id":"i1","type":"file_change","path":"/tmp/a.md","kind":"add","status":"in_progress"}}"#
        let failed = #"{"type":"item.completed","item":{"id":"i1","type":"file_change","path":"/tmp/a.md","kind":"add","status":"failed"}}"#
        let completed = #"{"type":"item.completed","item":{"id":"i1","type":"file_change","path":"/tmp/a.md","kind":"add","status":"completed"}}"#

        // The policy guard reads the start, so the path must be on it.
        let startEvents = CodexCLIRuntime.parseAgentEvents(line: started, parsesJSONLines: true)
        guard case .fileChange(let path, _, _, _, _, let toolUseID) = startEvents.first else {
            Issue.record("Expected the started patch to surface as a file change")
            return
        }
        #expect(path == "/tmp/a.md")
        #expect(toolUseID == "i1")

        func paths(after lines: [String], drain: Bool = false) throws -> [String] {
            let fixture = try makeToolFixture()
            for line in lines {
                for event in CodexCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true) {
                    AgentEventRecorder.recordCodexEvent(
                        event,
                        to: fixture.task,
                        run: fixture.run,
                        modelContext: fixture.container.mainContext,
                        recordingState: fixture.state
                    )
                }
            }
            if drain {
                AgentEventRecorder.commitUnresolvedFileChanges(
                    recordingState: fixture.state,
                    task: fixture.task,
                    run: fixture.run,
                    modelContext: fixture.container.mainContext,
                    processExitedCleanly: true
                )
            }
            return fixture.run.fileChanges.map(\.path)
        }

        #expect(try paths(after: [started]).isEmpty)
        #expect(try paths(after: [started, failed], drain: true).isEmpty)
        #expect(try paths(after: [started, completed]) == ["/tmp/a.md"])
        #expect(try paths(after: [completed]) == ["/tmp/a.md"])
    }

    @Test("A Codex completion's details replace what its start announced")
    func codexCompletionReplacesTheStartedChange() throws {
        let fixture = try makeToolFixture()
        for line in [
            #"{"type":"item.started","item":{"id":"i1","type":"file_change","path":"/tmp/a.md","kind":"add","summary":"Applying patch"}}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"file_change","path":"/tmp/a.md","kind":"update","summary":"Updated the summary table","status":"completed"}}"#
        ] {
            for event in CodexCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true) {
                AgentEventRecorder.recordCodexEvent(
                    event,
                    to: fixture.task,
                    run: fixture.run,
                    modelContext: fixture.container.mainContext,
                    recordingState: fixture.state
                )
            }
        }

        #expect(fixture.run.fileChanges.count == 1)
        #expect(fixture.run.fileChanges.first?.content == "Updated the summary table")
    }

    @Test("A denial drops exactly the held call it ruled out, even among parallel calls of one tool")
    func denialByToolNameDropsOnlyAnUnambiguousCall() throws {
        // A denied result that carries both `name` and `tool_use_id`: the
        // parser reports the name.
        let denied = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool_w","name":"Write","is_error":true,"content":"Permission denied"}]}}"#
        func write(_ id: String, _ path: String) -> ParsedEvent {
            .toolUse(name: "Write", id: id, input: ["file_path": path, "content": "x"])
        }

        let single = try makeToolFixture()
        record(write("tool_w", "/tmp/denied.md"), in: single)
        for parsed in StreamEventParser.parseAll(line: denied) { record(parsed, in: single) }
        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: single.state,
            task: single.task,
            run: single.run,
            modelContext: single.container.mainContext,
            processExitedCleanly: true
        )
        #expect(single.run.fileChanges.isEmpty)

        // Two held Writes: the name alone cannot say which was denied, but
        // the call id riding beside the denial does.
        let ambiguous = try makeToolFixture()
        record(write("tool_w", "/tmp/one.md"), in: ambiguous)
        record(write("tool_x", "/tmp/two.md"), in: ambiguous)
        for parsed in StreamEventParser.parseAll(line: denied) { record(parsed, in: ambiguous) }
        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: ambiguous.state,
            task: ambiguous.task,
            run: ambiguous.run,
            modelContext: ambiguous.container.mainContext,
            processExitedCleanly: true
        )
        #expect(ambiguous.run.fileChanges.map(\.path) == ["/tmp/two.md"])
    }

    @Test("Held writes are dropped, not kept, when ASTRA forced the provider to stop")
    func unresolvedToolFileChangesAreDroppedAfterAForcedStop() throws {
        let fixture = try makeToolFixture()
        record(.toolUse(name: "Write", id: "tool-w", input: ["file_path": "/tmp/halfway.md", "content": "x"]), in: fixture)

        AgentEventRecorder.commitUnresolvedFileChanges(
            recordingState: fixture.state,
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.container.mainContext,
            processExitedCleanly: false
        )

        #expect(fixture.run.fileChanges.isEmpty)
        #expect(fixture.task.artifacts.isEmpty)
    }

    private struct ToolFixture {
        let container: ModelContainer
        let task: AgentTask
        let run: TaskRun
        let state: AgentEventRecordingState
    }

    private func makeToolFixture() throws -> ToolFixture {
        let container = try makeAgentEventRecorderContainer()
        let task = AgentTask(title: "Tools", goal: "Write files")
        let run = TaskRun(task: task)
        container.mainContext.insert(task)
        container.mainContext.insert(run)
        return ToolFixture(container: container, task: task, run: run, state: AgentEventRecordingState())
    }

    private func record(_ parsed: ParsedEvent, in fixture: ToolFixture) {
        for agentEvent in AgentEventRecorder.agentEvents(from: parsed) {
            AgentEventRecorder.recordClaudeEvent(
                agentEvent,
                to: fixture.task,
                run: fixture.run,
                modelContext: fixture.container.mainContext,
                recordingState: fixture.state
            )
        }
    }

    @Test("Claude preserves every edit to the same file within one run, not just the first")
    func claudePreservesRepeatedEditsToSamePath() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Multi-edit", goal: "Edit the same file twice")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        func recordEdit(id: String, old: String, new: String) {
            let parsed = ParsedEvent.toolUse(
                name: "Edit",
                id: id,
                input: ["file_path": "/tmp/example.swift", "old_string": old, "new_string": new]
            )
            for agentEvent in AgentEventRecorder.agentEvents(from: parsed) {
                AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context)
            }
        }

        recordEdit(id: "tool-1", old: "let x = 1", new: "let x = 2")
        recordEdit(id: "tool-2", old: "let x = 2", new: "let x = 3")

        #expect(run.fileChanges.count == 2)
        #expect(run.fileChanges.map(\.newString) == ["let x = 2", "let x = 3"])
    }

    @Test("Claude in-process teammate events still record through the shared recorder")
    func claudeTeammateEventsRecordThroughSharedRecorder() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Team", goal: "Spawn a teammate")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let started = ParsedEvent.teammateStarted(taskId: "agent-1", name: "pro-agent", prompt: "Investigate the bug")
        for agentEvent in AgentEventRecorder.agentEvents(from: started) {
            AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context)
        }
        #expect(task.events.contains { $0.type == "team.agent.started" && $0.agentId == "agent-1" })

        let completed = ParsedEvent.teammateCompleted(taskId: "agent-1", name: "pro-agent")
        for agentEvent in AgentEventRecorder.agentEvents(from: completed) {
            AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context)
        }
        #expect(task.events.contains { $0.type == "team.agent.completed" && $0.agentId == "agent-1" })
    }

    @Test("A completed subagent keeps its started name, not its answer")
    func completedSubagentKeepsStartedName() throws {
        let container = try makeAgentEventRecorderContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Subagent", goal: "Summarize question.txt")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        func record(_ line: String) {
            for parsed in StreamEventParser.parseAll(line: line) {
                for agentEvent in AgentEventRecorder.agentEvents(from: parsed) {
                    AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context)
                }
            }
        }

        let answer = "Dana is asking whether the 32,872-day top-coding was implemented by capping each day "
            + "offset at 32,872 (using LEAST) or by first checking whether the patient reached age 90, "
            + "and wants a short reply drafted. Nothing else in the file needs an answer."
        record("""
        {"type":"system","subtype":"task_started","task_id":"a613e2b53651b7b23","tool_use_id":"toolu_1","description":"Summarize question.txt","subagent_type":"general-purpose","task_type":"local_agent","prompt":"Read question.txt and summarize it in one sentence."}
        """)
        record("""
        {"type":"system","subtype":"task_notification","task_id":"a613e2b53651b7b23","tool_use_id":"toolu_1","status":"completed","summary":"\(answer)"}
        """)
        // A subagent whose start was never recorded falls back to its task id.
        record("""
        {"type":"system","subtype":"task_notification","task_id":"b7c1d2e3f4a5b6c7d","status":"completed","summary":"\(answer)"}
        """)

        let completed = task.events.filter { $0.type == TaskEventTypes.Team.agentCompleted.rawValue }
        #expect(completed.count == 2)
        let matched = try #require(completed.first { $0.agentId == "a613e2b53651b7b23" })
        #expect(matched.agentName == "Summarize question.txt")
        #expect(matched.payload == "Summarize question.txt finished")
        let unmatched = try #require(completed.first { $0.agentId == "b7c1d2e3f4a5b6c7d" })
        #expect(unmatched.agentName == "b7c1d2e3f4a5b6c7d")
        #expect(unmatched.payload == "b7c1d2e3f4a5b6c7d finished")
        #expect(!completed.contains { ($0.agentName ?? "").contains("Dana") || $0.payload.contains("Dana") })
    }
}

@Suite("Agent Event Recording Presentation echo window")
struct AgentEventRecordingPresentationEchoWindowTests {
    @Test("a repeat older than the echo search window is appended, not swallowed")
    func repeatBeyondEchoWindowIsAppended() {
        // The echo containment scan looks back incoming.count +
        // echoSearchWindowSlack characters; older content is out of dedupe
        // range by design — the bound is what keeps the recording path linear
        // across a long streamed run. A repeat inside the window is still an
        // echo (the UI stress suite documents that half of the trade-off).
        let sentence = "The deployment completed successfully and all twelve health checks passed on the first attempt."
        let fillerLine = "Later progress detail keeps arriving in realistic streamed sentences.\n"
        let fillerLines = (AgentEventRecordingPresentation.echoSearchWindowSlack + sentence.count) / fillerLine.count + 40
        let filler = String(repeating: fillerLine, count: fillerLines)
        let existing = "Earlier: \(sentence)\n\(filler)"
        #expect(filler.count > AgentEventRecordingPresentation.echoSearchWindowSlack + sentence.count)

        let appended = AgentEventRecordingPresentation.responseTextToAppend(sentence, after: existing)
        #expect(appended == sentence, "repeats beyond the bounded window are new output")
    }

    @Test("a whole-output envelope echo is swallowed regardless of output size")
    func wholeOutputEnvelopeEchoSwallowedBeyondWindowSize() {
        // The window bounds only the interior containment scan; a whole-output
        // envelope echo (interior whitespace shifted) is caught by the
        // collapsed-equality walk at any size.
        var output = ""
        for index in 0..<600 {
            output += "Streamed sentence \(index) carrying a realistic amount of prose per tick.\n"
        }
        #expect(output.count > AgentEventRecordingPresentation.echoSearchWindowSlack)

        let envelope = output.replacingOccurrences(of: "\n", with: " \n")
        let appended = AgentEventRecordingPresentation.responseTextToAppend(envelope, after: output)
        #expect(appended.isEmpty, "whitespace-shifted whole-output echoes must never re-append")
    }

    @Test("a non-ASCII whole-output echo dedupes even past the window size")
    func nonAsciiWholeOutputEchoSwallowedBeyondWindowSize() {
        // Non-ASCII text can't use the ASCII byte walk, and an echo that also
        // collapses large whitespace runs can be shorter than the recorded
        // output by more than the containment window — the scalar walk must
        // still classify it as a whole-output echo, or the run's answer
        // records twice for non-English output.
        var output = ""
        for index in 0..<2_000 {
            output += "ストリーム文 \(index) は現実的な散文を運ぶ。" + String(repeating: " ", count: 40) + "\n"
        }
        let envelope = output
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(
            envelope.count + AgentEventRecordingPresentation.echoSearchWindowSlack < output.count,
            "fixture must shrink past the containment window to be discriminating"
        )

        let appended = AgentEventRecordingPresentation.responseTextToAppend(envelope, after: output)
        #expect(appended.isEmpty, "whitespace-normalized whole-output echoes must dedupe for non-ASCII output")
    }
}
