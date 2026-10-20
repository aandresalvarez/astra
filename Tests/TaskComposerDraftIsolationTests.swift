import AppKit
import SwiftUI
import Testing
@testable import ASTRA

/// `TaskMainView` hands the composer's text to `TaskComposerDraft` so typing
/// stops re-running the body that builds the non-lazy transcript. These host a
/// view shaped like it (an expensive sibling plus readers) and count `body`
/// passes, pinning the two properties that design rests on: typing reaches
/// only the readers, and parent state captured into a reader still refreshes it.
@Suite("Task composer draft isolation")
@MainActor
struct TaskComposerDraftIsolationTests {
    final class Counts {
        var parentBodies = 0
        var transcriptBodies = 0
        var readerBodies = 0
        var lastRenderedText = ""
        var lastRenderedSuffix = ""
    }

    @MainActor
    private enum HostLifetime {
        private static var retained: [Any] = []

        static func keepAlive(_ values: Any...) {
            retained.append(contentsOf: values)
        }
    }

    private struct Parent: View {
        let draft: TaskComposerDraft
        let counts: Counts
        @Binding var suffix: String
        @State private var itemCount = 3

        var body: some View {
            counts.parentBodies += 1
            // Captured as a local, as `composerView` does with the eligibility
            // inputs and the toolbar.
            let suffix = suffix
            return VStack {
                transcript()
                TaskComposerTextReader(draft: draft) { text in
                    readerContent(text: text, suffix: suffix)
                }
            }
        }

        /// Built inline, as `TaskMainView.conversationItemsList` is, so it
        /// runs whenever this body does. A child view with unchanged inputs
        /// would be skipped by SwiftUI and hide exactly the regression.
        private func transcript() -> some View {
            counts.transcriptBodies += 1
            return VStack {
                ForEach(0..<itemCount, id: \.self) { Text("Row \($0)") }
            }
        }

        private func readerContent(text: String, suffix: String) -> some View {
            counts.readerBodies += 1
            counts.lastRenderedText = text
            counts.lastRenderedSuffix = suffix
            return TextField("Message", text: Bindable(draft).text)
        }
    }

    private struct Harness: View {
        let draft: TaskComposerDraft
        let counts: Counts
        @State var suffix = "a"
        let suffixSetter: (Binding<String>) -> Void

        var body: some View {
            Parent(draft: draft, counts: counts, suffix: $suffix)
                .onAppear { suffixSetter($suffix) }
        }
    }

    private func settle(until predicate: () -> Bool, turns: Int = 400) async {
        for _ in 0..<turns {
            if predicate() { return }
            _ = await MainActor.run {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func host(_ view: some View) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: 320, height: 240))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        HostLifetime.keepAlive(host, window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test("Typing re-runs the reader, never the parent or its transcript")
    func typingReachesOnlyTheReader() async {
        let draft = TaskComposerDraft()
        let counts = Counts()
        HostLifetime.keepAlive(draft, counts)
        var suffixBinding: Binding<String>?
        _ = host(Harness(draft: draft, counts: counts, suffixSetter: { suffixBinding = $0 }))
        await settle(until: { counts.readerBodies > 0 && suffixBinding != nil })

        let parentBefore = counts.parentBodies
        let transcriptBefore = counts.transcriptBodies
        let readerBefore = counts.readerBodies

        for character in "hello" {
            draft.text.append(character)
            await settle(until: { counts.lastRenderedText == draft.text })
        }

        #expect(counts.lastRenderedText == "hello")
        #expect(counts.readerBodies > readerBefore)
        #expect(counts.parentBodies == parentBefore, "a keystroke re-ran the parent body")
        #expect(counts.transcriptBodies == transcriptBefore, "a keystroke rebuilt the transcript")
    }

    @Test("Parent state captured into the reader still refreshes it")
    func capturedParentStateRefreshesReader() async throws {
        let draft = TaskComposerDraft()
        let counts = Counts()
        HostLifetime.keepAlive(draft, counts)
        var suffixBinding: Binding<String>?
        _ = host(Harness(draft: draft, counts: counts, suffixSetter: { suffixBinding = $0 }))
        await settle(until: { counts.readerBodies > 0 && suffixBinding != nil })
        let binding = try #require(suffixBinding)

        binding.wrappedValue = "b"
        await settle(until: { counts.lastRenderedSuffix == "b" })

        #expect(counts.lastRenderedSuffix == "b")
    }

    @Test("Resetting an already-reset slash selection does not notify observers")
    func slashResetIsQuietWhenAlreadyReset() {
        let draft = TaskComposerDraft()
        var notified = false
        withObservationTracking {
            _ = draft.slashSelectedIndex
        } onChange: {
            notified = true
        }
        draft.noteTextChanged()
        #expect(!notified)

        draft.slashSelectedIndex = 2
        #expect(notified)
    }
}
