import Foundation

/// The `statusColor` half of `Astra/Services/Tasks/TaskPresentationState.swift`,
/// extracted as part of Track A2.1 (finishing A2's Models cycle-break) so
/// `Astra/Models/AgentTask.swift` can depend on it without pulling in the rest
/// of that file (`reviewPresentation`/`verificationPresentation`, which depend
/// on Persistence's `TaskContextState` and Validation's
/// `TaskDeliverableCheckStatus`).
///
/// Takes the raw string value of `TaskStatus` rather than the enum itself —
/// `TaskStatus` is defined in Models, and `ASTRACore` can never import Models
/// (that would recreate the cycle Track A2 broke).
public enum TaskStatusPresentation {
    /// `statusRawValue` must be one of `TaskStatus`'s raw values ("draft",
    /// "queued", "running", "pending_user", "completed", "failed",
    /// "cancelled", "budget_exceeded"). Every real `TaskStatus` case is
    /// covered explicitly; the "gray" fallback for an unrecognized string
    /// should be unreachable in practice (mirrors `.queued`/`.cancelled`'s
    /// color rather than inventing a new one).
    public static func color(for statusRawValue: String) -> String {
        switch statusRawValue {
        case "draft": return "purple"
        case "queued": return "gray"
        case "running": return "blue"
        case "pending_user": return "orange"
        case "completed": return "green"
        case "failed": return "red"
        case "cancelled": return "gray"
        case "budget_exceeded": return "red"
        default: return "gray"
        }
    }
}
