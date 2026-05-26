import CoreGraphics

/// Pure-math helpers for the ContentDetailAreaView panel layout.
///
/// Extracted so the layout rules (compact thresholds, shelf clamping,
/// inspector/shelf coexistence) can be regression-tested without standing
/// up a SwiftUI view hierarchy.
enum PanelLayoutGeometry {
    /// Window width at which the sidebar auto-hides when a right-side panel is open.
    static let compactPanelMutualExclusionWidth: CGFloat = 1_280

    /// Minimum docked width that still keeps the workspace inspector readable.
    static let inspectorMinColumnWidth: CGFloat = 340

    /// Preferred width of the inspector (Task Context) column on normal windows.
    static let inspectorColumnWidth: CGFloat = 392

    /// Maximum width used by the automatic docked inspector size.
    static let inspectorDefaultMaxColumnWidth: CGFloat = 420

    /// Maximum width a user can drag the docked inspector to.
    static let inspectorMaxColumnWidth: CGFloat = 460

    /// Margin kept around the slide-over inspector on narrow detail areas.
    static let inspectorOverlayHorizontalMargin: CGFloat = 12

    /// Default split inside the Files shelf. The shelf's outer minimum must
    /// keep this navigator and the preview pane readable together.
    static let filesShelfNavigatorDefaultWidth: CGFloat = 282
    static let filesShelfResizeHandleWidth: CGFloat = 8
    static let filesShelfMinimumPreviewWidth: CGFloat = 260
    static let filesShelfMinReadableWidth: CGFloat =
        filesShelfNavigatorDefaultWidth + filesShelfResizeHandleWidth + filesShelfMinimumPreviewWidth

    /// Returns true when the window is narrow enough that having both the sidebar
    /// AND a right-side panel open at once would cramp the detail area.
    static func isCompactPanelLayout(width: CGFloat) -> Bool {
        width > 0 && width < compactPanelMutualExclusionWidth
    }

    /// Uses a viewport-relative target with hard readability clamps:
    /// roughly `clamp(340, 24vw, 420)` in SwiftUI layout terms.
    static func inspectorDockedColumnWidth(for detailAreaWidth: CGFloat) -> CGFloat {
        guard detailAreaWidth > 0 else { return inspectorColumnWidth }
        return min(
            inspectorDefaultMaxColumnWidth,
            max(inspectorMinColumnWidth, detailAreaWidth * 0.24)
        )
    }

    static func inspectorResizableColumnWidth(
        _ candidate: CGFloat,
        detailAreaWidth: CGFloat,
        minimumDetailWidth: CGFloat
    ) -> CGFloat {
        guard detailAreaWidth > 0 else {
            return min(max(candidate, inspectorMinColumnWidth), inspectorMaxColumnWidth)
        }
        let maximumUsableWidth = max(inspectorMinColumnWidth, detailAreaWidth - minimumDetailWidth)
        let maximumWidth = min(inspectorMaxColumnWidth, maximumUsableWidth)
        return min(max(candidate, inspectorMinColumnWidth), maximumWidth)
    }

    /// Narrow detail areas should keep the main content full-width and present
    /// the inspector as a drawer instead of compressing both surfaces.
    static func shouldOverlayInspector(
        detailAreaWidth: CGFloat,
        minimumDetailWidth: CGFloat
    ) -> Bool {
        guard detailAreaWidth > 0 else { return false }
        return detailAreaWidth < minimumDetailWidth + inspectorMinColumnWidth
    }

    static func inspectorOverlayWidth(for detailAreaWidth: CGFloat) -> CGFloat {
        guard detailAreaWidth > 0 else { return inspectorMinColumnWidth }
        let readableWidth = min(
            inspectorDefaultMaxColumnWidth,
            max(inspectorMinColumnWidth, detailAreaWidth * 0.92)
        )
        let viewportCap = max(280, detailAreaWidth - inspectorOverlayHorizontalMargin * 2)
        return min(readableWidth, viewportCap)
    }

    /// Returns true when the right-side area (detail + shelf + inspector) cannot
    /// fit all three at their minimum widths without driving the detail area to
    /// (or below) zero. Used to force shelf/inspector mutual exclusion.
    ///
    /// `detailAreaWidth` is the width available to the detail+shelf+inspector
    /// stack — i.e., window width minus the sidebar's contribution.
    static func cannotFitShelfAndInspector(
        detailAreaWidth: CGFloat,
        shelfMinWidth: CGFloat,
        minimumDetailWidth: CGFloat
    ) -> Bool {
        guard detailAreaWidth > 0 else { return true }
        return detailAreaWidth < shelfMinWidth + minimumDetailWidth + inspectorMinColumnWidth
    }

    /// Clamps a shelf width so that the detail area to its left keeps at least
    /// `minimumDetailWidth` points. Mirrors the logic that ContentView previously
    /// inlined; kept identical so layout behavior is unchanged.
    static func clampedShelfWidth(
        _ candidate: CGFloat,
        shelfMinWidth: CGFloat,
        shelfMaxWidth: CGFloat,
        minimumDetailWidth: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let maximumUsableWidth = max(shelfMinWidth, availableWidth - minimumDetailWidth)
        let maximumWidth = min(shelfMaxWidth, maximumUsableWidth)
        return min(max(candidate, shelfMinWidth), maximumWidth)
    }

    static func shouldDismissShelfResize(
        proposedWidth: CGFloat,
        shelfMinWidth: CGFloat
    ) -> Bool {
        guard proposedWidth.isFinite, shelfMinWidth > 0 else { return false }
        return proposedWidth < shelfMinWidth
    }

    static func filesShelfPreviewWidth(
        shelfWidth: CGFloat,
        navigatorWidth: CGFloat = filesShelfNavigatorDefaultWidth
    ) -> CGFloat {
        max(0, shelfWidth - navigatorWidth - filesShelfResizeHandleWidth)
    }

    /// Computes the detail area width left over after the shelf takes its clamped
    /// width. Returns 0 (not negative) when geometry collapses.
    static func detailWidthAfterShelf(
        availableWidth: CGFloat,
        clampedShelfWidth: CGFloat
    ) -> CGFloat {
        max(0, availableWidth - clampedShelfWidth)
    }
}
