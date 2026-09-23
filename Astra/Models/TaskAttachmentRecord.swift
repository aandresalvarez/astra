import Foundation
import ASTRACore

/// How a file reached the conversation.
public enum TaskAttachmentKind: String, Codable, Sendable, Equatable {
    case file
    case pastedText = "pasted_text"
    case pastedImage = "pasted_image"
    case droppedImage = "dropped_image"

    /// Inferred from the composer's temp-file names (`astra_paste_*`,
    /// `astra_drop_*`), which a durable copy in the task folder keeps.
    public init(path: String) {
        let name = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        if name.hasPrefix(EphemeralComposerAttachment.dropPrefix) {
            self = .droppedImage
        } else if name.hasPrefix(EphemeralComposerAttachment.pastePrefix) {
            self = (name as NSString).pathExtension.lowercased() == "png" ? .pastedImage : .pastedText
        } else {
            self = .file
        }
    }

    /// The file's own name, or what the user did for a composer temp file,
    /// whose generated name means nothing to them.
    public func displayName(for path: String) -> String {
        switch self {
        case .file: (path as NSString).lastPathComponent
        case .pastedText: "Pasted text"
        case .pastedImage: "Pasted image"
        case .droppedImage: "Dropped image"
        }
    }
}

public struct TaskAttachmentItem: Codable, Sendable, Equatable {
    public let path: String
    public let kind: TaskAttachmentKind

    public init(path: String, kind: TaskAttachmentKind? = nil) {
        self.path = path
        self.kind = kind ?? TaskAttachmentKind(path: path)
    }
}

/// Payload of a `user.attachments` event: the files attached to one user
/// message. The event carries the message's timestamp, so this record is
/// what says when each file entered the conversation.
public struct TaskAttachmentsPayloadV1: Codable, Sendable, Equatable {
    public let version: Int
    public let messageEventID: UUID
    public let items: [TaskAttachmentItem]

    public init(messageEventID: UUID, items: [TaskAttachmentItem]) {
        self.version = 1
        self.messageEventID = messageEventID
        self.items = items
    }

    public static func decoded(from payload: String) -> TaskAttachmentsPayloadV1? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? TaskEventPayloadCodec.makeDecoder().decode(Self.self, from: data)
    }

    /// The same record pointing at another message and other paths, for a
    /// fork's copy. The encoder escapes `/` in JSON, so the text rewrite a fork
    /// applies to other payloads would miss these paths.
    public func remapped(messageEventID: UUID, path: (String) -> String) -> TaskAttachmentsPayloadV1 {
        TaskAttachmentsPayloadV1(
            messageEventID: messageEventID,
            items: items.map { TaskAttachmentItem(path: path($0.path), kind: $0.kind) }
        )
    }
}

extension TaskEvent {
    /// The typed record of the files attached to `messageEvent`, or nil when
    /// nothing is attached. It takes the message's timestamp.
    public static func attachmentsEvent(for messageEvent: TaskEvent, paths: [String]) -> TaskEvent? {
        guard let task = messageEvent.task else { return nil }
        let items = paths
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { TaskAttachmentItem(path: $0) }
        guard !items.isEmpty else { return nil }
        let event = structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.attachments,
            payload: TaskAttachmentsPayloadV1(messageEventID: messageEvent.id, items: items)
        )
        event.timestamp = messageEvent.timestamp
        return event
    }
}

/// Which files were attached to which user message, and when.
///
/// A message sent since the typed record exists is answered from its
/// `user.attachments` event; an older one from the `Attached files:` block in
/// its own text. Only user-authored messages count, so a block the agent
/// quoted is never taken for an attachment, and a record whose message is
/// not among the events given is ignored.
public enum TaskAttachmentLedger {
    public struct EventFacts: Sendable, Equatable {
        public let id: UUID
        public let type: String
        public let payload: String
        public let timestamp: Date

        public init(id: UUID, type: String, payload: String, timestamp: Date) {
            self.id = id
            self.type = type
            self.payload = payload
            self.timestamp = timestamp
        }

        public init(_ event: TaskEvent) {
            self.init(id: event.id, type: event.type, payload: event.payload, timestamp: event.timestamp)
        }
    }

    public struct Entry: Sendable, Equatable {
        public let path: String
        public let kind: TaskAttachmentKind
        public let messageEventID: UUID
        public let attachedAt: Date

        public var displayName: String { kind.displayName(for: path) }
    }

    public static let userAuthoredMessageTypes: Set<String> = [
        TaskEventTypes.Conversation.userMessage.rawValue,
        TaskPlanConversationEventTypes.userMessage
    ]

    /// One entry per attached file, in the order of `events`.
    public static func entries(in events: [EventFacts]) -> [Entry] {
        var recordedItems: [UUID: [TaskAttachmentItem]] = [:]
        for event in events where event.type == TaskEventTypes.Conversation.attachments.rawValue {
            guard let payload = TaskAttachmentsPayloadV1.decoded(from: event.payload) else { continue }
            recordedItems[payload.messageEventID, default: []].append(contentsOf: payload.items)
        }

        return events
            .filter { userAuthoredMessageTypes.contains($0.type) }
            .flatMap { message -> [Entry] in
                let items = recordedItems[message.id]
                    ?? TaskAttachmentBlock.paths(in: message.payload)
                        .filter { !$0.isEmpty }
                        .map { TaskAttachmentItem(path: $0) }
                return items.map {
                    Entry(path: $0.path, kind: $0.kind, messageEventID: message.id, attachedAt: message.timestamp)
                }
            }
    }
}
