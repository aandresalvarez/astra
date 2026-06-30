import Foundation

enum CopilotUtilityOutputRendering {
    static func nonEmptyText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isFinalAssistantMessageLine(_ line: String) -> Bool {
        eventType(in: jsonObject(from: line))?.lowercased() == "assistant.message"
    }

    static func isTerminalLine(_ line: String) -> Bool {
        let terminalTypes: Set<String> = [
            "assistant.turn_end",
            "session.shutdown",
            "result",
            "completed",
            "complete"
        ]
        guard let type = eventType(in: jsonObject(from: line))?.lowercased() else {
            return false
        }
        return terminalTypes.contains(type)
    }

    private static func eventType(in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        for key in ["type", "event", "kind", "sessionUpdate", "name"] {
            if let value = object[key] as? String {
                return value
            }
        }
        for key in ["data", "payload", "message"] {
            if let nested = object[key] as? [String: Any],
               let value = eventType(in: nested) {
                return value
            }
        }
        return nil
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
