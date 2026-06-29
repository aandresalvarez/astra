import Foundation

enum WorkspaceShelfRuntimePolicy {
    static func canPresentBrowserShelf(for workspace: Workspace?) -> Bool {
        let policy = AstraPackWorkspaceProfileProvider.shelfAvailabilityPolicy(for: workspace)
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
