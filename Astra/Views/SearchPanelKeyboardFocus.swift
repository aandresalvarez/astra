import AppKit
import SwiftUI

/// When the search panel's field takes the window's keyboard.
///
/// The panel is an overlay in the window's root hosting view. A composer sits
/// in the split view's detail column, which SwiftUI hosts in a view of its
/// own, and each hosting view keeps its own focus. When the panel opened over
/// a focused composer and asked for the focus through a focus state, the
/// composer's focus could be asserted again over that request: the panel
/// showed, and typing still went into the composer.
///
/// So the field takes the window's first responder itself, the way a click on
/// it does, and takes it back if it is moved before the user has pressed a
/// key or clicked, or the panel has begun to close. After that the keyboard
/// goes wherever the user, or the screen they chose, sends it.
enum SearchPanelKeyboardPolicy {
    /// The take on presenting plus three takings-back: enough to answer a
    /// focus that is asserted more than once, and a bound, so two fields that
    /// both insist cannot trade the keyboard forever.
    static let maximumTakes = 4

    /// - Parameters:
    ///   - isReleased: the user has pressed a key or clicked in the window
    ///     since the panel came up, or the panel is dismissing itself.
    ///   - takes: how many times the field has taken the keyboard so far.
    static func shouldTakeKeyboard(fieldHoldsKeyboard: Bool, isReleased: Bool, takes: Int) -> Bool {
        guard !fieldHoldsKeyboard, takes < maximumTakes else { return false }
        return takes == 0 || !isReleased
    }
}

/// The panel's handle on its field's keyboard hold, so it can end the hold
/// when it dismisses itself: the screen behind it may ask for the keyboard
/// while the panel is still fading out.
@MainActor
final class SearchPanelKeyboard {
    fileprivate weak var holder: SearchPanelKeyboardHolder?

    func release() {
        holder?.release()
    }
}

extension View {
    /// Gives this text field the keyboard when it comes on screen. See
    /// `SearchPanelKeyboardPolicy`. Apply it to the field itself: the field is
    /// found by its frame.
    func takesKeyboardWhenPresented(_ keyboard: SearchPanelKeyboard) -> some View {
        background(SearchPanelKeyboardAnchor(keyboard: keyboard).allowsHitTesting(false))
    }
}

private struct SearchPanelKeyboardAnchor: NSViewRepresentable {
    let keyboard: SearchPanelKeyboard

    func makeNSView(context: Context) -> SearchPanelKeyboardHolder {
        let view = SearchPanelKeyboardHolder()
        keyboard.holder = view
        return view
    }

    func updateNSView(_ view: SearchPanelKeyboardHolder, context: Context) {
        keyboard.holder = view
    }
}

/// Covers the field's area without taking its clicks, and watches the window's
/// first responder while the field is in a window.
final class SearchPanelKeyboardHolder: NSView {
    /// The field is laid out in the same pass as this view; the retries cover
    /// a pass that has not placed it yet.
    private static let maximumFieldLookups = 10
    private static let userInput: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    private var observation: NSKeyValueObservation?
    private var inputMonitor: Any?
    private var takes = 0
    private var fieldLookups = 0
    private var isReleased = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatching()
        guard let window else { return }
        takes = 0
        fieldLookups = 0
        isReleased = false
        // Checked on the next turn of the run loop: the responder changes
        // before the field that takes it has started editing.
        observation = window.observe(\.firstResponder) { [weak self] _, _ in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.check() }
            }
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.userInput) { [weak self] event in
            if let self, event.window === self.window { self.release() }
            return event
        }
        checkSoon()
    }

    /// The user pressed a key or clicked in this window, or the panel is
    /// closing: from here on a focus that moves is meant to.
    func release() {
        isReleased = true
    }

    private func checkSoon() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let window, observation != nil else { return }
        guard let field = field() else {
            fieldLookups += 1
            if fieldLookups < Self.maximumFieldLookups { checkSoon() }
            return
        }
        guard SearchPanelKeyboardPolicy.shouldTakeKeyboard(
            fieldHoldsKeyboard: field.currentEditor() != nil,
            isReleased: isReleased,
            takes: takes
        ) else { return }
        takes += 1
        window.makeFirstResponder(field)
    }

    /// The editable field that lies in this view's area.
    private func field() -> NSTextField? {
        var root: NSView = self
        while let parent = root.superview { root = parent }
        // A text field's own frame reaches a little past its SwiftUI layout frame.
        let area = convert(bounds, to: nil).insetBy(dx: -4, dy: -4)
        return Self.editableField(in: root, inside: area)
    }

    private static func editableField(in view: NSView, inside area: NSRect) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, area.contains(field.convert(field.bounds, to: nil)) {
            return field
        }
        for subview in view.subviews {
            if let field = editableField(in: subview, inside: area) { return field }
        }
        return nil
    }

    private func stopWatching() {
        observation = nil
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
            self.inputMonitor = nil
        }
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
}
