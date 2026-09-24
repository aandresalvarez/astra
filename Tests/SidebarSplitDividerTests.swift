import AppKit
import Testing
@testable import ASTRA

/// Stands in for AppKit's private `NSVibrantSplitDividerView`.
private final class FakeSplitDividerView: NSView {}

@MainActor
@Suite("Sidebar split divider")
struct SidebarSplitDividerTests {
    @Test("Only non-arranged divider views are faded, once, and stay hit-testable")
    func fadesOnlySystemDividerViews() {
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        splitView.isVertical = true
        splitView.arrangesAllSubviews = false
        let sidebar = NSView()
        let detail = NSView()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        let divider = FakeSplitDividerView()
        splitView.addSubview(divider)

        #expect(SidebarSplitDivider.fadeSystemDividers(in: splitView) == 1)
        #expect(divider.alphaValue == 0)
        #expect(!divider.isHidden)
        #expect(sidebar.alphaValue == 1 && detail.alphaValue == 1)
        #expect(SidebarSplitDivider.fadeSystemDividers(in: splitView) == 0)
    }
}
