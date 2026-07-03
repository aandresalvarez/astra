import SwiftData
import Testing
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

@Suite("Agent Event Recorder")
@MainActor
struct AgentEventRecorderTests {
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
        #expect(agentEvents.count == 1)
        guard case .fileChange(let path, let kind, _, let oldString, let newString) = agentEvents.first else {
            Issue.record("Expected Edit tool use to map to .fileChange")
            return
        }
        #expect(path == "/tmp/example.swift")
        #expect(kind == "Edit")
        #expect(oldString == "let x = 1")
        #expect(newString == "let x = 2")

        for agentEvent in agentEvents {
            AgentEventRecorder.recordClaudeEvent(agentEvent, to: task, run: run, modelContext: context)
        }

        #expect(run.fileChanges.count == 1)
        #expect(run.fileChanges.first?.oldString == "let x = 1")
        #expect(run.fileChanges.first?.newString == "let x = 2")
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
}
