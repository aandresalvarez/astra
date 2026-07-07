import Foundation

/// Pure JSON-decode slice of `Astra/Services/Tasks/TaskWorkerHandoffService.swift`,
/// extracted for Track A4 (`ASTRAPersistence`) so
/// `TaskContextStateManager.swift` can decode a handoff payload without
/// depending on the rest of that app-side service (which inserts
/// `TaskEvent`s, calls `AppLogger`, and refreshes UI-facing derived state).
/// `TaskWorkerHandoffService.decode` delegates here so its existing callers
/// are unaffected.
public enum TaskWorkerHandoffCodec {
    public static func decode(_ payload: String) -> TaskWorkerHandoffPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskWorkerHandoffPayload.self, from: data)
    }
}
