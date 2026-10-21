import SwiftUI
import Observation

/// The open task composer's per-keystroke state, kept out of `TaskMainView`'s
/// own storage.
///
/// `TaskMainView.body` builds the whole transcript, and that transcript is a
/// deliberately non-lazy stack (see `summaryContent`). While the typed text
/// was `@State` on the view, every keystroke re-ran that body, rebuilt every
/// row and sent AppKit through a full window layout pass: about 1 s per key on
/// a 148-item thread (prod 0.1.30, 2026-10-20 sample). As an `@Observable`,
/// the text invalidates only the views whose `body` reads it, which are the
/// `TaskComposerTextReader`s around the field, the slash menu, the toolbar
/// and the eligibility preview. `TaskMainView` reads it only from actions
/// (send, slash selection, a suggested next step), and observation does not
/// track reads made outside a `body` evaluation.
@MainActor
@Observable
final class TaskComposerDraft {
    var text = ""
    var slashSelectedIndex = 0
    /// Lives here, not on `TaskMainView`, because the preview resolves after
    /// every typing pause: as parent `@State` each verdict re-ran the
    /// transcript body as well.
    var eligibilityPreviewState = RuntimeEligibilityPreviewState.idle

    /// Typing resets the slash selection on each keystroke. Observation
    /// notifies on every assignment, equal or not, so the reset only writes
    /// when there is something to reset.
    func noteTextChanged() {
        if slashSelectedIndex != 0 {
            slashSelectedIndex = 0
        }
    }
}

/// Reads the draft's text in its own `body`, so a keystroke re-runs this view
/// and `content` alone, never the view that built it.
///
/// `content` runs inside this view's update, so build it from values the
/// parent already computed in its own `body` (capture them as locals). That
/// keeps the parent's dependencies with the parent: a change to one of them
/// re-runs the parent, which hands this view a new closure.
struct TaskComposerTextReader<Content: View>: View {
    let draft: TaskComposerDraft
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        content(draft.text)
    }
}

extension ComposerToolbar {
    /// The toolbar the parent built in its `body`, completed with the inputs
    /// that change per keystroke. Called from inside a `TaskComposerTextReader`.
    func composing(
        hasInput: Bool,
        previewState: RuntimeEligibilityPreviewState,
        previewSignature: String
    ) -> ComposerToolbar {
        var toolbar = self
        toolbar.hasInput = hasInput
        toolbar.runtimeEligibilityPreviewState = previewState
        toolbar.runtimeEligibilityPreviewSignature = previewSignature
        return toolbar
    }
}
