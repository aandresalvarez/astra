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
}
