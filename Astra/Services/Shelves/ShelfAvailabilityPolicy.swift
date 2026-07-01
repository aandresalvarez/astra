import Foundation

struct ShelfAvailabilityPolicy: Equatable {
    struct Context: Equatable {
        var hasOpenTaskThread: Bool
        var hasWorkspaceContext: Bool
        var hasPlanContent: Bool
        var hasFilesShelfContent: Bool
        var hasQueryShelfContent: Bool
        var isComposingWorkspaceApp: Bool
        var activeShelfID: ShelfID?
    }

    private let registeredShelfIDs: Set<ShelfID>
    private let disabledShelfIDs: Set<ShelfID>

    init(
        descriptors: [ShelfDescriptor] = CoreShelfRegistry.allDescriptors,
        disabledShelfIDs: Set<ShelfID> = []
    ) {
        self.registeredShelfIDs = Set(descriptors.map(\.id))
        self.disabledShelfIDs = disabledShelfIDs
    }

    static func loadingForPackEnabledWorkspace(
        descriptors: [ShelfDescriptor] = CoreShelfRegistry.allDescriptors
    ) -> ShelfAvailabilityPolicy {
        ShelfAvailabilityPolicy(descriptors: descriptors)
    }

    func isToolbarAvailable(_ shelfID: ShelfID, in context: Context) -> Bool {
        guard isRegisteredAndEnabled(shelfID) else { return false }

        switch shelfID {
        case .plan:
            return context.hasOpenTaskThread && context.hasPlanContent
        case .files:
            return context.hasWorkspaceContext || context.activeShelfID == .files
        case .browser:
            return context.hasOpenTaskThread
        case .query:
            return context.hasOpenTaskThread && hasQueryAffordance(in: context)
        case .appPreview:
            return context.isComposingWorkspaceApp
        }
    }

    func canPresent(_ shelfID: ShelfID, in context: Context) -> Bool {
        guard isRegisteredAndEnabled(shelfID) else { return false }

        switch shelfID {
        case .plan:
            return context.hasOpenTaskThread && context.hasPlanContent
        case .files:
            return context.hasWorkspaceContext
                || context.hasOpenTaskThread
                || context.hasFilesShelfContent
        case .browser:
            return context.hasOpenTaskThread
        case .query:
            return context.hasOpenTaskThread && hasQueryAffordance(in: context)
        case .appPreview:
            return context.isComposingWorkspaceApp
        }
    }

    func canRestoreRemembered(_ shelfID: ShelfID, in context: Context) -> Bool {
        canPresent(shelfID, in: context)
    }

    private func isRegisteredAndEnabled(_ shelfID: ShelfID) -> Bool {
        registeredShelfIDs.contains(shelfID) && !disabledShelfIDs.contains(shelfID)
    }

    private func hasQueryAffordance(in context: Context) -> Bool {
        context.activeShelfID == .query || context.hasQueryShelfContent
    }
}
