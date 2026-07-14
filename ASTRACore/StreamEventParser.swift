import Foundation

// MARK: - Stream JSON Event Types

public struct StreamSystemEvent: Decodable {
    public let type: String
    public let subtype: String?
    public let model: String?
    public let session_id: String?
    public let task_id: String?
    public let task_type: String?
    public let description: String?
    public let prompt: String?
    public let uuid: String?
    public let status: String?
    public let summary: String?
}

public struct StreamUsage: Decodable {
    public let input_tokens: Int?
    public let output_tokens: Int?
    public let cache_read_input_tokens: Int?
    public let cache_creation_input_tokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
}

public struct StreamContentBlock: Decodable {
    public let type: String
    public let text: String?
    public let thinking: String?
    public let name: String?
    public let id: String?
    public let input: [String: AnyCodable]?
}

public struct StreamMessage: Decodable {
    public let model: String?
    public let content: [StreamContentBlock]?
    public let usage: StreamUsage?
}

public struct StreamAssistantEvent: Decodable {
    public let type: String
    public let message: StreamMessage?
}

public struct StreamPartialEventEnvelope: Decodable {
    public let type: String
    public let event: StreamPartialEvent?
}

public struct StreamPartialEvent: Decodable {
    public let type: String
    public let message: StreamMessage?
    public let content_block: StreamContentBlock?
    public let delta: StreamPartialDelta?
    public let usage: StreamUsage?
}

public struct StreamPartialDelta: Decodable {
    public let type: String?
    public let text: String?
    public let thinking: String?
}

public struct StreamToolResultBlock: Decodable {
    public let type: String
    public let tool_use_id: String?
    public let content: ToolResultContent?
    /// Claude can report a failed tool call inside an otherwise successful
    /// provider process. Preserve that outcome so task completion does not
    /// mistake process exit 0 for completion of the requested external action.
    public let is_error: Bool?

    public enum ToolResultContent: Decodable {
        case string(String)
        case blocks([TextBlock])

        public struct TextBlock: Decodable {
            public let type: String
            public let text: String?
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                self = .string(str)
            } else if let blocks = try? container.decode([TextBlock].self) {
                self = .blocks(blocks)
            } else {
                self = .string("")
            }
        }
    }

    public var textContent: String {
        switch content {
        case .string(let s): return s
        case .blocks(let blocks): return blocks.compactMap(\.text).joined(separator: "\n")
        case .none: return ""
        }
    }
}

public struct StreamUserEvent: Decodable {
    public let type: String
    public let message: StreamUserMessage?

    public struct StreamUserMessage: Decodable {
        public let content: [StreamToolResultBlock]?
    }
}

public struct StreamModelUsageEntry: Decodable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let costUSD: Double?
}

public struct StreamResultEvent: Decodable {
    public let type: String
    public let subtype: String?
    public let is_error: Bool?
    public let result: String?
    public let duration_ms: Int?
    public let num_turns: Int?
    public let total_cost_usd: Double?
    public let usage: StreamUsage?
    public let modelUsage: [String: StreamModelUsageEntry]?
    public let stop_reason: String?
}

public struct AnyCodable: Decodable {
    public let value: Any

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else {
            value = NSNull()
        }
    }
}

// MARK: - File Change

public struct FileChange: Identifiable {
    public let id = UUID()
    public let path: String
    public let changeType: FileChangeType
    public let content: String?
    public let oldString: String?
    public let newString: String?
    public let timestamp: Date

    public enum FileChangeType: String {
        case write = "Write"
        case edit = "Edit"
    }

    public init(path: String, changeType: FileChangeType, content: String?,
                oldString: String?, newString: String?, timestamp: Date) {
        self.path = path
        self.changeType = changeType
        self.content = content
        self.oldString = oldString
        self.newString = newString
        self.timestamp = timestamp
    }
}

// MARK: - Parsed Event

public enum ParsedEvent {
    case systemInit(model: String?, sessionId: String?)
    case thinking(text: String)
    case text(text: String)
    case toolUse(name: String, id: String, input: [String: Any]?)
    case toolResult(toolId: String, content: String, isError: Bool = false)
    case usage(totalInputTokens: Int, totalOutputTokens: Int)
    case result(text: String?, costUSD: Double?, totalInputTokens: Int, totalOutputTokens: Int, durationMs: Int?, numTurns: Int?, isError: Bool)
    case teammateStarted(taskId: String, name: String, prompt: String)
    case teammateCompleted(taskId: String, name: String)
    case teamCreated(name: String, description: String)
    case teamDeleted(name: String)
    case teamMessage(from: String, to: String, content: String)
    case permissionDenied(tool: String, reason: String)
    case astraProtocol(AstraRunProtocolParsedEvent)
    case unknown(type: String)
}

// MARK: - Parser

public enum StreamEventParser {
    public static func parse(line: String) -> ParsedEvent? {
        parseAll(line: line).first
    }

    public static func parseAll(line: String) -> [ParsedEvent] {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let data = line.data(using: .utf8) else { return [] }

        guard let baseEvent = try? JSONDecoder().decode(StreamSystemEvent.self, from: data) else {
            return []
        }

        switch baseEvent.type {
        case "system":
            let agentTaskTypes: Set<String> = ["in_process_teammate", "local_agent"]
            if baseEvent.subtype == "task_started",
               let taskType = baseEvent.task_type, agentTaskTypes.contains(taskType) {
                let name = extractAgentName(from: baseEvent.description) ?? baseEvent.task_id ?? "teammate"
                return [.teammateStarted(
                    taskId: baseEvent.task_id ?? "",
                    name: name,
                    prompt: baseEvent.prompt ?? ""
                )]
            }
            if baseEvent.subtype == "task_completed" || baseEvent.subtype == "task_notification" {
                let name = baseEvent.summary ?? extractAgentName(from: baseEvent.description) ?? baseEvent.task_id ?? "teammate"
                return [.teammateCompleted(
                    taskId: baseEvent.task_id ?? "",
                    name: name
                )]
            }
            return [.systemInit(model: baseEvent.model, sessionId: baseEvent.session_id)]

        case "assistant":
            guard let event = try? JSONDecoder().decode(StreamAssistantEvent.self, from: data),
                  let content = event.message?.content else {
                return []
            }
            var events: [ParsedEvent] = []
            var firstThinking: ParsedEvent?
            for block in content {
                let blockEvents = parsedEvents(from: block, includeThinking: false)
                if blockEvents.isEmpty, firstThinking == nil, block.type == "thinking", let text = block.thinking {
                    firstThinking = .thinking(text: text)
                } else {
                    events.append(contentsOf: blockEvents)
                }
            }
            if events.isEmpty, let firstThinking {
                events.append(firstThinking)
            }
            if let usage = event.message?.usage,
               let usageEvent = parsedUsageEvent(from: usage) {
                events.append(usageEvent)
            }
            return events

        case "stream_event":
            guard let envelope = try? JSONDecoder().decode(StreamPartialEventEnvelope.self, from: data),
                  let event = envelope.event else {
                return []
            }
            return parsedEvents(from: event)

        case "user":
            let lower = line.lowercased()
            let denialKeywords = ["permission denied", "not allowed", "user denied",
                                  "rejected by user", "tool was blocked", "user rejected"]
            if denialKeywords.contains(where: { lower.contains($0) }) {
                let tool = extractDeniedTool(from: line) ?? "unknown"
                let reason = extractDenialReason(from: line)
                return [.permissionDenied(tool: tool, reason: reason)]
            }
            if let userEvent = try? JSONDecoder().decode(StreamUserEvent.self, from: data),
               let blocks = userEvent.message?.content {
                let results = blocks.compactMap { block -> (String, String, Bool)? in
                    guard block.type == "tool_result" else { return nil }
                    let text = block.textContent
                    return text.isEmpty ? nil : (block.tool_use_id ?? "", text, block.is_error ?? false)
                }
                if !results.isEmpty {
                    return results.map {
                        .toolResult(toolId: $0.0, content: $0.1, isError: $0.2)
                    }
                }
            }
            return [.toolResult(toolId: "", content: "", isError: false)]

        case "result":
            guard let event = try? JSONDecoder().decode(StreamResultEvent.self, from: data) else {
                return []
            }

            var totalInput = 0
            var totalOutput = 0

            if let modelUsage = event.modelUsage {
                for (_, entry) in modelUsage {
                    totalInput += (entry.inputTokens ?? 0) + (entry.cacheReadInputTokens ?? 0) + (entry.cacheCreationInputTokens ?? 0)
                    totalOutput += entry.outputTokens ?? 0
                }
            } else if let usage = event.usage {
                totalInput = totalInputTokens(from: usage)
                totalOutput = totalOutputTokens(from: usage)
            }

            return [.result(
                text: event.result,
                costUSD: event.total_cost_usd,
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                durationMs: event.duration_ms,
                numTurns: event.num_turns,
                isError: event.is_error ?? false
            )]

        default:
            return [.unknown(type: baseEvent.type)]
        }
    }

    private static func parsedEvents(from event: StreamPartialEvent) -> [ParsedEvent] {
        switch event.type {
        case "message_start":
            guard let usage = event.message?.usage,
                  let usageEvent = parsedUsageEvent(from: usage) else { return [] }
            return [usageEvent]
        case "message_delta":
            guard let usage = event.usage,
                  let usageEvent = parsedUsageEvent(from: usage) else { return [] }
            return [usageEvent]
        case "content_block_start":
            return []
        case "content_block_delta":
            guard let delta = event.delta else { return [] }
            if let text = delta.text, !text.isEmpty {
                return [.text(text: text)]
            }
            if let thinking = delta.thinking, !thinking.isEmpty {
                return [.thinking(text: thinking)]
            }
            return []
        default:
            return []
        }
    }

    private static func parsedEvents(from block: StreamContentBlock, includeThinking: Bool) -> [ParsedEvent] {
        switch block.type {
        case "thinking":
            guard includeThinking, let text = block.thinking, !text.isEmpty else { return [] }
            return [.thinking(text: text)]
        case "text":
            guard let text = block.text, !text.isEmpty else { return [] }
            return [.text(text: text)]
        case "tool_use":
            guard let name = block.name, let id = block.id else { return [] }
            return [parsedToolUseEvent(name: name, id: id, input: block.input?.mapValues { $0.value })]
        default:
            return []
        }
    }

    private static func parsedToolUseEvent(name: String, id: String, input: [String: Any]?) -> ParsedEvent {
        switch name {
        case "TeamCreate":
            let teamName = input?["team_name"] as? String ?? ""
            let desc = input?["description"] as? String ?? ""
            return .teamCreated(name: teamName, description: desc)
        case "TeamDelete":
            let teamName = input?["team_name"] as? String ?? ""
            return .teamDeleted(name: teamName)
        case "SendMessage":
            let to = input?["to"] as? String ?? input?["recipient"] as? String ?? ""
            let msgContent: String
            if let msg = input?["message"] as? String {
                msgContent = msg
            } else if let content = input?["content"] as? String {
                msgContent = content
            } else {
                msgContent = input?["summary"] as? String ?? ""
            }
            let msgType = input?["type"] as? String ?? "message"
            if msgType == "shutdown_request" {
                return .toolUse(name: name, id: id, input: input)
            }
            return .teamMessage(from: "lead", to: to, content: msgContent)
        default:
            return .toolUse(name: name, id: id, input: input)
        }
    }

    private static func parsedUsageEvent(from usage: StreamUsage) -> ParsedEvent? {
        let totalInput = totalInputTokens(from: usage)
        let totalOutput = totalOutputTokens(from: usage)
        guard totalInput > 0 || totalOutput > 0 else { return nil }
        return .usage(totalInputTokens: totalInput, totalOutputTokens: totalOutput)
    }

    private static func totalInputTokens(from usage: StreamUsage) -> Int {
        let uncachedInput = usage.input_tokens ?? usage.inputTokens ?? 0
        let cachedInput = usage.cachedInputTokens ?? 0
        let cacheReadInput = usage.cache_read_input_tokens
            ?? usage.cacheReadInputTokens
            ?? usage.cacheReadTokens
            ?? 0
        let cacheCreationInput = usage.cache_creation_input_tokens
            ?? usage.cacheCreationInputTokens
            ?? usage.cacheWriteTokens
            ?? 0

        return uncachedInput + cachedInput + cacheReadInput + cacheCreationInput
    }

    private static func totalOutputTokens(from usage: StreamUsage) -> Int {
        usage.output_tokens ?? usage.outputTokens ?? 0
    }

    private static func extractAgentName(from description: String?) -> String? {
        guard let desc = description, !desc.isEmpty else { return nil }
        if let colonIndex = desc.firstIndex(of: ":") {
            let name = desc[desc.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return desc
    }

    private static func extractDeniedTool(from line: String) -> String? {
        for key in ["name", "tool", "toolName", "tool_use_id", "toolUseId"] {
            let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
            if let value = firstRegexCapture(pattern: pattern, in: line), !value.isEmpty {
                return value
            }
        }

        let textPatterns = [
            #"(?i)permission denied:\s*tool\s+([A-Za-z0-9_()./\-]+)"#,
            #"(?i)tool\s+([A-Za-z0-9_()./\-]+)\s+is\s+not\s+allowed"#,
            #"(?i)user denied\s+(?:the\s+)?([A-Za-z0-9_()./\-]+)\s+tool"#
        ]
        for pattern in textPatterns {
            if let value = firstRegexCapture(pattern: pattern, in: line), !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private static func firstRegexCapture(pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractDenialReason(from line: String) -> String {
        if let range = line.range(of: #""text"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let match = line[range]
            if let valueStart = match.range(of: ":") {
                let value = match[valueStart.upperBound...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { return value }
            }
        }
        return "Permission denied"
    }

    public static func extractFileChange(from event: ParsedEvent) -> FileChange? {
        guard case .toolUse(let name, _, let input) = event else { return nil }
        guard let input = input else { return nil }

        switch name {
        case "Write":
            guard let path = input["file_path"] as? String else { return nil }
            let content = input["content"] as? String
            return FileChange(path: path, changeType: .write, content: content, oldString: nil, newString: nil, timestamp: Date())

        case "Edit":
            guard let path = input["file_path"] as? String else { return nil }
            let oldStr = input["old_string"] as? String
            let newStr = input["new_string"] as? String
            return FileChange(path: path, changeType: .edit, content: nil, oldString: oldStr, newString: newStr, timestamp: Date())

        default:
            return nil
        }
    }
}
