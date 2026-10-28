import Foundation

/// Derived presentation state. A late SSH reply cannot replace a newer selection.
struct RemoteWorkspaceJobOutputState {
    struct Selection {
        let requestID: UUID
        let taskID: UUID
        let jobID: String
        let label: String
        var text: String?
    }

    private var selection: Selection?

    mutating func begin(taskID: UUID, jobID: String, label: String) -> UUID {
        let requestID = UUID()
        selection = Selection(requestID: requestID, taskID: taskID, jobID: jobID, label: label)
        return requestID
    }

    mutating func complete(requestID: UUID, text: String) {
        guard selection?.requestID == requestID else { return }
        selection?.text = text
    }

    func visible(for taskID: UUID) -> Selection? {
        selection?.taskID == taskID ? selection : nil
    }
}
