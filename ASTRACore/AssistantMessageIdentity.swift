import Foundation

/// A piece of assistant text tied to the provider message it belongs to.
///
/// Providers deliver a message's text as streamed deltas, as one complete
/// final copy, or both. Keying every piece by the provider's own message
/// identity lets the recorder append deltas to a draft and let the final copy
/// replace that draft, instead of guessing from the text whether something is
/// an echo (docs/specs/2026-09-23-provider-message-identity-plan.md).
public struct AssistantMessageFragment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// More text for the message's draft.
        case delta
        /// The message's complete text; it replaces the draft.
        case final
    }

    /// Provider-namespaced and stable for the run, e.g. `claude:msg_01A…#0`.
    public let key: String
    public let kind: Kind
    public let text: String
    /// Written by a subagent rather than the main agent.
    public let isSubagent: Bool

    public init(key: String, kind: Kind, text: String, isSubagent: Bool = false) {
        self.key = key
        self.kind = kind
        self.text = text
        self.isSubagent = isSubagent
    }
}

/// Assistant text carrying provider identity. Parsers emit the raw provider
/// coordinates; `AgentRuntimeEventPipeline` resolves them, so only
/// `.fragment` reaches the recorder.
public enum AssistantMessageEvent: Sendable, Equatable {
    /// Claude `stream_event` `message_start`: a new message begins in the
    /// stream of `parentToolUseID` (`nil` for the main agent).
    case claudeMessageStart(messageID: String, parentToolUseID: String?)
    /// Claude `content_block_delta` text for block `blockIndex` of the current
    /// message in that stream.
    case claudeTextDelta(blockIndex: Int, parentToolUseID: String?, text: String)
    /// One text block of a Claude `assistant` envelope that carries a message
    /// id; an envelope without one stays plain `.text`.
    case claudeTextFinal(messageID: String, parentToolUseID: String?, text: String)
    /// The text of one Cursor `assistant` frame, a message's final copy.
    /// `modelCallID` is `nil` on the last frame of a run, which repeats the
    /// previous message before adding to it.
    case cursorFrame(modelCallID: String?, text: String)
    /// Resolved, keyed text.
    case fragment(AssistantMessageFragment)

    /// The text this event carries, if any.
    public var text: String? {
        switch self {
        case .claudeMessageStart: nil
        case .claudeTextDelta(_, _, let text), .claudeTextFinal(_, _, let text), .cursorFrame(_, let text): text
        case .fragment(let fragment): fragment.text
        }
    }
}

/// Adds Claude message identity to the events parsed from one stream-json
/// line: `message_start` becomes a message boundary, and each text event of a
/// delta or an envelope carries its block index or message id.
public enum ClaudeMessageIdentity {
    public static func annotate(_ events: [AgentEvent], line: String) -> [AgentEvent] {
        guard line.contains("\"type\""),
              let data = line.data(using: .utf8),
              let frame = try? JSONDecoder().decode(ClaudeIdentityFrame.self, from: data) else {
            return events
        }
        switch frame.type {
        case "stream_event":
            guard let event = frame.event else { return events }
            if event.type == "message_start", let messageID = event.message?.id, !messageID.isEmpty {
                return [.assistantMessage(.claudeMessageStart(
                    messageID: messageID,
                    parentToolUseID: frame.parent_tool_use_id
                ))] + events
            }
            guard event.type == "content_block_delta", let index = event.index else { return events }
            return events.map { event in
                guard case .text(let text) = event else { return event }
                return .assistantMessage(.claudeTextDelta(
                    blockIndex: index,
                    parentToolUseID: frame.parent_tool_use_id,
                    text: text
                ))
            }
        case "assistant":
            // Without an id there is nothing to match a draft against.
            guard let messageID = frame.message?.id, !messageID.isEmpty else { return events }
            // The parser emits one `.text` per non-empty text block, in block
            // order, which is the order the resolver numbers them in.
            return events.map { event in
                guard case .text(let text) = event else { return event }
                return .assistantMessage(.claudeTextFinal(
                    messageID: messageID,
                    parentToolUseID: frame.parent_tool_use_id,
                    text: text
                ))
            }
        default:
            return events
        }
    }

    /// The process monitor's view of one line. ASTRA launches Claude with
    /// `--include-partial-messages`, so a main-agent envelope repeats text the
    /// monitor already counted from its deltas: that copy is control, not new
    /// output, for estimated tokens and progress. A subagent's envelopes are
    /// its only copy and stay text.
    public static func monitorEvents(_ events: [ParsedEvent], line: String) -> [ParsedEvent] {
        guard line.contains("\"assistant\""),
              let data = line.data(using: .utf8),
              let frame = try? JSONDecoder().decode(ClaudeIdentityFrame.self, from: data),
              frame.type == "assistant", frame.parent_tool_use_id == nil,
              let messageID = frame.message?.id, !messageID.isEmpty else {
            return events
        }
        return events.map { event in
            guard case .text = event else { return event }
            return .control(type: "assistant.final_copy")
        }
    }

    private struct ClaudeIdentityFrame: Decodable {
        struct Message: Decodable {
            let id: String?
        }

        struct StreamEvent: Decodable {
            let type: String
            let index: Int?
            let message: Message?
        }

        let type: String
        let parent_tool_use_id: String?
        let event: StreamEvent?
        let message: Message?
    }
}

/// Adds Cursor message identity to the events parsed from one stream-json
/// line: an `assistant` frame's text becomes one `cursorFrame` carrying its
/// `model_call_id`, so the resolver can key it.
public enum CursorMessageIdentity {
    public static func annotate(_ events: [AgentEvent], line: String) -> [AgentEvent] {
        guard line.contains("\"assistant\""),
              let data = line.data(using: .utf8),
              let frame = try? JSONDecoder().decode(CursorIdentityFrame.self, from: data),
              frame.type == "assistant" else {
            return events
        }
        // The parser emits one `.text` per text block; the frame is one
        // message, so its blocks join into one final copy.
        let text = events.compactMap { event -> String? in
            if case .text(let text) = event { text } else { nil }
        }.joined()
        guard !text.isEmpty else { return events }
        var annotated: [AgentEvent] = []
        var placed = false
        for event in events {
            guard case .text = event else {
                annotated.append(event)
                continue
            }
            if !placed {
                annotated.append(.assistantMessage(.cursorFrame(modelCallID: frame.model_call_id, text: text)))
                placed = true
            }
        }
        return annotated
    }

    private struct CursorIdentityFrame: Decodable {
        let type: String
        let model_call_id: String?
    }
}

/// Turns raw provider coordinates into stable message keys for one run.
///
/// Claude streams a message's text blocks as deltas addressed by block index
/// under the latest `message_start` of that stream, then re-sends each text
/// block in an envelope addressed by message id. The n-th text block to start
/// streaming and the n-th text envelope of a message are the same block, so
/// both resolve to `claude:<message id>#<n>`.
///
/// A delta without a `message_start` before it has no identity: it resolves to
/// `.unkeyed` and keeps the legacy `.text` path.
public struct AssistantMessageIdentityResolver: Sendable {
    public enum Resolution: Equatable, Sendable {
        /// State only (a message boundary); nothing to record.
        case consumed
        case fragment(AssistantMessageFragment)
        /// Text without provider identity: record it as plain `.text`.
        case unkeyed(String)
    }

    private var currentMessageByStream: [String: String] = [:]
    private var deltaOrdinals: [String: [Int: Int]] = [:]
    private var finalOrdinals: [String: Int] = [:]
    private var cursorOrdinals: [String: Int] = [:]
    /// The last Cursor message's key and its full text, which the id-less
    /// last frame repeats before adding to it.
    private var cursorLast: (key: String, text: String)?
    private var cursorContinuations = 0
    private var cursorUnidentified = 0

    public init() {}

    public mutating func resolve(_ event: AssistantMessageEvent) -> Resolution {
        switch event {
        case .claudeMessageStart(let messageID, let parent):
            currentMessageByStream[parent ?? ""] = messageID
            return .consumed
        case .claudeTextDelta(let index, let parent, let text):
            guard let messageID = currentMessageByStream[parent ?? ""] else { return .unkeyed(text) }
            var ordinals = deltaOrdinals[messageID, default: [:]]
            let ordinal = ordinals[index] ?? ordinals.count
            ordinals[index] = ordinal
            deltaOrdinals[messageID] = ordinals
            return .fragment(AssistantMessageFragment(
                key: Self.claudeKey(messageID: messageID, ordinal: ordinal),
                kind: .delta,
                text: text,
                isSubagent: parent != nil
            ))
        case .claudeTextFinal(let messageID, let parent, let text):
            guard !messageID.isEmpty else { return .unkeyed(text) }
            let ordinal = finalOrdinals[messageID, default: 0]
            finalOrdinals[messageID] = ordinal + 1
            return .fragment(AssistantMessageFragment(
                key: Self.claudeKey(messageID: messageID, ordinal: ordinal),
                kind: .final,
                text: text,
                isSubagent: parent != nil
            ))
        case .cursorFrame(let modelCallID, let text):
            return resolveCursorFrame(modelCallID: modelCallID, text: text)
        case .fragment(let fragment):
            return .fragment(fragment)
        }
    }

    /// Cursor sends each message whole, once per model call. The run's last
    /// frame has no `model_call_id` and holds the previous message's full
    /// text followed by the new text; that addition is keyed as its own
    /// continuation of the previous message, so the committed message is
    /// never rewritten and nothing is recorded twice. Any other id-less frame
    /// gets a synthesized key.
    private mutating func resolveCursorFrame(modelCallID: String?, text: String) -> Resolution {
        let key: String
        var finalText = text
        if let modelCallID, !modelCallID.isEmpty {
            let ordinal = cursorOrdinals[modelCallID, default: 0]
            cursorOrdinals[modelCallID] = ordinal + 1
            key = "cursor:\(modelCallID)#\(ordinal)"
            cursorLast = (key, text)
        } else if let last = cursorLast, !last.text.isEmpty, text.hasPrefix(last.text) {
            guard text.count > last.text.count else { return .consumed }
            cursorContinuations += 1
            key = "\(last.key)+\(cursorContinuations)"
            finalText = String(text.dropFirst(last.text.count))
            cursorLast = (last.key, text)
        } else {
            cursorUnidentified += 1
            key = "cursor:frame-\(cursorUnidentified)"
            cursorLast = (key, text)
        }
        return .fragment(AssistantMessageFragment(key: key, kind: .final, text: finalText))
    }

    static func claudeKey(messageID: String, ordinal: Int) -> String {
        "claude:\(messageID)#\(ordinal)"
    }
}
