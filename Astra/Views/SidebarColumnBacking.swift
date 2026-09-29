import AppKit

/// Paints the sidebar column's AppKit layer with `Stanford.sidebarBackground`.
///
/// `NavigationSplitView` hosts the SwiftUI sidebar inside a full-height
/// `NSVisualEffectView` (the source-list material) that reaches under the
/// titlebar, but the SwiftUI content is laid out below it. So `SidebarSurface`'s
/// fill covers the column body and the top titlebar band keeps the raw system
/// material, which blends with whatever is behind the window: the strip above the
/// sidebar rendered blue-grey next to a neutral sidebar. This inserts a solid
/// view between the material and the SwiftUI host so the whole column, titlebar
/// band included, is the fixed token.
///
/// `SidebarSplitViewGuard` reapplies this on every layout pass because AppKit can
/// rebuild the column during show/hide transitions. If a future macOS changes the
/// private structure, nothing matches and the material simply shows again.
enum SidebarColumnBacking {
    static let identifier = NSUserInterfaceItemIdentifier("astra.sidebarColumnBacking")

    /// Returns true when a backing view was newly installed.
    @discardableResult
    static func install(in sidebarSubview: NSView) -> Bool {
        guard let material = sidebarSubview.subviews.first(where: { $0 is NSVisualEffectView }),
              !material.subviews.contains(where: { $0.identifier == identifier })
        else { return false }

        let backing = SidebarColumnBackingView(frame: material.bounds)
        backing.identifier = identifier
        backing.autoresizingMask = [.width, .height]
        material.addSubview(backing, positioned: .below, relativeTo: material.subviews.first)
        return true
    }
}

/// A solid, event-transparent layer that follows the window's appearance.
final class SidebarColumnBackingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Stanford.sidebarNSColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Never the target of a click: the SwiftUI sidebar above owns every event.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
