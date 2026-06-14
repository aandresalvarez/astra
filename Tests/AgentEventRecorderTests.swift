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
        AgentEventRecorder.recordClaudeRunEvent(
            .text(text: "REM"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        AgentEventRecorder.recordClaudeRunEvent(
            .text(text: "REMEMBERED"),
            to: task,
            run: run,
            modelContext: context,
            recordingState: recordingState
        )
        AgentEventRecorder.recordClaudeRunEvent(
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
}
