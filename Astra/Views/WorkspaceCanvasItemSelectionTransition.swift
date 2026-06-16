import Foundation

enum WorkspaceCanvasItemSelectionTransition {
    static func itemAfterTaskSelectionChange(
        currentItem: WorkspaceCanvasItem?,
        previousTaskID: UUID?,
        nextTaskID: UUID?,
        isComposingTask: Bool
    ) -> WorkspaceCanvasItem? {
        guard previousTaskID != nextTaskID else { return currentItem }
        guard currentItem == .browser else { return nil }
        guard nextTaskID != nil || isComposingTask else { return nil }

        return .browser
    }
}
