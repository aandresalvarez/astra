import Foundation
import Testing

/// Typing in an open task lagged about 1 s per key on large threads (prod
/// 0.1.30, 2026-10-20): the composer text was `@State` on `TaskMainView`, so
/// each keystroke re-ran the body that builds the deliberately non-lazy
/// transcript, and AppKit re-laid out every row. The text now lives in
/// `TaskComposerDraft`, and `body` may read it only through a
/// `TaskComposerTextReader`. `TaskComposerDraftIsolationTests` proves the
/// mechanism in a hosted view; this pins that `TaskMainView` keeps using it.
@Suite("Composer draft fitness")
struct ComposerDraftFitnessTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("TaskMainView keeps no per-keystroke composer state of its own")
    func taskMainViewKeepsNoPerKeystrokeState() throws {
        let taskMainView = try code(source("Astra/Views/TaskMainView.swift"))

        #expect(taskMainView.contains("@State var composerDraft = TaskComposerDraft()"))
        #expect(!taskMainView.contains("var messageText"))
        #expect(!taskMainView.contains("$messageText"))
        #expect(!taskMainView.contains("var slashSelectedIndex"))
        #expect(!taskMainView.contains("var runtimeEligibilityPreviewState"))
    }

    @Test("TaskMainView.body never reads the draft directly")
    func bodyReadsTheDraftOnlyThroughReaders() throws {
        let taskMainView = try source("Astra/Views/TaskMainView.swift")
        // Several structs in the file have a `body`; take the view's own.
        let mainView = try code(taskMainView, from: "struct TaskMainView: View {")
        let body = try code(mainView, from: "    var body: some View {", to: "\n    }\n")
        #expect(body.contains("composerView(decisionDockPresentation: dockPresentation)"))
        #expect(body.contains(".sheet(isPresented: $showContextPreview)"))

        // Any direct read here would subscribe the whole body, transcript and
        // all, to every keystroke again.
        for line in body.split(separator: "\n") where line.contains("composerDraft") {
            #expect(line.contains("TaskComposerTextReader(draft: composerDraft)"), "body reads the draft: \(line)")
        }
        #expect(!body.contains(".runtimeEligibilityPreview("), "the preview reads the text, so it belongs in a reader")
        #expect(!body.contains("contextPreviewRequest(messageText: composerDraft"))
    }

    @Test("The composer reads text, verdict and per-keystroke toolbar inputs inside readers")
    func composerReadsPerKeystrokeInputsInsideReaders() throws {
        let taskMainView = try source("Astra/Views/TaskMainView.swift")
        let composer = try code(taskMainView, from: "private func composerView(", to: "/// Smart paste")
        let firstReader = try #require(composer.range(of: "TaskComposerTextReader(draft: composerDraft)"))
        let beforeReaders = String(composer[..<firstReader.lowerBound])

        // Built once per `body` pass, outside the readers, with the
        // per-keystroke inputs left for `composing(...)`.
        #expect(beforeReaders.contains("let toolbar = ComposerToolbar("))
        #expect(beforeReaders.contains("hasInput: false,"))
        #expect(beforeReaders.contains("let eligibilityPreviewRequest = runtimeEligibilityPreviewRequestBuilder()"))
        #expect(!beforeReaders.contains("composerDraft."))
        #expect(!beforeReaders.contains("hasInput: hasInput"))
        #expect(!beforeReaders.contains("runtimeEligibilityPreviewRequest.signature"))

        let readers = String(composer[firstReader.lowerBound...])
        #expect(readers.contains("text: Bindable(composerDraft).text"))
        #expect(readers.contains(".onChange(of: text)"))
        #expect(readers.contains("toolbar.composing("))
        #expect(readers.contains(".runtimeEligibilityPreview("))
        #expect(readers.contains("state: Bindable(composerDraft).eligibilityPreviewState"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The non-comment lines of `text`, optionally between two markers.
    private func code(_ text: String, from start: String? = nil, to end: String? = nil) throws -> String {
        var slice = Substring(text)
        if let start {
            slice = slice[try #require(slice.range(of: start)).lowerBound...]
        }
        if let end, let endRange = slice.dropFirst(start?.count ?? 0).range(of: end) {
            slice = slice[..<endRange.lowerBound]
        }
        return slice
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }
}
