import Foundation

enum TaskPresentationState {
    static func statusColor(for status: TaskStatus) -> String {
        switch status {
        case .draft: return "purple"
        case .queued: return "gray"
        case .running: return "blue"
        case .pendingUser: return "orange"
        case .completed: return "green"
        case .failed: return "red"
        case .cancelled: return "gray"
        case .budgetExceeded: return "red"
        }
    }
}
