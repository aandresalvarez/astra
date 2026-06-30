import Foundation

enum WorkspaceShelfRuntimePolicy {
    static func resolvedShelfAvailabilityPolicy(for workspace: Workspace?) -> ShelfAvailabilityPolicy {
        AstraPackWorkspaceProfileProvider.shelfAvailabilityPolicy(for: workspace)
    }

    static func canPresentBrowserShelf(
        for workspace: Workspace?,
        shelfAvailabilityPolicy: ShelfAvailabilityPolicy? = nil
    ) -> Bool {
        let policy = shelfAvailabilityPolicy ?? resolvedShelfAvailabilityPolicy(for: workspace)
        return policy.canPresent(
            .browser,
            in: ShelfAvailabilityPolicy.Context(
                hasOpenTaskThread: true,
                hasWorkspaceContext: workspace != nil,
                hasPlanContent: false,
                hasFilesShelfContent: false,
                hasQueryShelfContent: false,
                isComposingWorkspaceApp: false,
                activeShelfID: .browser
            )
        )
    }
}
