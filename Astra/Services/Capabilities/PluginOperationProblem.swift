import Foundation

/// A saved or uncertain operation is not an ordinary save failure. Callers
/// must keep its recovery state and must not undo committed credential edits.
enum PluginOperationProblem: Error, LocalizedError {
    case savedRecoveryPending(UUID)
    case commitUncertain(UUID)

    var operationID: UUID {
        switch self {
        case .savedRecoveryPending(let id), .commitUncertain(let id): id
        }
    }

    var errorDescription: String? {
        switch self {
        case .savedRecoveryPending:
            "The change was saved, but its recovery copy is pending. ASTRA will retry it."
        case .commitUncertain:
            "ASTRA couldn't confirm this save. Its recovery information was kept; check recovery before repeating the change."
        }
    }

    static func preventsRollback(_ error: Error) -> Bool { error is Self }
}
