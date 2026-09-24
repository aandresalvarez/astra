import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeAssistantMessageLedgerContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [config]
    )
}

@Suite("Assistant message ledger")
@MainActor
struct AssistantMessageLedgerTests {
    @MainActor
    private struct Harness {
        let container: ModelContainer
        let task: AgentTask
        let run: TaskRun
        let state: AgentEventRecordingState

        init(rowCap: Int? = nil) throws {
            container = try makeAssistantMessageLedgerContainer()
            task = AgentTask(title: "Messages", goal: "Record keyed assistant text")
            run = TaskRun(task: task)
            container.mainContext.insert(task)
            container.mainContext.insert(run)
            state = rowCap.map { AgentEventRecordingState(maxCoalescedPayloadLength: $0) } ?? AgentEventRecordingState()
        }

        func record(_ event: AgentEvent) {
            AgentEventRecorder.recordClaudeEvent(
                event,
                to: task,
                run: run,
                modelContext: container.mainContext,
                recordingState: state
            )
        }

        func delta(_ key: String, _ text: String) {
            record(.assistantMessage(.fragment(.init(key: key, kind: .delta, text: text))))
        }

        func final(_ key: String, _ text: String, isSubagent: Bool = false) {
            record(.assistantMessage(.fragment(.init(key: key, kind: .final, text: text, isSubagent: isSubagent))))
        }

        func responseRows() throws -> [TaskEvent] {
            try container.mainContext.save()
            return try container.mainContext.fetch(FetchDescriptor<TaskEvent>())
                .filter { $0.type == TaskEventTypes.Conversation.agentResponse.rawValue }
                .sorted { $0.timestamp < $1.timestamp }
        }
    }

    @Test("A final copy equal to the streamed draft writes nothing")
    func equalFinalIsANoOp() throws {
        let harness = try Harness()
        harness.delta("claude:msg_A#0", "Short answer.\n")
        harness.delta("claude:msg_A#0", "Done.")
        harness.final("claude:msg_A#0", "Short answer.\nDone.")

        let rows = try harness.responseRows()
        #expect(rows.map(\.payload) == ["Short answer.\nDone."])
        #expect(harness.run.output == "Short answer.\nDone.")
    }

    @Test("A final copy that differs from the draft replaces it")
    func differingFinalReplacesTheDraft() throws {
        let harness = try Harness()
        harness.delta("claude:msg_A#0", "Helo wrld")
        harness.final("claude:msg_A#0", "Hello world")

        #expect(try harness.responseRows().map(\.payload) == ["Hello world"])
        #expect(harness.run.output == "Hello world")
    }

    @Test("A final copy with no draft is recorded once")
    func finalOnlyMessageIsRecorded() throws {
        let harness = try Harness()
        harness.final("claude:msg_Sub#0", "Subagent result", isSubagent: true)
        harness.final("claude:msg_Sub#0", "Subagent result", isSubagent: true)

        #expect(try harness.responseRows().map(\.payload) == ["Subagent result"])
        #expect(harness.run.output == "Subagent result")
    }

    @Test("Text for a committed message is ignored")
    func committedMessageIgnoresLateText() throws {
        let harness = try Harness()
        harness.delta("claude:msg_A#0", "Done.")
        harness.final("claude:msg_A#0", "Done.")
        harness.delta("claude:msg_A#0", " Again.")

        #expect(try harness.responseRows().map(\.payload) == ["Done."])
        #expect(harness.run.output == "Done.")
    }

    @Test("Replacing an earlier message keeps it before later events")
    func replacingAnEarlierMessageKeepsItsPlace() throws {
        let harness = try Harness()
        harness.delta("claude:msg_A#0", "First.")
        harness.record(.toolUse(name: "Read", id: "toolu_1", inputSummary: "notes.md"))
        harness.delta("claude:msg_B#0", "Second.")
        harness.final("claude:msg_A#0", "First!")
        harness.final("claude:msg_B#0", "Second.")

        let rows = try harness.responseRows()
        #expect(rows.map(\.payload) == ["First!", "Second."])
        let toolRow = try #require(harness.task.events.first { $0.type == TaskEventTypes.Tool.use.rawValue })
        #expect(rows[0].timestamp <= toolRow.timestamp)
        #expect(harness.run.output == "First!Second.")
    }

    @Test("Two messages never share a row")
    func messagesDoNotCoalesce() throws {
        let harness = try Harness()
        harness.delta("claude:msg_A#0", "One. ")
        harness.delta("claude:msg_A#1", "Two.")

        #expect(try harness.responseRows().map(\.payload) == ["One. ", "Two."])
        #expect(harness.run.output == "One. Two.")
    }

    @Test("A message longer than the row cap continues in more rows, and shrinks with its final copy")
    func longMessagesSpanRows() throws {
        let harness = try Harness(rowCap: 10)
        harness.delta("claude:msg_A#0", "0123456789")
        harness.delta("claude:msg_A#0", "abcdefghij")
        harness.delta("claude:msg_A#0", "KLMNO")
        #expect(try harness.responseRows().count == 3)

        harness.final("claude:msg_A#0", "0123456789abc")

        let rows = try harness.responseRows()
        #expect(Set(rows.map(\.payload)) == ["0123456789", "abc"])
        #expect(harness.run.output == "0123456789abc")
    }

    @Test("A secret split across deltas, or carried by a final copy, is redacted")
    func secretsAreRedactedAcrossFragments() throws {
        let harness = try Harness()
        let secret = "sk-test-0123456789abcdefghijklmnopqrstuv"
        let taskID = harness.task.id
        RunSecretRedactionScope.beginRun(taskID: taskID)
        defer {
            RunSecretRedactionScope.endRun(taskID: taskID)
            RunSecretRedactionScope.forget(taskID: taskID)
        }
        RunSecretRedactionScope.register(taskID: taskID, secrets: [secret])
        let half = secret.index(secret.startIndex, offsetBy: secret.count / 2)

        harness.delta("claude:msg_A#0", "key=\(secret[..<half])")
        harness.delta("claude:msg_A#0", "\(secret[half...]) ok")
        let streamed = try harness.responseRows()
        #expect(streamed.count == 1)
        #expect(!streamed[0].payload.contains(secret))
        #expect(!streamed[0].payload.contains(String(secret[..<half])))
        #expect(!harness.run.output.contains(secret))

        harness.final("claude:msg_A#0", "key=\(secret) is fine")
        let rewritten = try harness.responseRows()
        #expect(rewritten.count == 1)
        #expect(!rewritten[0].payload.contains(secret))
        #expect(rewritten[0].payload.hasSuffix(" is fine"))
        #expect(!harness.run.output.contains(secret))
    }

    @Test("A streamed Claude reply with short lines is recorded once, end to end")
    func claudeStreamRecordsTheReplyOnce() throws {
        let harness = try Harness()
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        let reply = "Here is the summary you asked for, in a few short lines.\n\n- One.\n- Two.\n\nDone."
        let lines = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_A","type":"message","role":"assistant","content":[]}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Here is the summary you asked for, in a few short lines.\n\n- One.\n"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"- Two.\n\nDone."}},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"id":"msg_A","role":"assistant","content":[{"type":"text","text":"Here is the summary you asked for, in a few short lines.\n\n- One.\n- Two.\n\nDone."}]},"parent_tool_use_id":null}"#
        ]
        for line in lines {
            for event in adapter.parseWorkerStreamEvents(line: line, parsesJSONLines: true).agentEvents {
                pipeline.process(event).forEach(harness.record)
            }
        }
        pipeline.flushAgentEvents().forEach(harness.record)

        #expect(try harness.responseRows().map(\.payload) == [reply])
        #expect(harness.run.output == reply)
    }
}
