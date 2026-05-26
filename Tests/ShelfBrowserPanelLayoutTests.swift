import Testing
@testable import ASTRA

@Suite("Shelf Browser Panel Layout")
struct ShelfBrowserPanelLayoutTests {
    @Test("browser toolbar switches layouts before controls get smushed")
    func browserToolbarSwitchesLayoutsBeforeControlsGetSmushed() {
        #expect(ShelfBrowserToolbarLayout.resolve(width: 640) == .regular)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.regularMinimumWidth) == .regular)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.regularMinimumWidth - 1) == .compact)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.compactMinimumWidth) == .compact)
        #expect(ShelfBrowserToolbarLayout.resolve(width: ShelfBrowserToolbarLayout.compactMinimumWidth - 1) == .stacked)
    }

    @Test("stacked browser toolbar has enough height for two rows")
    func stackedBrowserToolbarHasEnoughHeightForTwoRows() {
        #expect(ShelfBrowserToolbarLayout.stacked.height > ShelfBrowserToolbarLayout.regular.height)
        #expect(ShelfBrowserToolbarLayout.compact.height == ShelfBrowserToolbarLayout.regular.height)
    }
}
