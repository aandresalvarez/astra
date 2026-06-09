import CoreGraphics
import Testing
@testable import ASTRA

@Suite("WindowChromeConfigurator")
struct WindowChromeConfiguratorTests {

    @Test("Hover-only sidebar updates do not replace the hosted command bar")
    func hoverOnlySidebarUpdatesDoNotRefreshHostedCommands() {
        let current = WindowChromeCommandBarState(
            isSearchActive: false,
            isSidebarHidden: true,
            titleBarHeight: 36
        )
        let hoverOnlyUpdate = WindowChromeCommandBarState(
            isSearchActive: false,
            isSidebarHidden: true,
            titleBarHeight: 36
        )

        #expect(!WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: current,
            next: hoverOnlyUpdate
        ))
    }

    @Test("Visible command state changes still refresh the hosted command bar")
    func visibleCommandStateChangesRefreshHostedCommands() {
        let current = WindowChromeCommandBarState(
            isSearchActive: false,
            isSidebarHidden: true,
            titleBarHeight: 36
        )

        #expect(WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: current,
            next: WindowChromeCommandBarState(
                isSearchActive: true,
                isSidebarHidden: true,
                titleBarHeight: 36
            )
        ))
        #expect(WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: current,
            next: WindowChromeCommandBarState(
                isSearchActive: false,
                isSidebarHidden: false,
                titleBarHeight: 36
            )
        ))
        #expect(WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: current,
            next: WindowChromeCommandBarState(
                isSearchActive: false,
                isSidebarHidden: true,
                titleBarHeight: 42
            )
        ))
    }

    @Test("Leading command bar reserves the first titlebar accessory slot")
    func leadingCommandBarReservesFirstAccessorySlot() {
        #expect(
            AstraLeadingCommandBarMetrics.reservedAccessorySlotWidth
                >= AstraToolbarCommandMetrics.iconWidth
        )
    }
}
