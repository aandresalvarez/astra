import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Phase 3 of docs/specs/2026-09-23-provider-message-identity-plan.md: one rule
/// chooses a run's answer for the transcript view and the compactor alike.
@Suite("Run answer selection")
struct RunAnswerSelectionPolicyTests {
    private typealias Step = RunTranscriptStep

    // MARK: - The rule

    @Test("A short sign-off after a file write shows with the answer it follows")
    func signOffAfterWriteJoinsTheAnswer() {
        let steps: [Step] = [
            .message(id: 0, length: 60, subagent: false), .work,
            .message(id: 1, length: 1_200, subagent: false), .bookkeeping, .bookkeeping,
            .message(id: 2, length: 40, subagent: false)
        ]
        #expect(RunAnswerSelectionPolicy.answerMessageIDs(in: steps) == [1, 2])
    }

    @Test("A long message after bookkeeping is an answer on its own")
    func longMessageAfterBookkeepingStandsAlone() {
        let steps: [Step] = [
            .message(id: 0, length: 66, subagent: false), .bookkeeping,
            .message(id: 1, length: 50, subagent: false)
        ]
        #expect(RunAnswerSelectionPolicy.answerMessageIDs(in: steps) == [1])
    }

    @Test("Messages with nothing between them are one answer; work ends it")
    func adjacentMessagesJoinAndWorkEndsTheAnswer() {
        let steps: [Step] = [
            .message(id: 0, length: 900, subagent: false), .work,
            .message(id: 1, length: 900, subagent: false),
            .message(id: 2, length: 900, subagent: false)
        ]
        #expect(RunAnswerSelectionPolicy.answerMessageIDs(in: steps) == [1, 2])
    }

    @Test("Subagent messages are never the answer and break nothing")
    func subagentMessagesAreSkipped() {
        let steps: [Step] = [
            .message(id: 0, length: 900, subagent: false),
            .message(id: 1, length: 300, subagent: true),
            .message(id: 2, length: 900, subagent: false),
            .message(id: 3, length: 400, subagent: true)
        ]
        #expect(RunAnswerSelectionPolicy.answerMessageIDs(in: steps) == [0, 2])
    }

    @Test("File writes, todo lists and permission prompts are bookkeeping by every provider's name")
    func bookkeepingToolNames() {
        for name in ["Write", "Edit", "MultiEdit", "TodoWrite", "apply_patch", "create", "write_to_file", "editToolCall"] {
            #expect(RunAnswerSelectionPolicy.isBookkeepingTool(name), "\(name)")
        }
        for name in ["Read", "Bash", "view", "command_execution", "Agent", "readToolCall"] {
            #expect(!RunAnswerSelectionPolicy.isBookkeepingTool(name), "\(name)")
        }
    }

    // MARK: - Events

    private static func event(_ type: String, _ payload: String = "", id: UUID = UUID()) -> RunAnswerSelectionPolicy.Event {
        RunAnswerSelectionPolicy.Event(id: id, type: type, payload: payload)
    }

    private static func record(_ key: String, _ rows: [UUID], subagent: Bool = false) -> RunAnswerSelectionPolicy.Event {
        event("agent.message", TaskEvent.payloadString(AssistantMessageRecord(key: key, rows: rows, subagent: subagent)))
    }

    @Test("Message records group rows; the answer before a Write is kept with its sign-off")
    func recordsGroupRowsIntoMessages() {
        let narration = UUID(), readResult = UUID(), answerPart1 = UUID(), answerPart2 = UUID(), signOff = UUID()
        let events = [
            Self.event("agent.response", "I'll read the question first.", id: narration),
            Self.event("tool.use", "Using tool: Read: question.txt"),
            Self.event("tool.result", "Dana asks…", id: readResult),
            Self.event("agent.response", String(repeating: "Draft reply. ", count: 300), id: answerPart1),
            Self.event("agent.response", String(repeating: "More of it. ", count: 50), id: answerPart2),
            Self.event("tool.use", "Using tool: Write: answer.md"),
            Self.event("tool.result", "Wrote answer.md"),
            Self.event("agent.response", "The draft is saved.", id: signOff),
            Self.record("claude:msg_A#0", [narration]),
            Self.record("claude:msg_B#0", [answerPart1, answerPart2]),
            Self.record("claude:msg_C#0", [signOff])
        ]

        let selection = RunAnswerSelectionPolicy.select(events)
        #expect(selection?.answer == [[answerPart1, answerPart2], [signOff]])
        // The anchor is the last work event before the answer.
        #expect(selection?.anchor == readResult)
    }

    @Test("Tool results are paired with their uses in order")
    func toolResultsPairWithUsesInOrder() {
        let answer = UUID(), signOff = UUID()
        // Read and Write are issued together; the Read result is work, the
        // Write result bookkeeping, so the answer still follows the Read.
        let events = [
            Self.event("tool.use", "Using tool: Read: a.md"),
            Self.event("tool.use", "Using tool: Write: b.md"),
            Self.event("tool.result", "contents"),
            Self.event("agent.response", String(repeating: "Answer. ", count: 100), id: answer),
            Self.event("tool.result", "Wrote b.md"),
            Self.event("agent.response", "Saved.", id: signOff),
            Self.record("k:1", [answer]),
            Self.record("k:2", [signOff])
        ]
        #expect(RunAnswerSelectionPolicy.select(events)?.answer == [[answer], [signOff]])
    }

    @Test("A run without records has no keyed selection; its rows stand in for messages")
    func legacyRowsStandInForMessages() {
        let narration = UUID(), answer = UUID(), signOff = UUID()
        let events = [
            Self.event("tool.use", "Using tool: view"),
            Self.event("tool.result", "contents"),
            Self.event("agent.response", "Translating and saving it.", id: narration),
            Self.event("tool.use", "Using tool: create"),
            Self.event("tool.result", "Created"),
            Self.event("agent.response", "Traduzida e guardada.", id: answer),
            Self.event("permission.approval.requested", "Allow?"),
            Self.event("agent.response", "Ok.", id: signOff)
        ]
        #expect(RunAnswerSelectionPolicy.select(events) == nil)
        #expect(RunAnswerSelectionPolicy.legacySelection(events)?.answer == [[answer], [signOff]])
        #expect(RunAnswerSelectionPolicy.legacySelection([Self.event("agent.response", "Direct answer")]) == nil)
    }

    // MARK: - Presentation

    @Test("A keyed answer joins its messages with a paragraph break and no sentence repair")
    func keyedPresentationJoinsMessages() {
        let presentation = TaskRunAnswerPresentationPolicy.presentation(messages: [
            "The reply is sent.",
            "ASTRA_EVENT {\"v\":1,\"type\":\"complete\",\"summary\":\"Done\"}\nGood question, by the way.",
            "## Summary\n\nshort"
        ])
        #expect(presentation.answerText == "The reply is sent.\n\nGood question, by the way.\n\n## Summary\n\nshort")
    }

    @Test("The legacy summary cut needs a heading line with a substantive, non-repeated section")
    func legacySummaryCutIsStrict() {
        let answer = "Here is the whole answer with its detail.\n\n## Bottom line\n\nWe capped each day offset directly at 32,872 days."
        #expect(TaskRunAnswerPresentationPolicy.presentation(rawText: answer).answerText
            == "## Bottom line\n\nWe capped each day offset directly at 32,872 days.")

        let midLine = "The bottom line is that we capped each offset directly, which is simpler than an age check."
        #expect(TaskRunAnswerPresentationPolicy.presentation(rawText: midLine).answerText == midLine)

        // A re-sent copy left a trailing heading over only short, repeated
        // lines: the cut starts at the real section, never inside the copy.
        let hollowEcho = answer + "\n\nThanks,\nAlvaro\n\n## Bottom line\n\nThanks,\nAlvaro"
        #expect(TaskRunAnswerPresentationPolicy.presentation(rawText: hollowEcho).answerText
            .hasPrefix("## Bottom line\n\nWe capped each day offset directly"))
        let emptySection = "Long answer text that explains everything in detail for the reader.\n\n## Bottom line\n"
        #expect(TaskRunAnswerPresentationPolicy.presentation(rawText: emptySection).answerText.hasPrefix("Long answer text"))
    }

    // MARK: - Full response

    @MainActor
    @Test("The full response holds every main-agent message; it is offered only when it says more")
    func fullResponseCoversEveryMessage() throws {
        let task = AgentTask(title: "T", goal: "G")
        let run = TaskRun(task: task)
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 100)
        var clock = 0.0
        func add(_ type: String, _ payload: String) -> TaskEvent {
            let event = TaskEvent(task: task, type: type, payload: payload, run: run)
            event.timestamp = Date(timeIntervalSince1970: clock)
            clock += 1
            return event
        }
        let narration = add("agent.response", "I'll read the question first.")
        let read = add("tool.use", "Using tool: Read: q.txt")
        let answer = add("agent.response", "Here is the reply.")
        let records = [("k:0", narration), ("k:1", answer)].map { key, row in
            add("agent.message", TaskEvent.payloadString(AssistantMessageRecord(key: key, rows: [row.id], subagent: false)))
        }
        let snapshot = TaskThreadSnapshot(goal: "G", createdAt: Date(), events: [narration, read, answer] + records, runs: [run])
        let presentation = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run)))

        #expect(presentation.displayText == "Here is the reply.")
        #expect(presentation.fullText == "I'll read the question first.\n\nHere is the reply.")
        #expect(presentation.hasMoreThanDisplayText)

        let only = TaskThreadSnapshot(goal: "G", createdAt: Date(), events: [read, answer, records[1]], runs: [run])
        #expect(!only.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))).hasMoreThanDisplayText)
    }

    // MARK: - Compaction

    @MainActor
    @Test("Compaction keeps the answer the transcript shows, for a task over the threshold")
    func compactionKeepsTheSelectedAnswer() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Reply to Dana", goal: "Draft a reply")
        context.insert(task)
        let first = TaskRun(task: task)
        first.status = .completed
        first.completedAt = Date(timeIntervalSince1970: 100)
        let second = TaskRun(task: task)
        context.insert(first)
        context.insert(second)
        var clock = 0.0
        @discardableResult
        func add(_ type: String, _ payload: String, _ run: TaskRun) -> TaskEvent {
            let event = TaskEvent(task: task, type: type, payload: payload, run: run)
            event.timestamp = Date(timeIntervalSince1970: clock)
            clock += 1
            context.insert(event)
            return event
        }
        let narration = add("agent.response", "I'll read the question first.", first)
        add("tool.use", "Using tool: Read: question.txt", first)
        add("tool.result", "Dana asks…", first)
        let answer = add("agent.response", String(repeating: "Here is the reply. ", count: 40), first)
        add("tool.use", "Using tool: Write: answer.md", first)
        add("tool.result", "Wrote answer.md", first)
        let signOff = add("agent.response", "The draft is saved.", first)
        for (key, row) in [("k:0", narration), ("k:1", answer), ("k:2", signOff)] {
            add("agent.message", TaskEvent.payloadString(AssistantMessageRecord(key: key, rows: [row.id], subagent: false)), first)
        }
        for index in 0..<220 {
            add("agent.response", "later turn \(index)", second)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TaskEvent>()).filter { $0.run?.id == first.id }
        let ids = Set(remaining.map(\.id))
        #expect(ids.contains(answer.id) && ids.contains(signOff.id))
        #expect(!ids.contains(narration.id))
        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: remaining.sorted { $0.timestamp < $1.timestamp },
            runs: [first]
        )
        let displayed = snapshot.outputPresentation(for: TaskRunSnapshot(input: TaskRunSnapshotInput(run: first))).displayText
        #expect(displayed.hasPrefix("Here is the reply."))
        #expect(displayed.hasSuffix("The draft is saved."))
    }
}
