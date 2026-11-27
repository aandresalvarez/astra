import AppKit
import Observation
import SwiftUI
import Testing
@testable import ASTRA
import ASTRAModels

/// The search panel's field must end up holding the window's keyboard when the
/// panel opens over a focused composer.
///
/// In the app the two sit in different hosting views (the panel in the
/// window's root, the composer in the split view's detail column), and with a
/// real click on the Search button SwiftUI asserted the composer's focus again
/// over the panel's request: the panel showed, typing went into the composer.
/// A hosted view does not reproduce that race, so these tests stand in for it
/// by moving the first responder back to the composer field, which is how the
/// race shows in AppKit.
@Suite("Search panel keyboard focus", .serialized)
@MainActor
struct SearchPanelKeyboardFocusTests {
    @Test("The field takes the keyboard once, and takes it back only until it is released")
    func policy() {
        typealias Policy = SearchPanelKeyboardPolicy
        // Presenting: taken from whoever holds it.
        #expect(Policy.shouldTakeKeyboard(fieldHoldsKeyboard: false, isReleased: false, takes: 0))
        #expect(Policy.shouldTakeKeyboard(fieldHoldsKeyboard: false, isReleased: true, takes: 0))
        #expect(!Policy.shouldTakeKeyboard(fieldHoldsKeyboard: true, isReleased: false, takes: 0))
        // Moved away before the user did anything: taken back, a bounded number of times.
        #expect(Policy.shouldTakeKeyboard(fieldHoldsKeyboard: false, isReleased: false, takes: 1))
        #expect(Policy.shouldTakeKeyboard(fieldHoldsKeyboard: false, isReleased: false, takes: Policy.maximumTakes - 1))
        #expect(!Policy.shouldTakeKeyboard(fieldHoldsKeyboard: false, isReleased: false, takes: Policy.maximumTakes))
        // Moved by the user, or while the panel closes: left where it went.
        #expect(!Policy.shouldTakeKeyboard(fieldHoldsKeyboard: false, isReleased: true, takes: 1))
        #expect(!Policy.shouldTakeKeyboard(fieldHoldsKeyboard: true, isReleased: true, takes: 1))
    }

    @Test("Opening the panel over a focused composer moves typing to the search field")
    func openingTakesTheKeyboard() throws {
        let fixture = SearchPanelFixture()
        defer { fixture.tearDown() }
        try fixture.focusComposer()
        fixture.type("my draft")
        #expect(fixture.model.draft == "my draft")

        fixture.model.isSearchActive = true
        fixture.settle { fixture.searchFieldHoldsKeyboard }
        #expect(fixture.searchFieldHoldsKeyboard)

        fixture.type("abc")
        #expect(try fixture.searchField().stringValue == "abc")
        #expect(fixture.model.draft == "my draft")
    }

    @Test("A composer focus asserted again over the open panel does not keep the keyboard")
    func reassertedComposerFocusIsTakenBack() throws {
        let fixture = SearchPanelFixture()
        defer { fixture.tearDown() }
        try fixture.focusComposer()
        fixture.type("my draft")
        fixture.model.isSearchActive = true
        fixture.settle { fixture.searchFieldHoldsKeyboard }

        // The first take and each of these count against the bound.
        for _ in 1..<SearchPanelKeyboardPolicy.maximumTakes {
            try fixture.focusComposer()
            fixture.settle { fixture.searchFieldHoldsKeyboard }
            #expect(fixture.searchFieldHoldsKeyboard)
        }
        fixture.type("abc")
        #expect(try fixture.searchField().stringValue == "abc")
        #expect(fixture.model.draft == "my draft")

        // Past the bound the panel stops insisting.
        try fixture.focusComposer()
        fixture.settle()
        #expect(try fixture.keyboardField === fixture.composerField())
    }

    @Test("After the user's key press or click, a focus that moves stays where it went")
    func userInputEndsTheHold() throws {
        let fixture = SearchPanelFixture()
        defer { fixture.tearDown() }
        fixture.model.isSearchActive = true
        fixture.settle { fixture.searchFieldHoldsKeyboard }
        #expect(fixture.searchFieldHoldsKeyboard)

        // What the holder's event monitor does on a key press or click in its
        // window. Events sent straight to a window do not pass the monitor.
        try fixture.holder().release()

        try fixture.focusComposer()
        fixture.settle()
        #expect(try fixture.keyboardField === fixture.composerField())
    }

    @Test("Escape closes the panel, keeps the draft, and lets the next screen take the keyboard")
    func escapeClosesAndReleases() throws {
        let fixture = SearchPanelFixture()
        defer { fixture.tearDown() }
        try fixture.focusComposer()
        fixture.type("my draft")
        fixture.model.isSearchActive = true
        fixture.settle { fixture.searchFieldHoldsKeyboard }
        fixture.type("abc")

        try fixture.pressEscape()
        fixture.settle { !fixture.model.isSearchActive }
        #expect(!fixture.model.isSearchActive)
        #expect(fixture.model.draft == "my draft")

        // The panel is still fading out when the screen behind it may ask for
        // the keyboard. It must not be pulled back into the closing panel.
        try fixture.focusComposer()
        fixture.settle()
        #expect(try fixture.keyboardField === fixture.composerField())
        fixture.type("!")
        #expect(fixture.model.draft.contains("!"))
    }

    @Test("The panel's field takes the keyboard through the holder, not a focus state")
    func panelWiresTheHolder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/SearchPanelOverlayView.swift"),
            encoding: .utf8
        )
        let field = try #require(panel.range(of: "TextField(\"Search tasks and workspaces\""))
        let holder = try #require(panel.range(of: ".takesKeyboardWhenPresented(keyboard)"))
        let submit = try #require(panel.range(of: ".onSubmit {"))
        // On the field itself: the holder finds the field by its frame.
        #expect(field.lowerBound < holder.lowerBound)
        #expect(holder.lowerBound < submit.lowerBound)
        // A focus state set on appear is the request the composer's focus won over.
        #expect(!panel.contains("@FocusState"))
        #expect(!panel.contains("isFocused = true"))
        // Every way the panel closes itself ends the hold first.
        #expect(panel.contains("private func dismiss() {\n        keyboard.release()"))
    }
}

@MainActor
@Observable
private final class SearchPanelHostModel {
    var draft = ""
    var isSearchActive = false
}

/// A composer-like field with the real panel presented over it, the way
/// `ContentView` presents it.
private struct SearchPanelHost: View {
    static let composerPlaceholder = "Message"

    @Bindable var model: SearchPanelHostModel
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack {
            Spacer()
            TextField(Self.composerPlaceholder, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isComposerFocused)
                .padding(12)
        }
        .frame(width: 900, height: 600)
        .overlay {
            if model.isSearchActive {
                SearchPanelOverlay(
                    tasks: [],
                    workspaces: [],
                    selectedTask: .constant(nil),
                    selectedWorkspace: .constant(nil),
                    isActive: $model.isSearchActive
                )
            }
        }
    }
}

@MainActor
private final class SearchPanelFixture {
    static let searchPlaceholder = "Search tasks and workspaces"

    let model = SearchPanelHostModel()
    let window: NSWindow
    private var host: NSHostingView<AnyView>!

    init() {
        // Off every display and never key: events reach it only through
        // `sendEvent`, so nothing here touches the user's own windows.
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(SearchPanelHost(model: model)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        window.displayIfNeeded()
        settle()
    }

    /// The field the window's key presses go to.
    var keyboardField: NSTextField? {
        (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    }

    var searchFieldHoldsKeyboard: Bool {
        keyboardField?.placeholderString == Self.searchPlaceholder
    }

    /// Spin the run loop a few turns so pending updates land.
    func settle() {
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Spin the run loop until `done`, counting turns, not seconds.
    func settle(until done: () -> Bool) {
        for _ in 0..<400 {
            if done() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    func composerField() throws -> NSTextField {
        try field(SearchPanelHost.composerPlaceholder)
    }

    func searchField() throws -> NSTextField {
        try field(Self.searchPlaceholder)
    }

    func holder() throws -> SearchPanelKeyboardHolder {
        try #require(Self.first(SearchPanelKeyboardHolder.self, in: host) { _ in true })
    }

    /// Makes the composer field first responder: what a composer asking for
    /// the focus, or SwiftUI asserting a focus it already has, comes to.
    func focusComposer() throws {
        let composer = try composerField()
        #expect(window.makeFirstResponder(composer))
        settle { self.keyboardField === composer }
    }

    /// Types into whichever field holds the keyboard.
    func type(_ text: String) {
        guard let editor = window.firstResponder as? NSTextView, let field = keyboardField else {
            Issue.record("no field holds the keyboard")
            return
        }
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        settle { field.stringValue.hasSuffix(text) }
    }

    func pressEscape() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        window.sendEvent(event)
    }

    func tearDown() {
        window.makeFirstResponder(nil)
        window.contentView = nil
        host.removeFromSuperview()
        window.close()
    }

    private func field(_ placeholder: String) throws -> NSTextField {
        try #require(Self.first(NSTextField.self, in: host) { $0.placeholderString == placeholder })
    }

    private static func first<Found: NSView>(_ type: Found.Type, in view: NSView, where matches: (Found) -> Bool) -> Found? {
        if let found = view as? Found, matches(found) { return found }
        for subview in view.subviews {
            if let found = first(type, in: subview, where: matches) { return found }
        }
        return nil
    }
}
