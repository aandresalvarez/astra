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

    @Test("address formatter keeps the port so distinct local endpoints don't collide")
    func addressFormatterKeepsPort() {
        #expect(ShelfBrowserAddressFormatter.displayText(for: "http://localhost:3000") == "localhost:3000")
        #expect(ShelfBrowserAddressFormatter.displayText(for: "http://localhost:8080/health") == "localhost:8080/health")
        #expect(ShelfBrowserAddressFormatter.displayText(for: "http://localhost:3000") != ShelfBrowserAddressFormatter.displayText(for: "http://localhost:8080"))
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

    // Each test below replays a concrete review finding against the pure
    // edit-lifecycle model, simulating the exact event order the view
    // forwards (including Go clicks that blur the field before the button
    // action runs).

    @Test("Go at rest reloads the real URL, not the display text")
    func goAtRestReloadsRealURL() {
        let model = ShelfBrowserAddressEditModel()
        let url = "file:///Users/a/.astra/tasks/X/report.html"
        let text = ShelfBrowserAddressFormatter.displayText(for: url)
        #expect(model.submissionTarget(text: text, currentURL: url, isFocused: false, hasDisplayablePage: true) == url)
    }

    @Test("edit submitted via Go survives the blur that precedes the button action")
    func editSurvivesGoBlur() {
        var model = ShelfBrowserAddressEditModel()
        let url = "https://example.com/a"
        var text = ShelfBrowserAddressFormatter.displayText(for: url)
        model.focusGained(text: &text, currentURL: url)
        #expect(text == url)
        text = "github.com/anthropics"
        model.focusLost(text: &text, currentURL: url)
        #expect(text == "github.com/anthropics")
        #expect(model.submissionTarget(text: text, currentURL: url, isFocused: false, hasDisplayablePage: true) == "github.com/anthropics")
    }

    @Test("edit that coincidentally equals the display text still submits as typed")
    func coincidentalDisplayMatchStillSubmits() {
        var model = ShelfBrowserAddressEditModel()
        let url = "https://example.com/search?q=old"
        var text = ShelfBrowserAddressFormatter.displayText(for: url)
        model.focusGained(text: &text, currentURL: url)
        text = "example.com/search"
        model.focusLost(text: &text, currentURL: url)
        #expect(text == "example.com/search")
        #expect(model.submissionTarget(text: text, currentURL: url, isFocused: false, hasDisplayablePage: true) == "example.com/search")
    }

    @Test("pending edit survives an unchanged refocus-blur cycle")
    func pendingEditSurvivesRefocus() {
        var model = ShelfBrowserAddressEditModel()
        let url = "https://example.com/a"
        var text = ShelfBrowserAddressFormatter.displayText(for: url)
        model.focusGained(text: &text, currentURL: url)
        text = "github.com/anthropics"
        model.focusLost(text: &text, currentURL: url)
        model.focusGained(text: &text, currentURL: url)
        #expect(text == "github.com/anthropics")
        model.focusLost(text: &text, currentURL: url)
        #expect(text == "github.com/anthropics")
        #expect(model.submissionTarget(text: text, currentURL: url, isFocused: false, hasDisplayablePage: true) == "github.com/anthropics")
    }

    @Test("untouched focus-blur cycle returns to display text")
    func untouchedFocusBlurReturnsToDisplayText() {
        var model = ShelfBrowserAddressEditModel()
        let url = "https://example.com/a"
        var text = ShelfBrowserAddressFormatter.displayText(for: url)
        model.focusGained(text: &text, currentURL: url)
        model.focusLost(text: &text, currentURL: url)
        #expect(text == ShelfBrowserAddressFormatter.displayText(for: url))
        #expect(!model.hasPendingEdit)
        #expect(model.submissionTarget(text: text, currentURL: url, isFocused: false, hasDisplayablePage: true) == url)
    }

    @Test("manually restoring the raw URL clears a pending edit")
    func restoringRawURLClearsPendingEdit() {
        var model = ShelfBrowserAddressEditModel()
        let url = "https://example.com/a"
        var text = ShelfBrowserAddressFormatter.displayText(for: url)
        model.focusGained(text: &text, currentURL: url)
        text = "github.com/anthropics"
        model.focusLost(text: &text, currentURL: url)
        model.focusGained(text: &text, currentURL: url)
        text = url
        model.focusLost(text: &text, currentURL: url)
        #expect(!model.hasPendingEdit)
        #expect(text == ShelfBrowserAddressFormatter.displayText(for: url))
    }

    @Test("navigation commit clears pending edit and shows the new page")
    func navigationCommitClearsPendingEdit() {
        var model = ShelfBrowserAddressEditModel()
        let oldURL = "https://example.com/a"
        var text = ShelfBrowserAddressFormatter.displayText(for: oldURL)
        model.focusGained(text: &text, currentURL: oldURL)
        text = "github.com/anthropics"
        model.focusLost(text: &text, currentURL: oldURL)
        let newURL = "https://github.com/anthropics"
        model.navigationCommitted(text: &text, currentURL: newURL)
        #expect(!model.hasPendingEdit)
        #expect(text == "github.com/anthropics")
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
