import Foundation
import MCPServerKit

/// The broker supplies a reader bound to its task. Callers cannot choose a
/// database, task, or filesystem path, and this route has no write operation.
public protocol TaskHistoryReading: Sendable {
    func readHistory(_ request: TaskHistoryReadRequest) throws -> [String: Any]
}

public struct TaskHistoryReadRequest: Sendable {
    public let eventID: UUID?
    public let beforeID: UUID?
    public let offset: Int

    public static func parse(_ arguments: [String: Any]) -> Self? {
        guard Set(arguments.keys).isSubset(of: ["event_id", "before_id", "offset"]) else { return nil }
        func uuid(_ key: String) -> UUID? { (arguments[key] as? String).flatMap(UUID.init(uuidString:)) }
        let eventID = uuid("event_id"), beforeID = uuid("before_id")
        guard arguments["event_id"] == nil || eventID != nil,
              arguments["before_id"] == nil || beforeID != nil,
              eventID == nil || beforeID == nil else { return nil }
        let offset: Int
        if let raw = arguments["offset"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0,
                  value.doubleValue <= Double(Int32.max), value.doubleValue.rounded() == value.doubleValue else { return nil }
            offset = value.intValue
        } else { offset = 0 }
        guard offset == 0 || eventID != nil else { return nil }
        return Self(eventID: eventID, beforeID: beforeID, offset: offset)
    }
}

enum TaskHistoryHostControlPolicy {
    static func handle(arguments: [String: Any], reader: (any TaskHistoryReading)?) -> MCPServerReply {
        guard let request = TaskHistoryReadRequest.parse(arguments) else {
            return .error(code: -32602, message: "history accepts before_id for older pages, or event_id and a nonnegative character offset for exact evidence.")
        }
        guard let reader else {
            return .error(code: -32000, message: "Task history is unavailable on this transport. Use the supplied inline context; do not assume missing history is empty.")
        }
        do {
            let result = try reader.readHistory(request)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            return .result(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false])
        } catch {
            return .error(code: -32000, message: "History retrieval failed: \(error.localizedDescription)")
        }
    }

    static let schema: [String: Any] = [
        "name": "history",
        "description": "Read this task's original durable events. No arguments returns the newest 10 events; use next_before_id for older pages. Fetch exact payload chunks with event_id and next_offset. Summaries are navigation aids; original events are evidence.",
        "inputSchema": ["type": "object", "properties": [
            "before_id": ["type": "string", "description": "next_before_id from a previous page."],
            "event_id": ["type": "string", "description": "Event UUID for exact payload retrieval."],
            "offset": ["type": "integer", "minimum": 0, "description": "Character offset, returned as next_offset. Only with event_id."]
        ], "additionalProperties": false]
    ]
}
