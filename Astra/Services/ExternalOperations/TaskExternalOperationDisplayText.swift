import Foundation
import ASTRAModels

/// Shared, bounded human-readable text for operation state. Keeping this
/// mapping outside SwiftUI lets notifications and views agree without either
/// layer depending on raw backend output.
enum TaskExternalOperationPresentation {
    static func executionLabel(_ state: TaskExternalOperationExecutionState) -> String {
        switch state {
        case .registered: "Registered"
        case .queued: "Queued"
        case .running: "Running"
        case .processCompleted: "Awaiting validation"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        case .unknown: "State unknown"
        }
    }

    static func healthLabel(_ health: TaskExternalOperationObservationHealth) -> String {
        switch health {
        case .unknown: "Not checked"
        case .healthy: "Reachable"
        case .unreachable: "Unreachable"
        case .malformed: "Invalid observation"
        case .quarantined: "Quarantined"
        }
    }

    static func resultMessage(_ result: TaskExternalOperationPollResult) -> String {
        switch result {
        case .applied: "Updated"
        case .coalesced: "Update already in progress"
        case .leased: "Another monitor owns this check"
        case .missing: "Operation is no longer available"
        case .notMonitoring: "Operation is not eligible for that action"
        case .quarantined: "Reactivation is required first"
        case .ownershipRejected: "Trusted backend ownership could not be verified"
        case .staleIgnored: "A newer operation state was preserved"
        }
    }
}
