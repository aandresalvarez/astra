import Testing
@testable import ASTRA

@Suite("Shelf Browser Panel Layout")
struct ShelfBrowserPanelLayoutTests {
    @Test("browser toolbar switches layouts before controls get smushed")
    func browserToolbarSwitchesLayoutsBeforeControlsGetSmushed() {
        #expect(ShelfBrowserToolbarLayout.resolve(width: 640) == .regular)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.regularMinimumWidth) == .regular)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.regularMinimumWidth - 1) == .compact)
        #expect(ShelfBrowserToolbarLayout.resolve(width: 420) == .compact)
        #expect(ShelfBrowserToolbarLayout.resolve(width: PanelLayoutGeometry.browserShelfMinWidth) == .compact)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.compactMinimumWidth) == .compact)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.compactMinimumWidth - 1) == .stacked)
    }

    @Test("compact browser toolbar is the browser shelf minimum layout")
    func compactBrowserToolbarIsBrowserShelfMinimumLayout() {
        #expect(ShelfBrowserToolbarLayout.compactMinimumWidth < PanelLayoutGeometry.browserShelfMinWidth)
        #expect(ShelfBrowserToolbarLayout.compactAddressMinimumWidth <= 108)
        #expect(ShelfBrowserToolbarLayout.regularAddressMinimumWidth > ShelfBrowserToolbarLayout.compactAddressMinimumWidth)
    }

    @Test("stacked browser toolbar has enough height for two rows")
    func stackedBrowserToolbarHasEnoughHeightForTwoRows() {
        #expect(ShelfBrowserToolbarLayout.stacked.height > ShelfBrowserToolbarLayout.regular.height)
        #expect(ShelfBrowserToolbarLayout.compact.height == ShelfBrowserToolbarLayout.regular.height)
    }
}
