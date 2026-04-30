import Foundation

public enum AstraRunProtocolEvent: Sendable, Equatable {
    public enum TodoStatus: String, Codable, Sendable, Equatable, Hashable {
        case pending
        case done
    }

    public struct TodoItem: Codable, Sendable, Equatable, Hashable {
        public let text: String
        public let status: TodoStatus

        public init(text: String, status: TodoStatus) {
            self.text = text
            self.status = status
        }
    }

    case todoReplace(items: [TodoItem])
    case complete(summary: String, verifiedBy: String?)

    public var taskEventType: String {
        switch self {
        case .todoReplace:
            "astra.todo.replace"
        case .complete:
            "astra.complete"
        }
    }

    public var normalizedPayload: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data?
        switch self {
        case .todoReplace(let items):
            data = try? encoder.encode(NormalizedTodoReplace(items: items))
        case .complete(let summary, let verifiedBy):
            data = try? encoder.encode(NormalizedComplete(summary: summary, verifiedBy: verifiedBy))
        }

        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func decodeNormalizedPayload(_ payload: String) -> AstraRunProtocolEvent? {
        guard let result = AstraRunProtocolParser.parseMarkerLine(AstraRunProtocolParser.markerPrefix + payload),
              case .valid(let event) = result else {
            return nil
        }
        return event
    }
}

public enum AstraRunProtocolLimits {
    public static let maxMarkerJSONBytes = 16 * 1024
    public static let maxTodoItems = 12
    public static let maxTodoItemTextCharacters = 180
    public static let maxCompletionSummaryCharacters = 1_200
    public static let maxVerifiedByCharacters = 240
    public static let maxInvalidEventsPerRun = 5
}

public enum AstraRunProtocolParsedEvent: Sendable, Equatable {
    case valid(AstraRunProtocolEvent)
    case invalid(reason: String)

    public var taskEventType: String {
        switch self {
        case .valid(let event):
            event.taskEventType
        case .invalid:
            "astra.protocol.invalid"
        }
    }

    public var normalizedPayload: String {
        switch self {
        case .valid(let event):
            return event.normalizedPayload
        case .invalid(let reason):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = NormalizedInvalid(reason: String(reason.prefix(160)))
            guard let data = try? encoder.encode(payload),
                  let string = String(data: data, encoding: .utf8) else {
                return #"{"reason":"invalid protocol marker","type":"protocol.invalid","v":1}"#
            }
            return string
        }
    }
}

public enum AstraRunProtocolTextFilterOutput: Sendable, Equatable {
    case text(String)
    case protocolEvent(AstraRunProtocolParsedEvent)
}

public struct AstraRunProtocolTextFilterResult: Sendable, Equatable {
    public let outputs: [AstraRunProtocolTextFilterOutput]

    public init(outputs: [AstraRunProtocolTextFilterOutput] = []) {
        self.outputs = outputs
    }
}

public struct AstraRunProtocolTextFilter: Sendable {
    private var bufferedLine = ""

    public init() {}

    public mutating func process(text: String) -> AstraRunProtocolTextFilterResult {
        guard !text.isEmpty else { return AstraRunProtocolTextFilterResult() }

        var outputs: [AstraRunProtocolTextFilterOutput] = []
        var candidate = bufferedLine + text
        bufferedLine = ""

        while let newlineIndex = candidate.firstIndex(of: "\n") {
            let line = String(candidate[candidate.startIndex..<newlineIndex])
            appendCompleteLine(line, to: &outputs)
            candidate = String(candidate[candidate.index(after: newlineIndex)...])
        }

        guard !candidate.isEmpty else {
            return AstraRunProtocolTextFilterResult(outputs: outputs)
        }

        if shouldBuffer(candidate) {
            bufferedLine = candidate
        } else {
            outputs.append(.text(candidate))
        }

        return AstraRunProtocolTextFilterResult(outputs: outputs)
    }

    public mutating func flush() -> AstraRunProtocolTextFilterResult {
        guard !bufferedLine.isEmpty else { return AstraRunProtocolTextFilterResult() }
        var outputs: [AstraRunProtocolTextFilterOutput] = []
        appendFinalLine(bufferedLine, to: &outputs)
        bufferedLine = ""
        return AstraRunProtocolTextFilterResult(outputs: outputs)
    }

    private func appendCompleteLine(_ line: String, to outputs: inout [AstraRunProtocolTextFilterOutput]) {
        if let parsed = AstraRunProtocolParser.parseMarkerLine(line) {
            outputs.append(.protocolEvent(parsed))
        } else {
            outputs.append(.text(line + "\n"))
        }
    }

    private func appendFinalLine(_ line: String, to outputs: inout [AstraRunProtocolTextFilterOutput]) {
        if let parsed = AstraRunProtocolParser.parseMarkerLine(line) {
            outputs.append(.protocolEvent(parsed))
        } else {
            outputs.append(.text(line))
        }
    }

    private func shouldBuffer(_ candidate: String) -> Bool {
        AstraRunProtocolParser.markerPrefix.hasPrefix(candidate) ||
            candidate.hasPrefix(AstraRunProtocolParser.markerPrefix)
    }
}

public enum AstraRunProtocolParser {
    public static let markerPrefix = "ASTRA_EVENT "

    public static func parseMarkerLine(_ line: String) -> AstraRunProtocolParsedEvent? {
        guard line.hasPrefix(markerPrefix) else { return nil }

        let json = String(line.dropFirst(markerPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard json.utf8.count <= AstraRunProtocolLimits.maxMarkerJSONBytes else {
            return .invalid(reason: "marker JSON too large")
        }
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return .invalid(reason: "missing JSON payload")
        }

        let envelope: RawEnvelope
        do {
            envelope = try JSONDecoder().decode(RawEnvelope.self, from: data)
        } catch {
            return .invalid(reason: "malformed JSON")
        }

        guard let version = envelope.v else {
            return .invalid(reason: "missing version")
        }
        guard version == 1 else {
            return .invalid(reason: "unsupported version")
        }

        guard let type = envelope.type, !type.isEmpty else {
            return .invalid(reason: "missing type")
        }

        switch type {
        case "todo.replace":
            return parseTodoReplace(envelope)
        case "complete":
            return parseComplete(envelope)
        default:
            return .invalid(reason: "unsupported type")
        }
    }

    private static func parseTodoReplace(_ envelope: RawEnvelope) -> AstraRunProtocolParsedEvent {
        guard let rawItems = envelope.items, !rawItems.isEmpty else {
            return .invalid(reason: "missing todo items")
        }
        guard rawItems.count <= AstraRunProtocolLimits.maxTodoItems else {
            return .invalid(reason: "too many todo items")
        }

        var items: [AstraRunProtocolEvent.TodoItem] = []
        items.reserveCapacity(rawItems.count)

        for rawItem in rawItems {
            guard let text = rawItem.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return .invalid(reason: "invalid todo item")
            }
            guard text.count <= AstraRunProtocolLimits.maxTodoItemTextCharacters else {
                return .invalid(reason: "todo item too long")
            }
            guard let statusValue = rawItem.status,
                  let status = AstraRunProtocolEvent.TodoStatus(rawValue: statusValue) else {
                return .invalid(reason: "invalid todo status")
            }
            items.append(AstraRunProtocolEvent.TodoItem(text: text, status: status))
        }

        return .valid(.todoReplace(items: items))
    }

    private static func parseComplete(_ envelope: RawEnvelope) -> AstraRunProtocolParsedEvent {
        guard let summary = envelope.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return .invalid(reason: "missing completion summary")
        }
        guard summary.count <= AstraRunProtocolLimits.maxCompletionSummaryCharacters else {
            return .invalid(reason: "completion summary too long")
        }

        let verifiedBy = envelope.verifiedBy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if let verifiedBy, verifiedBy.count > AstraRunProtocolLimits.maxVerifiedByCharacters {
            return .invalid(reason: "verification summary too long")
        }

        return .valid(.complete(summary: summary, verifiedBy: verifiedBy))
    }
}

private struct RawEnvelope: Decodable {
    let v: Int?
    let type: String?
    let items: [RawTodoItem]?
    let summary: String?
    let verifiedBy: String?
}

private struct RawTodoItem: Decodable {
    let text: String?
    let status: String?
}

private struct NormalizedTodoReplace: Encodable {
    let v = 1
    let type = "todo.replace"
    let items: [AstraRunProtocolEvent.TodoItem]
}

private struct NormalizedComplete: Encodable {
    let v = 1
    let type = "complete"
    let summary: String
    let verifiedBy: String?
}

private struct NormalizedInvalid: Encodable {
    let v = 1
    let type = "protocol.invalid"
    let reason: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
