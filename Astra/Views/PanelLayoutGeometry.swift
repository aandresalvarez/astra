import CoreGraphics

/// Pure-math helpers for the ContentDetailAreaView panel layout.
///
/// Extracted so the layout rules (compact thresholds, shelf clamping,
/// inspector/shelf coexistence) can be regression-tested without standing
/// up a SwiftUI view hierarchy.
enum PanelLayoutGeometry {
    /// Window width at which the sidebar auto-hides when a right-side panel is open.
    static let compactPanelMutualExclusionWidth: CGFloat = 1_280

    /// Width of the inspector (Task Context) column when shown.
    static let inspectorColumnWidth: CGFloat = 460

    /// Returns true when the window is narrow enough that having both the sidebar
    /// AND a right-side panel open at once would cramp the detail area.
    static func isCompactPanelLayout(width: CGFloat) -> Bool {
        width > 0 && width < compactPanelMutualExclusionWidth
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
        return detailAreaWidth < shelfMinWidth + minimumDetailWidth + inspectorColumnWidth
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

    /// Computes the detail area width left over after the shelf takes its clamped
    /// width. Returns 0 (not negative) when geometry collapses.
    static func detailWidthAfterShelf(
        availableWidth: CGFloat,
        clampedShelfWidth: CGFloat
    ) -> CGFloat {
        max(0, availableWidth - clampedShelfWidth)
    }
}
