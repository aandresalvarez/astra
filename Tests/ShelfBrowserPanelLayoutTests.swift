import Testing
import Foundation
@testable import ASTRA

@Suite("Shelf Browser Panel Layout")
struct ShelfBrowserPanelLayoutTests {
    // The toolbar's row-vs-stacked choice is now made by ViewThatFits, which
    // is a SwiftUI layout primitive rather than a value our own code
    // computes — there's nothing left to unit test there. What we do own is
    // how a raw URL becomes the address bar's at-rest display text, so that's
    // what's covered below.
    @Test("address formatter shows a host for web pages")
    func addressFormatterShowsHostForWebPages() {
        #expect(ShelfBrowserAddressFormatter.displayText(for: "https://www.github.com/anthropics") == "github.com/anthropics")
        #expect(ShelfBrowserAddressFormatter.displayText(for: "https://example.com") == "example.com")
        #expect(ShelfBrowserAddressFormatter.displayText(for: "https://example.com/") == "example.com")
    }

    @Test("address formatter shows a filename for local files")
    func addressFormatterShowsFilenameForLocalFiles() {
        let url = "file:///Users/alvaro/Documents/Astra%20Dev/Workspaces/test/.astra/tasks/D4E9A905/report.html"
        #expect(ShelfBrowserAddressFormatter.displayText(for: url) == "report.html")
    }

    @Test("address formatter treats empty and blank as no address")
    func addressFormatterTreatsEmptyAndBlankAsNoAddress() {
        #expect(ShelfBrowserAddressFormatter.displayText(for: "") == "")
        #expect(ShelfBrowserAddressFormatter.displayText(for: "about:blank") == "")
        #expect(ShelfBrowserAddressFormatter.displayText(for: "  ") == "")
    }

    @MainActor
    @Test("browser session reuse preserves explicit adapter enablement")
    func browserSessionReusePreservesExplicitAdapterEnablement() {
        ShelfBrowserBridgeRegistry.shared.reset()
        let store = ShelfBrowserSessionStore()
        let taskID = UUID()

        let first = store.session(
            for: taskID,
            pinnedToTask: true,
            enabledBrowserAdapters: [BrowserSiteAdapterID.github]
        )
        #expect(ShelfBrowserBridgeRegistry.shared.promptState(for: taskID).enabledBrowserAdapters == [
            BrowserSiteAdapterID.github
        ])

        let reused = store.session(
            for: taskID,
            pinnedToTask: true,
            enabledBrowserAdapters: [BrowserSiteAdapterID.github]
        )
        #expect(first === reused)
        #expect(ShelfBrowserBridgeRegistry.shared.promptState(for: taskID).enabledBrowserAdapters == [
            BrowserSiteAdapterID.github
        ])
    }
}
