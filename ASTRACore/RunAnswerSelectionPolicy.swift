import Foundation

/// The rows of one recorded assistant message, written as an `agent.message`
/// event when the run ends. Rows never mix two messages, so this is what lets
/// a reader tell one long message split across rows from several messages.
public struct AssistantMessageRecord: Codable, Sendable, Equatable {
    public let key: String
    public let rows: [UUID]
    public let subagent: Bool

    public init(key: String, rows: [UUID], subagent: Bool) {
        self.key = key
        self.rows = rows
        self.subagent = subagent
    }
}

/// One step of a run's transcript, in order, as the answer rule sees it.
public enum RunTranscriptStep: Equatable, Sendable {
    /// An assistant message; `id` is the caller's, `length` its visible text.
    case message(id: Int, length: Int, subagent: Bool)
    /// Work that does not change what the user asked for: writing the answer
    /// to a file, updating a todo list, a permission request or its answer.
    case bookkeeping
    /// Anything else the agent did: reading, running, searching, delegating.
    case work
}

/// Chooses which messages of a run are its answer. The transcript view and the
/// event compactor both use it, so what is shown and what compaction keeps can
/// no longer disagree (docs/specs/2026-09-23-provider-message-identity-plan.md,
/// Phase 3).
///
/// The answer is the last main-agent message, extended backward:
/// - over a message that directly precedes it (nothing in between): one
///   continuous reply split into several messages is one answer;
/// - over a message separated from it only by bookkeeping, when what follows
///   is shorter than a third of that message: "draft the reply, save it,
///   say it is saved" shows the draft with its sign-off, never the sign-off
///   alone. A long message after bookkeeping is a new answer on its own.
///
/// Work ends the answer: a message before a read or a command is progress.
/// Subagent messages are never the answer and break nothing.
public enum RunAnswerSelectionPolicy {
    public static func answerMessageIDs(in steps: [RunTranscriptStep]) -> [Int] {
        let messages: [(position: Int, id: Int, length: Int)] = steps.enumerated().compactMap { position, step in
            guard case .message(let id, let length, let subagent) = step, !subagent else { return nil }
            return (position, id, length)
        }
        guard var index = messages.indices.last else { return [] }
        var groupLength = messages[index].length
        while index > messages.startIndex {
            let previous = messages[index - 1]
            let between = steps[(previous.position + 1)..<messages[index].position].filter { step in
                if case .message(_, _, true) = step { return false }
                return true
            }
            let joins: Bool
            if between.isEmpty {
                joins = true
            } else if between.allSatisfy({ $0 == .bookkeeping }) {
                joins = groupLength * 3 < previous.length
            } else {
                joins = false
            }
            guard joins else { break }
            index -= 1
            groupLength += previous.length
        }
        return messages[index...].map(\.id)
    }

    /// Tools that record the answer rather than find it: file writes and todo
    /// lists, by the names each provider uses.
    public static func isBookkeepingTool(_ name: String) -> Bool {
        bookkeepingToolNames.contains(name.lowercased())
    }

    private static let bookkeepingToolNames: Set<String> = [
        "write", "edit", "multiedit", "multi_edit", "notebookedit", "todowrite",
        "apply_patch", "create", "str_replace_editor", "write_to_file", "replace_file_content",
        "edittoolcall", "writetoolcall", "file_change", "update_plan"
    ]
}

extension RunAnswerSelectionPolicy {
    /// One event of a run, as stored: the transcript view and the compactor
    /// each map their own event type onto this.
    public struct Event: Sendable {
        public let id: UUID
        public let type: String
        public let payload: String

        public init(id: UUID, type: String, payload: String) {
            self.id = id
            self.type = type
            self.payload = payload
        }
    }

    public struct Selection: Sendable, Equatable {
        /// The answer's messages in order, each as its rows in order.
        public let answer: [[UUID]]
        /// The last work event before the answer: what the answer follows.
        public let anchor: UUID?
    }

    /// The answer of one run, from its events in order. `nil` for a run
    /// recorded before messages were keyed (it has no `agent.message`
    /// records); `legacySelection` reads those.
    public static func select(_ events: [Event]) -> Selection? {
        let records = events.compactMap { event -> AssistantMessageRecord? in
            guard event.type == messageRecordType, let data = event.payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AssistantMessageRecord.self, from: data)
        }
        guard !records.isEmpty else { return nil }
        return selection(events, records: records)
    }

    /// A run recorded before messages were keyed. Its rows were already split
    /// at every tool call, so each row stands in for a message and the same
    /// rule applies: a short sign-off after a file write shows with the answer
    /// it follows, and narration before the write stays progress. `nil` when
    /// no work event precedes the rows, so the caller falls back to the run's
    /// output.
    public static func legacySelection(_ events: [Event]) -> Selection? {
        guard stepKinds(of: events).contains(.work) else { return nil }
        let selection = selection(events, records: [])
        return selection.answer.isEmpty ? nil : selection
    }

    private static func selection(_ events: [Event], records: [AssistantMessageRecord]) -> Selection {
        var messageOfRow: [UUID: Int] = [:]
        for (index, record) in records.enumerated() {
            for row in record.rows { messageOfRow[row] = index }
        }

        // Group the rows that are present (compaction may have removed some)
        // into messages, noting where each message starts. A row no record
        // lists is a message of its own.
        let kinds = stepKinds(of: events)
        var rowsByMessage: [Int: [UUID]] = [:]
        var lengthByMessage: [Int: Int] = [:]
        var order: [(kind: StepKind, message: Int?, eventID: UUID)] = []
        var unlisted = records.count
        for (index, event) in events.enumerated() {
            switch kinds[index] {
            case .response:
                let length = event.payload.trimmingCharacters(in: .whitespacesAndNewlines).count
                guard length > 0 else { continue }
                let message: Int
                if let listed = messageOfRow[event.id] {
                    message = listed
                } else {
                    message = unlisted
                    unlisted += 1
                }
                if rowsByMessage[message] == nil { order.append((.response, message, event.id)) }
                rowsByMessage[message, default: []].append(event.id)
                lengthByMessage[message, default: 0] += length
            case .bookkeeping, .work:
                order.append((kinds[index], nil, event.id))
            case .other:
                continue
            }
        }
        let steps: [RunTranscriptStep] = order.map { entry in
            switch entry.kind {
            case .response:
                let message = entry.message ?? 0
                let subagent = message < records.count && records[message].subagent
                return .message(id: message, length: lengthByMessage[message] ?? 0, subagent: subagent)
            case .bookkeeping: return .bookkeeping
            case .work, .other: return .work
            }
        }
        let answer = answerMessageIDs(in: steps)
        guard let first = answer.first,
              let firstPosition = order.firstIndex(where: { $0.message == first }) else {
            return Selection(answer: [], anchor: nil)
        }
        let anchor = order[..<firstPosition].last { $0.kind == .work }?.eventID
        return Selection(answer: answer.compactMap { rowsByMessage[$0] }, anchor: anchor)
    }

    /// `agent.message`, the record a keyed run writes per message.
    public static let messageRecordType = "agent.message"

    private enum StepKind: Equatable {
        case response
        case bookkeeping
        case work
        case other
    }

    /// Tool results carry no tool name, so each is paired with the oldest
    /// unanswered tool use, in order.
    private static func stepKinds(of events: [Event]) -> [StepKind] {
        var pendingUses: [Bool] = []
        return events.map { event in
            switch event.type {
            case "agent.response":
                return .response
            case "tool.use":
                let bookkeeping = isBookkeepingTool(toolName(fromUsePayload: event.payload))
                pendingUses.append(bookkeeping)
                return bookkeeping ? .bookkeeping : .work
            case "tool.result", "tool.result.failed":
                let bookkeeping = pendingUses.isEmpty ? false : pendingUses.removeFirst()
                return bookkeeping ? .bookkeeping : .work
            case "permission.denied", "permission.approval.requested", "permission.request.resolved":
                return .bookkeeping
            default:
                return .other
            }
        }
    }

    /// The tool name from a `tool.use` payload, `Using tool: <name>[: <input>]`.
    public static func toolName(fromUsePayload payload: String) -> String {
        let prefix = "Using tool: "
        guard payload.hasPrefix(prefix) else { return "" }
        return String(payload.dropFirst(prefix.count).prefix { $0 != ":" }).trimmingCharacters(in: .whitespaces)
    }
}
