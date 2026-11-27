import AppKit
import SwiftUI

/// What a Return press means in a composer.
enum ComposerReturnKeyAction: Equatable {
    case submit
    case insertNewline
    /// An input method is composing, and Return confirms its candidate.
    case passToInputMethod
}

enum ComposerReturnKeyPolicy {
    /// Return and keypad Enter. Keypad Enter types its own character (ETX),
    /// so `.return` alone would leave it to the field's native commit.
    static let keys: Set<KeyEquivalent> = [.return, KeyEquivalent("\u{3}")]

    /// Shift-Return and Option-Return start a new line; any other Return sends.
    static func action(modifiers: EventModifiers, hasMarkedText: Bool) -> ComposerReturnKeyAction {
        if hasMarkedText { return .passToInputMethod }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .insertNewline }
        return .submit
    }
}

extension View {
    /// What a composer's text field does beyond typing. Apply it after the
    /// field's padding, which becomes part of its click target.
    ///
    /// - Return sends; Shift-Return or Option-Return starts a new line at the
    ///   caret. The press is consumed before the field's native commit, which
    ///   would select the whole text. `onSubmit` remains for a commit that
    ///   does not arrive as a key press.
    /// - The field is one line tall when empty, so a click on its padding
    ///   focuses it.
    /// - AppKit selects a field's whole text when it starts editing, and the
    ///   next key would then replace the draft. The caret goes to the end.
    func composerInput(focus: FocusState<Bool>.Binding, onSubmit submit: @escaping () -> Void) -> some View {
        modifier(ComposerInputInteraction(focus: focus, submit: submit))
    }
}

private struct ComposerInputInteraction: ViewModifier {
    let focus: FocusState<Bool>.Binding
    let submit: () -> Void
    @State private var field = ComposerFieldAnchor()

    func body(content: Content) -> some View {
        content
            .background(ComposerFieldAnchorView(anchor: field).allowsHitTesting(false))
            .contentShape(Rectangle())
            .onTapGesture {
                if focus.wrappedValue {
                    field.collapseSelection()
                } else {
                    focus.wrappedValue = true
                }
            }
            .onSubmit(submit)
            .onKeyPress(keys: ComposerReturnKeyPolicy.keys, phases: [.down, .repeat]) { press in
                field.handleReturn(press, submit: submit)
            }
    }
}

/// Where one composer field sits in AppKit: the area it covers in its window,
/// and so the field editor it types through while it is being edited.
///
/// A window has one first responder, so the editor is this field's exactly
/// when the field it is editing lies inside the anchored area. Asking the key
/// window instead would reach another window's composer, or the search
/// panel's field, whenever this one is not key.
@MainActor
private final class ComposerFieldAnchor {
    weak var view: NSView?

    private var editor: NSTextView? {
        guard let view,
              let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let edited = editor.delegate as? NSView else { return nil }
        // A text field's own frame reaches a little past its SwiftUI layout frame.
        let area = view.convert(view.bounds, to: nil).insetBy(dx: -4, dy: -4)
        return area.contains(edited.convert(edited.bounds, to: nil)) ? editor : nil
    }

    func handleReturn(_ press: KeyPress, submit: () -> Void) -> KeyPress.Result {
        let editor = editor
        let action = ComposerReturnKeyPolicy.action(
            modifiers: press.modifiers,
            hasMarkedText: editor?.hasMarkedText() ?? false
        )
        switch action {
        case .passToInputMethod:
            return .ignored
        case .insertNewline:
            // Through the editor, so the break lands at the insertion point,
            // replaces a selection, and grows and scrolls the field the way
            // typing does. With no editor the press is dropped: letting it
            // through would commit, and so send, a half-written message.
            editor?.insertNewlineIgnoringFieldEditor(nil)
            return .handled
        case .submit:
            // A held Return sends once.
            if press.phase == .down { submit() }
            return .handled
        }
    }

    /// The window's first responder changed. AppKit selects the whole text of
    /// a field that starts editing, whoever asked for it: a click on the
    /// padding, the Tab key, or SwiftUI re-asserting a focus the field never
    /// lost, as it does when the search overlay opens over a focused composer.
    /// That last one changes no focus state, so this watches the responder
    /// itself. A click inside the text places its own caret and is left alone.
    func firstResponderChanged() {
        guard let editor, !Self.currentEventIsClick(in: editor) else { return }
        let length = (editor.string as NSString).length
        guard length > 0, editor.selectedRange() == NSRange(location: 0, length: length) else { return }
        editor.moveToEndOfDocument(nil)
    }

    /// A click on the padding of the focused field deselects, as a click
    /// beside the text of any editor does. A bare caret stays where it is.
    func collapseSelection() {
        guard let editor, editor.selectedRange().length > 0 else { return }
        editor.moveToEndOfDocument(nil)
    }

    private static func currentEventIsClick(in editor: NSTextView) -> Bool {
        guard let event = NSApplication.shared.currentEvent, event.window === editor.window else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return editor.bounds.contains(editor.convert(event.locationInWindow, from: nil))
        default:
            return false
        }
    }
}

/// Covers the field's area without taking its clicks, and reports each change
/// of its window's first responder.
private struct ComposerFieldAnchorView: NSViewRepresentable {
    let anchor: ComposerFieldAnchor

    func makeNSView(context: Context) -> ResponderWatchingView {
        let view = ResponderWatchingView()
        connect(view)
        return view
    }

    func updateNSView(_ view: ResponderWatchingView, context: Context) {
        connect(view)
    }

    private func connect(_ view: ResponderWatchingView) {
        anchor.view = view
        view.onFirstResponderChange = { [weak anchor] in anchor?.firstResponderChanged() }
    }

    final class ResponderWatchingView: NSView {
        var onFirstResponderChange: (@MainActor () -> Void)?
        private var observation: NSKeyValueObservation?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Reported on the next turn of the run loop: the responder
            // changes before the field has selected its text.
            observation = window?.observe(\.firstResponder) { [weak self] _, _ in
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { self?.onFirstResponderChange?() }
                }
            }
        }
    }
}
