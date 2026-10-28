import Foundation
import SwiftData

/// Metadata on the existing immutable submission envelope, without changing
/// the SwiftData schema or manufacturing policy for a V15 request.
public enum TaskTurnOwnerBinding: Equatable {
    case legacy
    case owner(PersistentIdentifier)
    case invalid

    public init(json: String?) {
        guard let json else { self = .legacy; return }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self = .invalid; return
        }
        guard let value = object["taskOwnerID"] else { self = .legacy; return }
        guard !(value is NSNull),
              let encoded = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let owner = try? JSONDecoder().decode(PersistentIdentifier.self, from: encoded),
              owner.storeIdentifier != nil else { self = .invalid; return }
        self = .owner(owner)
    }

    /// A restored request belongs to the local task being restored. A PID from
    /// a different store (even a well-formed one) cannot authorize access here.
    public static func rebinding(_ json: String?, to task: AgentTask) -> String? {
        let json = json ?? "{}"
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return json }
        object["taskOwnerID"] = NSNull()
        if task.persistentModelID.storeIdentifier != nil,
           let encoded = try? JSONEncoder().encode(task.persistentModelID),
           let owner = try? JSONSerialization.jsonObject(with: encoded) {
            object["taskOwnerID"] = owner
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
              let result = String(data: encoded, encoding: .utf8) else { return json }
        return result
    }

    public static func isLegacyPolicy(_ json: String?) -> Bool {
        guard let json else { return true }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if case .owner = Self(json: json) { return Set(object.keys) == ["taskOwnerID"] }
        return false
    }
}
