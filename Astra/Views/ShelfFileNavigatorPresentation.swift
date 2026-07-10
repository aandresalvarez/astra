import CoreGraphics

/// Resolves the Files shelf browser without coupling its interaction policy to
/// SwiftUI view state. Reading remains the default surface; browsing floats
/// above it unless the user explicitly pins the navigator and there is enough
/// room to keep both panes readable.
enum ShelfFileNavigatorLayout: Equatable {
    case hidden
    case floating
    case docked

    static func resolve(
        isPresented: Bool,
        isPinned: Bool,
        availableWidth: CGFloat,
        navigatorWidth: CGFloat = ShelfWidthMetrics.filesNavigatorDefaultWidth
    ) -> ShelfFileNavigatorLayout {
        guard isPresented else { return .hidden }
        let minimumDockedWidth = navigatorWidth
            + ShelfWidthMetrics.filesResizeHandleWidth
            + ShelfWidthMetrics.filesMinimumPreviewWidth
        guard isPinned, availableWidth >= minimumDockedWidth else { return .floating }
        return .docked
    }
}

enum ShelfFileNavigatorSelectionPolicy {
    /// Temporary browsing ends after a selection. A pinned navigator stays open
    /// because the user has explicitly chosen sustained file work.
    static func isPresentedAfterSelectingFile(isPinned: Bool) -> Bool {
        isPinned
    }
}

enum ShelfFileNavigatorInitialPresentationPolicy {
    /// Reveal browsing once for discovery, whenever there is no current file,
    /// or whenever the user has explicitly pinned the browser.
    static func shouldPresent(
        isPinned: Bool,
        hasSelectedFile: Bool,
        hasDiscoveredBrowser: Bool
    ) -> Bool {
        isPinned || !hasSelectedFile || !hasDiscoveredBrowser
    }
}
