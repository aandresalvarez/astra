import AppKit
import Observation
import SwiftUI
import Testing
@testable import ASTRA

/// The composer's Return handling, height, click target and focus behavior,
/// driven through a hosted field that wears the modifiers both composers apply.
///
/// Shift-Return used to be a key monitor that appended "\n" to the end of the
/// bound text, so the line break landed after the last character wherever the
/// caret was, and the caret jumped there with it. And a composer whose field
/// started editing again (a restored draft, the search overlay opening over
/// it) had its whole text selected, so the next key replaced the draft.
@Suite("Composer input interaction", .serialized)
@MainActor
struct ComposerInputInteractionTests {
    @Test("Shift-Return and Option-Return start a new line; any other Return sends")
    func returnKeyPolicy() {
        typealias Policy = ComposerReturnKeyPolicy
        #expect(Policy.action(modifiers: [], hasMarkedText: false) == .submit)
        #expect(Policy.action(modifiers: .shift, hasMarkedText: false) == .insertNewline)
        #expect(Policy.action(modifiers: .option, hasMarkedText: false) == .insertNewline)
        #expect(Policy.action(modifiers: [.shift, .option], hasMarkedText: false) == .insertNewline)
        #expect(Policy.action(modifiers: .command, hasMarkedText: false) == .submit)
        #expect(Policy.action(modifiers: .control, hasMarkedText: false) == .submit)
        // An input method that is composing owns Return, whatever is held.
        #expect(Policy.action(modifiers: [], hasMarkedText: true) == .passToInputMethod)
        #expect(Policy.action(modifiers: .shift, hasMarkedText: true) == .passToInputMethod)
        #expect(Policy.keys == [.return, KeyEquivalent("\u{3}")])
    }

    @Test("Shift-Return breaks the line at the caret and replaces a selection")
    func newLineLandsAtTheCaret() throws {
        let fixture = ComposerFieldFixture()
        defer { fixture.tearDown() }
        let editor = try fixture.focusField()
        fixture.type("hello world", into: editor)
        editor.setSelectedRange(NSRange(location: 5, length: 0))

        try fixture.pressReturn(.shift)
        fixture.settle { fixture.model.text == "hello\n world" }
        #expect(fixture.model.text == "hello\n world")
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))

        editor.setSelectedRange(NSRange(location: 6, length: 6))
        try fixture.pressReturn(.option)
        fixture.settle { fixture.model.text == "hello\n\n" }
        #expect(fixture.model.text == "hello\n\n")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))

        // A held Shift-Return keeps adding lines; none of this sends.
        try fixture.pressReturn(.shift, isRepeat: true)
        fixture.settle { fixture.model.text == "hello\n\n\n" }
        #expect(fixture.model.text == "hello\n\n\n")
        #expect(fixture.model.submits == 0)
    }

    @Test("Return sends once, keeps the caret, and keypad Enter follows the same rules")
    func returnSendsOnce() throws {
        let fixture = ComposerFieldFixture()
        defer { fixture.tearDown() }
        let editor = try fixture.focusField()
        fixture.type("hello", into: editor)

        try fixture.pressReturn()
        fixture.settle { fixture.model.submits == 1 }
        #expect(fixture.model.submits == 1)
        #expect(fixture.model.text == "hello")
        // The field's native commit would have selected the whole text.
        #expect(editor.selectedRange() == NSRange(location: 5, length: 0))

        try fixture.pressReturn(isRepeat: true)
        fixture.settle()
        #expect(fixture.model.submits == 1)

        try fixture.pressReturn(keypad: true)
        fixture.settle { fixture.model.submits == 2 }
        #expect(fixture.model.submits == 2)
        #expect(editor.selectedRange() == NSRange(location: 5, length: 0))

        try fixture.pressReturn(.shift, keypad: true)
        fixture.settle { fixture.model.text == "hello\n" }
        #expect(fixture.model.text == "hello\n")
        #expect(fixture.model.submits == 2)
    }

    @Test("An empty field is one line tall and grows a line at a time up to its limit")
    func fieldGrowsWithItsLines() throws {
        let fixture = ComposerFieldFixture()
        defer { fixture.tearDown() }
        let editor = try fixture.focusField()
        let oneLine = try fixture.fieldHeight()
        #expect(oneLine > 0)

        fixture.type("one", into: editor)
        #expect(try fixture.fieldHeight() == oneLine)

        // The line a trailing break opens is visible before anything is typed on it.
        try fixture.pressReturn(.shift)
        fixture.settle { (try? fixture.fieldHeight()).map { $0 > oneLine * 1.5 } ?? false }
        let twoLines = try fixture.fieldHeight()
        #expect(twoLines > oneLine * 1.5)
        #expect(twoLines < oneLine * 2.5)

        let limit = CGFloat(TaskComposerPresentation.inputLineLimit.upperBound)
        for _ in 0..<(TaskComposerPresentation.inputLineLimit.upperBound * 2) {
            try fixture.pressReturn(.shift)
        }
        fixture.settle { (try? fixture.fieldHeight()).map { $0 > oneLine * (limit - 2) } ?? false }
        let capped = try fixture.fieldHeight()
        #expect(capped > oneLine * (limit - 2))
        #expect(capped < oneLine * (limit + 1))
    }

    @Test("A click on the padding focuses the field with the caret at the end")
    func paddingFocusesTheField() throws {
        let fixture = ComposerFieldFixture()
        defer { fixture.tearDown() }
        fixture.model.text = "hello world"
        try fixture.blur()

        try fixture.clickTopPadding()
        fixture.settle { fixture.focusedEditor?.selectedRange() == NSRange(location: 11, length: 0) }
        let editor = try #require(fixture.focusedEditor)
        #expect(editor.selectedRange() == NSRange(location: 11, length: 0))

        // A click there while typing leaves a bare caret alone...
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        try fixture.clickTopPadding()
        fixture.settle()
        #expect(fixture.focusedEditor?.selectedRange() == NSRange(location: 3, length: 0))

        // ...and deselects, as a click beside the text of any editor does.
        editor.selectAll(nil)
        try fixture.clickTopPadding()
        fixture.settle { fixture.focusedEditor?.selectedRange() == NSRange(location: 11, length: 0) }
        #expect(fixture.focusedEditor?.selectedRange() == NSRange(location: 11, length: 0))
    }

    @Test("A tap on the text keeps its selection; only the padding deselects")
    func tapOnTheTextKeepsItsSelection() throws {
        let fixture = ComposerFieldFixture()
        defer { fixture.tearDown() }
        let editor = try fixture.focusField()
        fixture.type("hello world", into: editor)
        // The word a double-click leaves selected.
        let word = NSRange(location: 0, length: 5)
        editor.setSelectedRange(word)

        // The rule itself: this Mac's SwiftUI does not report a click on the
        // text to the padding's gesture, so the event below cannot prove it.
        let area = fixture.hostView
        let text = editor.convert(editor.bounds, to: area)
        ComposerFieldSelection.collapse(editor, forTapAt: CGPoint(x: text.midX, y: text.midY), in: area)
        #expect(editor.selectedRange() == word)

        // Through the gesture, wherever it does report it: whatever the editor
        // makes of one more click on the word, the selection is not thrown to
        // the end of the draft.
        try fixture.clickText()
        fixture.settle()
        #expect(fixture.focusedEditor?.selectedRange() != NSRange(location: 11, length: 0))

        editor.setSelectedRange(word)
        let padding = CGPoint(x: text.midX, y: text.minY - TaskComposerPresentation.inputTopPadding / 2)
        ComposerFieldSelection.collapse(editor, forTapAt: padding, in: area)
        #expect(editor.selectedRange() == NSRange(location: 11, length: 0))
    }

    @Test("Taking focus never leaves the draft selected for the next key to replace")
    func focusKeepsTheDraft() throws {
        let fixture = ComposerFieldFixture()
        defer { fixture.tearDown() }
        fixture.model.text = "hello world"
        try fixture.blur()

        // How the app's own focus requests and the Tab key arrive. AppKit
        // selects the whole text of a field that becomes first responder.
        let editor = try fixture.focusField()
        fixture.settle { editor.selectedRange() == NSRange(location: 11, length: 0) }
        #expect(editor.selectedRange() == NSRange(location: 11, length: 0))

        fixture.type("!", into: editor)
        #expect(fixture.model.text == "hello world!")

        // SwiftUI re-asserts the focus of a field that never lost it when the
        // search overlay opens over a focused composer: the editor is torn
        // down and set up again, the text is selected again, and no focus
        // state changes.
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let reasserted = try fixture.focusField()
        fixture.settle { reasserted.selectedRange() == NSRange(location: 12, length: 0) }
        #expect(reasserted.selectedRange() == NSRange(location: 12, length: 0))
    }
}

@MainActor
@Observable
private final class ComposerFieldModel {
    var text = ""
    var submits = 0
}

/// The modifier chain `ChatPanelView` and `TaskMainView` put on their field.
private struct ComposerFieldUnderTest: View {
    @Bindable var model: ComposerFieldModel
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Message", text: $model.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Stanford.chatBody())
            .lineLimit(TaskComposerPresentation.inputLineLimit)
            .focused($isFocused)
            .padding(.horizontal, TaskComposerPresentation.inputHorizontalPadding)
            .padding(.top, TaskComposerPresentation.inputTopPadding)
            .padding(.bottom, TaskComposerPresentation.inputBottomPadding)
            .composerInput(focus: $isFocused) { model.submits += 1 }
    }
}

@MainActor
private final class ComposerFieldFixture {
    let model = ComposerFieldModel()
    let window: NSWindow
    private var host: NSHostingView<AnyView>!

    init() {
        // Off every display and never key: events reach it only through
        // `sendEvent`, so nothing here touches the user's own windows.
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 360),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = ComposerFieldUnderTest(model: model)
        host = FirstMouseHostingView(rootView: AnyView(field.frame(width: 480, height: 360, alignment: .top)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        window.displayIfNeeded()
        settle()
    }

    var focusedEditor: NSTextView? { window.firstResponder as? NSTextView }
    var hostView: NSView { host }

    /// Spin the run loop a few turns so pending updates land.
    func settle() {
        for _ in 0..<4 {
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

    /// A window hands its first field the focus when it comes up. The turns
    /// let the focus state follow: a blur and a focus inside one run loop
    /// turn would reach the view as no change at all.
    func blur() throws {
        settle()
        #expect(window.makeFirstResponder(nil))
        settle()
        #expect(focusedEditor == nil)
    }

    func focusField() throws -> NSTextView {
        let field = try textField()
        #expect(window.makeFirstResponder(field))
        settle { self.focusedEditor != nil }
        return try #require(focusedEditor)
    }

    func type(_ text: String, into editor: NSTextView) {
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        settle { self.model.text.hasSuffix(text) }
    }

    func fieldHeight() throws -> CGFloat {
        host.layoutSubtreeIfNeeded()
        return try textField().frame.height
    }

    func pressReturn(_ flags: NSEvent.ModifierFlags = [], keypad: Bool = false, isRepeat: Bool = false) throws {
        let characters = keypad ? "\u{3}" : "\r"
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isRepeat, keyCode: keypad ? 76 : 36
        ))
        window.sendEvent(event)
    }

    func clickTopPadding() throws {
        let frame = try textField().convert(try textField().bounds, to: nil)
        try click(NSPoint(x: frame.midX, y: frame.maxY + TaskComposerPresentation.inputTopPadding / 2))
    }

    /// Inside the field, on its first word.
    func clickText() throws {
        let frame = try textField().convert(try textField().bounds, to: nil)
        try click(NSPoint(x: frame.minX + 20, y: frame.midY))
    }

    private func click(_ location: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func tearDown() {
        window.makeFirstResponder(nil)
        window.contentView = nil
        host.removeFromSuperview()
        window.close()
    }

    private func textField() throws -> NSTextField {
        try #require(Self.firstTextField(in: host))
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }
}

@MainActor
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
