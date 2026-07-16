import CoreGraphics

/// How the sidebar is presented for a given window width and intent.
///
/// One value, derived purely from (intent, width, right-panel presence) by
/// `PanelLayoutGeometry.sidebarMode`. `SidebarPresentationModel` owns the live
/// instance; nothing else decides sidebar visibility. Keeping the decision here
/// (and pure) makes it unit-testable without a view hierarchy.
enum SidebarMode: Equatable {
    /// Resizable column docked inside the `NavigationSplitView`.
    case docked
    /// Floating drawer over the detail area — the window is too narrow to dock
    /// the column alongside the right panel without cramping the detail.
    case overlay
    /// Hidden entirely (the user has not asked for it).
    case collapsed

    /// True when the sidebar occupies its own layout column (vs. floating/hidden).
    var occupiesColumn: Bool { self == .docked }
}

/// Pure-math helpers for the ContentDetailAreaView panel layout.
///
/// Extracted so the layout rules (compact thresholds, shelf clamping,
/// inspector/shelf coexistence) can be regression-tested without standing
/// up a SwiftUI view hierarchy.
enum PanelLayoutGeometry {
    /// Window width at which the sidebar auto-hides when a right-side panel is open.
    static let compactPanelMutualExclusionWidth: CGFloat = 1_280

    /// Minimum readable width for the main detail area. Mirrors
    /// `ContentDetailAreaView.contentMinWidth`; kept here so the pure dock/overlay
    /// decision can reason about the full three-column budget without a view.
    static let detailMinWidth: CGFloat = 480

    /// Window width below which a docked sidebar + right panel + readable detail
    /// can't coexist, so the sidebar must present as an overlay drawer instead.
    /// With a right panel this is the readability-margin threshold; without one
    /// the sidebar only needs room for itself plus the detail minimum.
    static func canDockSidebar(width: CGFloat, hasRightSidePanel: Bool) -> Bool {
        // Unmeasured width: dock optimistically; the first real measurement
        // re-resolves before anything is shown.
        guard width > 0 else { return true }
        if hasRightSidePanel {
            return width >= compactPanelMutualExclusionWidth
        }
        return width >= SidebarColumnLayout.expandedMinimumWidth + detailMinWidth
    }

    /// The single, pure sidebar-presentation decision. `SidebarPresentationModel`
    /// is the only caller that turns this into live view state.
    ///
    /// - `wantsDock`: the durable intent — drives the docked column whenever the
    ///   window is wide enough to dock.
    /// - `overlayOpen`: a transient request to float the sidebar over a window too
    ///   narrow to dock. Ignored when the window can dock (the dock intent wins),
    ///   so a stale overlay flag can never override a real column.
    static func sidebarMode(
        width: CGFloat,
        hasRightSidePanel: Bool,
        wantsDock: Bool,
        overlayOpen: Bool
    ) -> SidebarMode {
        if canDockSidebar(width: width, hasRightSidePanel: hasRightSidePanel) {
            return wantsDock ? .docked : .collapsed
        }
        return overlayOpen ? .overlay : .collapsed
    }

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
    static let filesShelfNavigatorDefaultWidth: CGFloat = ShelfWidthMetrics.filesNavigatorDefaultWidth
    static let filesShelfResizeHandleWidth: CGFloat = ShelfWidthMetrics.filesResizeHandleWidth
    static let filesShelfMinimumPreviewWidth: CGFloat = ShelfWidthMetrics.filesMinimumPreviewWidth
    static let filesShelfMinReadableWidth: CGFloat = ShelfWidthMetrics.filesMinReadableWidth
    static let browserShelfMinWidth: CGFloat = ShelfWidthMetrics.browserMinWidth

    /// Returns true when the window is narrow enough that having both the sidebar
    /// AND a right-side panel open at once would cramp the detail area.
    static func isCompactPanelLayout(width: CGFloat) -> Bool {
        width > 0 && width < compactPanelMutualExclusionWidth
    }

    static func shouldAutoHideSidebarForCompactPanels(
        width: CGFloat,
        hasRightSidePanelPresented: Bool,
        isSidebarDetailOnly: Bool,
        isSidebarRevealInProgress: Bool
    ) -> Bool {
        guard !isSidebarRevealInProgress else { return false }
        guard isCompactPanelLayout(width: width) else { return false }
        guard hasRightSidePanelPresented else { return false }
        return !isSidebarDetailOnly
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
        let finiteCandidate = candidate.isFinite ? candidate : inspectorMinColumnWidth
        guard detailAreaWidth > 0 else {
            return min(max(finiteCandidate, inspectorMinColumnWidth), inspectorMaxColumnWidth)
        }
        let maximumUsableWidth = max(inspectorMinColumnWidth, detailAreaWidth - minimumDetailWidth)
        let maximumWidth = min(inspectorMaxColumnWidth, maximumUsableWidth)
        return min(max(finiteCandidate, inspectorMinColumnWidth), maximumWidth)
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
        let finiteCandidate = candidate.isFinite ? candidate : shelfMinWidth
        let maximumUsableWidth = max(shelfMinWidth, availableWidth - minimumDetailWidth)
        let maximumWidth = min(shelfMaxWidth, maximumUsableWidth)
        return min(max(finiteCandidate, shelfMinWidth), maximumWidth)
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
        guard shelfWidth.isFinite, navigatorWidth.isFinite else { return 0 }
        return max(0, shelfWidth - navigatorWidth - filesShelfResizeHandleWidth)
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
