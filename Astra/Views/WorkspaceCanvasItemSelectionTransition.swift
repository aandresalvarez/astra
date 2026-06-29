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

enum WorkspacePlanCanvasPresentationTransition {
    static func cachedHasPlanContentAfterTargetValidation(
        previousTaskID: UUID?,
        targetTaskID: UUID,
        currentCachedHasPlanContent: Bool,
        targetHasPlanContent: Bool
    ) -> Bool {
        previousTaskID == targetTaskID ? currentCachedHasPlanContent : targetHasPlanContent
    }
}

enum WorkspaceCanvasPolicyTransition {
    static func itemAfterAppStudioStart(
        policy: ShelfAvailabilityPolicy,
        context: ShelfAvailabilityPolicy.Context
    ) -> WorkspaceCanvasItem? {
        policy.canPresent(.appPreview, in: context) ? .appPreview : nil
    }

    static func itemAfterPolicyChange(
        currentItem: WorkspaceCanvasItem?,
        policy: ShelfAvailabilityPolicy,
        context: ShelfAvailabilityPolicy.Context
    ) -> WorkspaceCanvasItem? {
        guard let currentItem else { return nil }
        return policy.canPresent(currentItem.shelfID, in: context) ? currentItem : nil
    }
}
