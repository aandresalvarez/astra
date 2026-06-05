import Foundation
import SwiftData

@Model
final class TaskEvent {
    var id: UUID
    var task: AgentTask?
    var run: TaskRun?
    var type: String
    var payload: String
    var timestamp: Date
    // Agent Teams identity
    var agentName: String?    // e.g. "pro-agent", nil = lead/orchestrator
    var agentId: String?      // e.g. "pro-agent@rest-api-debate"
    var teamName: String?     // e.g. "rest-api-debate"
    var category: String       // "lifecycle", "conversation", "tool", "system", "team"

    init(task: AgentTask, type: String, payload: String = "", run: TaskRun? = nil,
         agentName: String? = nil, agentId: String? = nil, teamName: String? = nil) {
        self.id = UUID()
        self.task = task
        self.run = run
        self.type = type
        self.payload = payload
        self.timestamp = Date()
        self.agentName = agentName
        self.agentId = agentId
        self.teamName = teamName
        self.category = Self.categoryFor(type: type)
    }

    convenience init(task: AgentTask, eventType: TaskEventType, payload: String = "", run: TaskRun? = nil,
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

    var eventType: TaskEventType? {
        TaskEventType(rawValue: type)
    }

    var typedCategory: TaskEventCategory {
        TaskEventTypes.category(forRawValue: type)
    }

    func hasType(_ eventType: TaskEventType) -> Bool {
        type == eventType.rawValue
    }

    func decodePayload<T: Decodable>(
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

    static func encodePayload<T: Encodable>(
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

    static func categoryFor(type: String) -> String {
        TaskEventTypes.category(forRawValue: type).rawValue
    }
}

enum TaskEventPayloadEncodeError: Error, Equatable, CustomStringConvertible {
    case invalidUTF8
    case encodingFailed(String)

    var description: String {
        switch self {
        case .invalidUTF8:
            "Encoded event payload is not valid UTF-8."
        case .encodingFailed(let message):
            "Could not encode event payload: \(message)"
        }
    }
}

enum TaskEventPayloadCodec {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
