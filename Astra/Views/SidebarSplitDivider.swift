import AppKit

/// Swaps the sidebar split's system divider for ASTRA's separator hairline.
///
/// On macOS 26 `NavigationSplitView` draws the sidebar/detail divider with a
/// private vibrant divider view (`NSVibrantSplitDividerView`) layered over the
/// split view. In dark mode it renders an opaque black line, ten times stronger
/// than any other line in the app, and it ignores `dividerColor`. This fades
/// those divider views to zero opacity; `SidebarSurface` draws the
/// `Stanford.separator` hairline in their place, so the sidebar edge matches
/// every other region edge.
///
/// Fading (not hiding) keeps the views hit-testable, so dragging the divider
/// still resizes the sidebar. AppKit can rebuild divider views during column
/// transitions, so `SidebarSplitViewGuard` reapplies this on every layout
/// pass. If a future macOS renames the private class, nothing matches and the
/// system divider simply shows again.
enum SidebarSplitDivider {
    /// Returns how many divider views were newly faded.
    @discardableResult
    static func fadeSystemDividers(in splitView: NSSplitView) -> Int {
        var faded = 0
        for view in splitView.subviews
        where !splitView.arrangedSubviews.contains(view)
            && NSStringFromClass(type(of: view)).contains("SplitDivider")
            && view.alphaValue != 0 {
            view.alphaValue = 0
            faded += 1
        }
        return faded
    }
}
