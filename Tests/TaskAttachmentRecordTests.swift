import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Covers how a message's attachments are written, parsed, recorded as a
/// typed `user.attachments` event, and read back by the ledger.
@Suite("Task attachment record")
@MainActor
struct TaskAttachmentRecordTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    // MARK: - Text block

    @Test("The attachment block round-trips the composer's paths")
    func attachmentBlockRoundTrips() {
        let paths = ["/tmp/report.md", "/tmp/My Notes/astra_paste_1234ABCD.png"]
        let message = TaskAttachmentBlock.message("Compare these.", attaching: paths)

        #expect(message == "Compare these.\n\nAttached files:\n- /tmp/report.md\n- /tmp/My Notes/astra_paste_1234ABCD.png")
        #expect(TaskAttachmentBlock.paths(in: message) == paths)
        #expect(TaskAttachmentBlock.message("Just text.", attaching: []) == "Just text.")
    }

    @Test("The attachment block parser reads every spelling and stops at prose")
    func attachmentBlockParserReadsEverySpelling() {
        let text = """
        ATTACHED FILES:
        * `/tmp/one.md`
        - "/tmp/two.md"

        Later I mentioned /tmp/not-attached.md in prose.
        - /tmp/also-not-attached.md
        Attached files/folders (dragged by user):
        - '/tmp/folder'
        Original blocked user request follows.
        """

        #expect(TaskAttachmentBlock.paths(in: text) == ["/tmp/one.md", "/tmp/two.md", "/tmp/folder"])
        #expect(TaskAttachmentBlock.paths(in: "No attachments here.\n- /tmp/stray.md").isEmpty)
    }

    // MARK: - Kinds

    @Test("Attachment kinds follow the composer's temp-file names, even on a durable copy")
    func attachmentKindsFollowComposerNames() {
        #expect(TaskAttachmentKind(path: "/tmp/astra_paste_1234ABCD.png") == .pastedImage)
        #expect(TaskAttachmentKind(path: "/tmp/astra_paste_1234ABCD.txt") == .pastedText)
        #expect(TaskAttachmentKind(path: "/tmp/astra_paste_1234ABCD.json") == .pastedText)
        #expect(TaskAttachmentKind(path: "/tmp/astra_drop_1234ABCD.png") == .droppedImage)
        #expect(TaskAttachmentKind(path: "/ws/.astra/tasks/T/inputs/astra_paste_1234ABCD.png") == .pastedImage)
        #expect(TaskAttachmentKind(path: "/Users/someone/report.pdf") == .file)

        #expect(TaskAttachmentKind.pastedImage.displayName(for: "/tmp/astra_paste_1234ABCD.png") == "Pasted image")
        #expect(TaskAttachmentKind.droppedImage.displayName(for: "/tmp/astra_drop_1234ABCD.png") == "Dropped image")
        #expect(TaskAttachmentKind.file.displayName(for: "/Users/someone/report.pdf") == "report.pdf")
    }

    // MARK: - Ledger

    @Test("A typed record answers for its message, and older messages fall back to their text")
    func ledgerPrefersRecordsAndFallsBackToText() throws {
        let legacyAt = Date(timeIntervalSince1970: 100)
        let recordedAt = Date(timeIntervalSince1970: 200)
        let planAt = Date(timeIntervalSince1970: 300)
        let legacy = TaskAttachmentLedger.EventFacts(
            id: UUID(),
            type: "user.message",
            payload: TaskAttachmentBlock.message("Old turn.", attaching: ["/tmp/old.md", "/tmp/astra_drop_1234ABCD.png"]),
            timestamp: legacyAt
        )
        let recordedMessage = TaskAttachmentLedger.EventFacts(
            id: UUID(),
            type: "user.message",
            payload: TaskAttachmentBlock.message("New turn.", attaching: ["/tmp/new.md"]),
            timestamp: recordedAt
        )
        let record = TaskAttachmentLedger.EventFacts(
            id: UUID(),
            type: "user.attachments",
            payload: TaskEvent.payloadString(TaskAttachmentsPayloadV1(
                messageEventID: recordedMessage.id,
                items: [TaskAttachmentItem(path: "/tmp/new.md")]
            )),
            timestamp: recordedAt
        )
        let planMessage = TaskAttachmentLedger.EventFacts(
            id: UUID(),
            type: TaskPlanConversationEventTypes.userMessage,
            payload: TaskAttachmentBlock.message("Plan around this.", attaching: ["/tmp/plan.md"]),
            timestamp: planAt
        )
        let agentQuote = TaskAttachmentLedger.EventFacts(
            id: UUID(),
            type: "agent.response",
            payload: TaskAttachmentBlock.message("I would attach:", attaching: ["/tmp/agent.md"]),
            timestamp: planAt
        )
        let orphanRecord = TaskAttachmentLedger.EventFacts(
            id: UUID(),
            type: "user.attachments",
            payload: TaskEvent.payloadString(TaskAttachmentsPayloadV1(
                messageEventID: UUID(),
                items: [TaskAttachmentItem(path: "/tmp/orphan.md")]
            )),
            timestamp: planAt
        )

        let entries = TaskAttachmentLedger.entries(
            in: [legacy, recordedMessage, record, planMessage, agentQuote, orphanRecord]
        )

        #expect(entries.map(\.path) == ["/tmp/old.md", "/tmp/astra_drop_1234ABCD.png", "/tmp/new.md", "/tmp/plan.md"])
        #expect(entries.map(\.attachedAt) == [legacyAt, legacyAt, recordedAt, planAt])
        #expect(entries.map(\.messageEventID) == [legacy.id, legacy.id, recordedMessage.id, planMessage.id])
        #expect(entries.map(\.displayName) == ["old.md", "Dropped image", "new.md", "plan.md"])
    }

    // MARK: - Event

    @Test("Inserting a user message inserts its attachment record beside it, and only when files are attached")
    func insertingMessageInsertsItsRecord() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Attach", goal: "Record attachments")
        context.insert(task)
        let plain = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "No files.")
        let withFiles = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "See attached.")

        TaskEventInsertionService.insert(plain, attachmentPaths: [], into: context)
        TaskEventInsertionService.insert(withFiles, attachmentPaths: ["/tmp/report.md"], into: context)
        try context.save()

        let events = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(events.count == 3)
        let records = events.filter { $0.type == TaskEventTypes.Conversation.attachments.rawValue }
        let payload = try #require(records.first.flatMap { TaskAttachmentsPayloadV1.decoded(from: $0.payload) })
        #expect(records.count == 1)
        #expect(payload.messageEventID == withFiles.id)
        #expect(payload.items.map(\.path) == ["/tmp/report.md"])
    }

    @Test("The attachments event takes its message's time and skips an empty list")
    func attachmentsEventTakesMessageTime() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Attach", goal: "Record attachments")
        context.insert(task)
        let message = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "See attached.")
        message.timestamp = Date(timeIntervalSince1970: 1_000)
        context.insert(message)

        #expect(TaskEvent.attachmentsEvent(for: message, paths: []) == nil)
        #expect(TaskEvent.attachmentsEvent(for: message, paths: ["  "]) == nil)

        let event = try #require(TaskEvent.attachmentsEvent(
            for: message,
            paths: ["/tmp/report.md", " ", "/tmp/astra_paste_1234ABCD.png"]
        ))
        #expect(event.type == "user.attachments")
        #expect(event.category == "conversation")
        #expect(event.timestamp == message.timestamp)
        #expect(event.task?.id == task.id)
        let payload = try #require(TaskAttachmentsPayloadV1.decoded(from: event.payload))
        #expect(payload.version == 1)
        #expect(payload.messageEventID == message.id)
        #expect(payload.items == [
            TaskAttachmentItem(path: "/tmp/report.md", kind: .file),
            TaskAttachmentItem(path: "/tmp/astra_paste_1234ABCD.png", kind: .pastedImage)
        ])
    }
}
