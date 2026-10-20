import CoreGraphics

/// Resolves the Files shelf browser without coupling its interaction policy to
/// SwiftUI view state. Reading remains the default surface; browsing floats
/// above it unless the user explicitly pins the navigator and there is enough
/// room to keep both panes readable. With nothing to preview, browsing owns
/// the pane instead of covering part of an empty-state message.
enum ShelfFileNavigatorLayout: Equatable {
    case hidden
    case navigatorOnly
    case floating
    case docked

    static func resolve(
        isPresented: Bool,
        isPinned: Bool,
        availableWidth: CGFloat,
        navigatorWidth: CGFloat = ShelfWidthMetrics.filesNavigatorDefaultWidth,
        hasPreviewContent: Bool = true
    ) -> ShelfFileNavigatorLayout {
        guard isPresented else { return .hidden }
        guard hasPreviewContent else { return .navigatorOnly }
        let minimumDockedWidth = navigatorWidth
            + ShelfWidthMetrics.filesResizeHandleWidth
            + ShelfWidthMetrics.filesMinimumPreviewWidth
        guard isPinned, availableWidth >= minimumDockedWidth else { return .floating }
        return .docked
    }
}

enum ShelfFileNavigatorResizePolicy {
    static func showsResizeHandle(layout: ShelfFileNavigatorLayout, isPinned: Bool) -> Bool {
        isPinned && (layout == .floating || layout == .docked)
    }

    static func displayedWidth(
        layout: ShelfFileNavigatorLayout,
        navigatorWidth: CGFloat,
        availableWidth: CGFloat,
        reservesResizeHandle: Bool
    ) -> CGFloat {
        guard layout == .floating else { return navigatorWidth }
        let reservedWidth = reservesResizeHandle ? ShelfWidthMetrics.filesResizeHandleWidth : 0
        return max(0, min(navigatorWidth, availableWidth - reservedWidth))
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

enum ShelfFileNavigatorContentPresentation: Equatable {
    case noWorkspacePaths
    case scanning
    case emptyScope
    case populatedList

    static func resolve(
        hasConfiguredRoots: Bool,
        hasVisibleFileRoots: Bool,
        isSearchingFiles: Bool,
        isScanningFiles: Bool
    ) -> ShelfFileNavigatorContentPresentation {
        if !hasConfiguredRoots {
            return .noWorkspacePaths
        }
        if isScanningFiles && !hasVisibleFileRoots {
            return .scanning
        }
        if !hasVisibleFileRoots && !isSearchingFiles {
            return .emptyScope
        }
        return .populatedList
    }

    var usesListSurface: Bool {
        switch self {
        case .noWorkspacePaths, .scanning, .emptyScope, .populatedList:
            true
        }
    }
}
