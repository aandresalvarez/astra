import Foundation
import SwiftData

@Model
public final class TaskEvent {
    public var id: UUID
    public var task: AgentTask?
    public var run: TaskRun?
    public var type: String
    public var payload: String
    public var timestamp: Date
    // Agent Teams identity
    public var agentName: String?    // e.g. "pro-agent", nil = lead/orchestrator
    public var agentId: String?      // e.g. "pro-agent@rest-api-debate"
    public var teamName: String?     // e.g. "rest-api-debate"
    public var category: String       // "lifecycle", "conversation", "tool", "system", "team"

    public init(task: AgentTask, type: String, payload: String = "", run: TaskRun? = nil,
         agentName: String? = nil, agentId: String? = nil, teamName: String? = nil) {
        let now = Date()
        self.id = UUID()
        self.task = task
        self.run = run
        self.type = type
        self.payload = payload
        self.timestamp = now
        self.agentName = agentName
        self.agentId = agentId
        self.teamName = teamName
        self.category = Self.categoryFor(type: type)
        task.updatedAt = now
    }

    public convenience init(task: AgentTask, eventType: TaskEventType, payload: String = "", run: TaskRun? = nil,
                     agentName: String? = nil, agentId: String? = nil, teamName: String? = nil) {
        self.init(
            task: task,
            type: eventType.rawValue,
            payload: payload,
            run: run,
            agentName: agentName,
            agentId: agentId,
            teamName: teamName
        )
    }

    public var eventType: TaskEventType? {
        TaskEventType(rawValue: type)
    }

    public var typedCategory: TaskEventCategory {
        TaskEventTypes.category(forRawValue: type)
    }

    public func hasType(_ eventType: TaskEventType) -> Bool {
        type == eventType.rawValue
    }

    public func decodePayload<T: Decodable>(
        as type: T.Type,
        expecting expectedType: TaskEventType? = nil,
        decoder: JSONDecoder = JSONDecoder()
    ) -> Result<T, TaskEventPayloadDecodeError> {
        if let expectedType, self.type != expectedType.rawValue {
            return .failure(.typeMismatch(expected: expectedType.rawValue, actual: self.type))
        }
        guard let data = payload.data(using: .utf8) else {
            return .failure(.invalidUTF8)
        }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
    }

    public static func encodePayload<T: Encodable>(
        _ payload: T,
        encoder: JSONEncoder = TaskEventPayloadCodec.makeEncoder()
    ) -> Result<String, TaskEventPayloadEncodeError> {
        do {
            let data = try encoder.encode(payload)
            guard let json = String(data: data, encoding: .utf8) else {
                return .failure(.invalidUTF8)
            }
            return .success(json)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }
    }

    public static func payloadString<T: Encodable>(
        _ payload: T,
        fallback: String = "{}",
        encoder: JSONEncoder = TaskEventPayloadCodec.makeEncoder()
    ) -> String {
        switch encodePayload(payload, encoder: encoder) {
        case .success(let json):
            json
        case .failure:
            fallback
        }
    }

    public static func structuredPayloadEvent<T: Encodable>(
        task: AgentTask,
        eventType: TaskEventType,
        payload: T,
        fallbackPayload: String = "{}",
        run: TaskRun? = nil,
        agentName: String? = nil,
        agentId: String? = nil,
        teamName: String? = nil,
        encoder: JSONEncoder = TaskEventPayloadCodec.makeEncoder()
    ) -> TaskEvent {
        TaskEvent(
            task: task,
            eventType: eventType,
            payload: payloadString(payload, fallback: fallbackPayload, encoder: encoder),
            run: run,
            agentName: agentName,
            agentId: agentId,
            teamName: teamName
        )
    }

    public static func structuredPayloadEvent<T: Encodable>(
        task: AgentTask,
        type: String,
        payload: T,
        fallbackPayload: String = "{}",
        run: TaskRun? = nil,
        agentName: String? = nil,
        agentId: String? = nil,
        teamName: String? = nil,
        encoder: JSONEncoder = TaskEventPayloadCodec.makeEncoder()
    ) -> TaskEvent {
        TaskEvent(
            task: task,
            type: type,
            payload: payloadString(payload, fallback: fallbackPayload, encoder: encoder),
            run: run,
            agentName: agentName,
            agentId: agentId,
            teamName: teamName
        )
    }

    public static func categoryFor(type: String) -> String {
        TaskEventTypes.category(forRawValue: type).rawValue
    }
}

public enum TaskEventPayloadEncodeError: Error, Equatable, CustomStringConvertible {
    case invalidUTF8
    case encodingFailed(String)

    public var description: String {
        switch self {
        case .invalidUTF8:
            "Encoded event payload is not valid UTF-8."
        case .encodingFailed(let message):
            "Could not encode event payload: \(message)"
        }
    }
}

public enum TaskEventPayloadCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func makeISO8601Encoder() -> JSONEncoder {
        let encoder = makeEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeUnescapedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeISO8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
