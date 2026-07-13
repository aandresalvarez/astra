import CoreGraphics
import SwiftUI
import Testing
@testable import ASTRA

@Suite("WindowChromeConfigurator")
struct WindowChromeConfiguratorTests {

    @Test("Hover-only sidebar updates do not replace the hosted command bar")
    func hoverOnlySidebarUpdatesDoNotRefreshHostedCommands() {
        let current = WindowChromeCommandBarState(
            isSearchActive: false,
            isSidebarHidden: true,
            sidebarWidth: 320,
            titleBarHeight: 36
        )
        let hoverOnlyUpdate = WindowChromeCommandBarState(
            isSearchActive: false,
            isSidebarHidden: true,
            sidebarWidth: 320,
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
            sidebarWidth: 320,
            titleBarHeight: 36
        )

        #expect(WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: current,
            next: WindowChromeCommandBarState(
                isSearchActive: true,
                isSidebarHidden: true,
                sidebarWidth: 320,
                titleBarHeight: 36
            )
        ))
        #expect(WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: current,
            next: WindowChromeCommandBarState(
                isSearchActive: false,
                isSidebarHidden: false,
                sidebarWidth: 320,
                titleBarHeight: 36
            )
        ))
        #expect(WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: current,
            next: WindowChromeCommandBarState(
                isSearchActive: false,
                isSidebarHidden: true,
                sidebarWidth: 320,
                titleBarHeight: 42
            )
        ))
    }

    @Test("A measured command-bar width change refreshes the hosted view")
    func measuredCommandBarWidthChangesRefreshHostedView() {
        let state = WindowChromeCommandBarState(
            isSearchActive: false,
            isSidebarHidden: false,
            sidebarWidth: 320,
            titleBarHeight: 36
        )

        #expect(WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: state,
            next: state,
            previousCommandBarWidth: nil,
            nextCommandBarWidth: 222
        ))
        #expect(!WindowChromeCommandBarRefreshPolicy.shouldRefresh(
            previous: state,
            next: state,
            previousCommandBarWidth: 222,
            nextCommandBarWidth: 222.2
        ))
    }

    @Test("Leading command bar sits flush after the traffic lights")
    func leadingCommandBarSitsFlushAfterTrafficLights() {
        #expect(AstraLeadingCommandBarMetrics.leadingPadding == 0)
    }

    // With no reserved spacer, click reliability for the leading-most button
    // depends on the accessory never converting clicks into window drags.
    @Test("Accessory hosting view keeps clicks out of titlebar window-drag")
    @MainActor
    func accessoryHostingViewKeepsClicksOutOfWindowDrag() {
        let host = FullScreenSafeHostingView(rootView: EmptyView())
        #expect(!host.mouseDownCanMoveWindow)
    }
}
