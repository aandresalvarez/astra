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

public struct StreamToolResultBlock: Decodable {
    public let type: String
    public let tool_use_id: String?
    public let content: ToolResultContent?

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
    case toolResult(toolId: String, content: String)
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
                switch block.type {
                case "thinking":
                    if firstThinking == nil, let text = block.thinking {
                        firstThinking = .thinking(text: text)
                    }
                case "text":
                    if let text = block.text {
                        events.append(.text(text: text))
                    }
                case "tool_use":
                    if let name = block.name, let id = block.id {
                        let inputDict = block.input?.mapValues { $0.value }
                        switch name {
                        case "TeamCreate":
                            let teamName = inputDict?["team_name"] as? String ?? ""
                            let desc = inputDict?["description"] as? String ?? ""
                            events.append(.teamCreated(name: teamName, description: desc))
                            continue
                        case "TeamDelete":
                            let teamName = inputDict?["team_name"] as? String ?? ""
                            events.append(.teamDeleted(name: teamName))
                            continue
                        case "SendMessage":
                            let to = inputDict?["to"] as? String ?? inputDict?["recipient"] as? String ?? ""
                            let msgContent: String
                            if let msg = inputDict?["message"] as? String {
                                msgContent = msg
                            } else if let content = inputDict?["content"] as? String {
                                msgContent = content
                            } else {
                                msgContent = inputDict?["summary"] as? String ?? ""
                            }
                            let msgType = inputDict?["type"] as? String ?? "message"
                            if msgType == "shutdown_request" {
                                events.append(.toolUse(name: name, id: id, input: inputDict))
                            } else {
                                events.append(.teamMessage(from: "lead", to: to, content: msgContent))
                            }
                            continue
                        default:
                            events.append(.toolUse(name: name, id: id, input: inputDict))
                        }
                    }
                default:
                    break
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
                let results = blocks.compactMap { block -> (String, String)? in
                    guard block.type == "tool_result" else { return nil }
                    let text = block.textContent
                    return text.isEmpty ? nil : (block.tool_use_id ?? "", text)
                }
                if let first = results.first {
                    return [.toolResult(toolId: first.0, content: first.1)]
                }
            }
            return [.toolResult(toolId: "", content: "")]

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
                totalInput = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)
                totalOutput = usage.output_tokens ?? 0
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

    private static func parsedUsageEvent(from usage: StreamUsage) -> ParsedEvent? {
        let totalInput = (usage.input_tokens ?? 0)
            + (usage.cache_read_input_tokens ?? 0)
            + (usage.cache_creation_input_tokens ?? 0)
        let totalOutput = usage.output_tokens ?? 0
        guard totalInput > 0 || totalOutput > 0 else { return nil }
        return .usage(totalInputTokens: totalInput, totalOutputTokens: totalOutput)
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
