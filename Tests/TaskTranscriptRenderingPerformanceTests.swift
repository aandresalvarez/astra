import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ASTRA

/// Exercises the work after a snapshot lands, which the snapshot benchmarks
/// do not include. Uses synthetic text only; never opens an application store.
@Suite("Task transcript rendering performance", .serialized,
       .enabled(if: uiStressSuitesEnabled, "Set RUN_UI_STRESS=1 to run UI stress suites"))
@MainActor
struct TaskTranscriptRenderingPerformanceTests {
    private func document(sections: Int) -> String {
        (0..<sections).map { index in
            """
            ## Finding \(index)
            Review `source\(index).swift` and [the evidence](https://example.com/\(index)).

            - Verify the result for section \(index).
            - Retain the existing approval boundary.

            | Check | Result |
            | --- | --- |
            | Case \(index) | Passed |
            """
        }.joined(separator: "\n\n")
    }

    @Test("Unchanged markdown view construction reuses prepared text")
    func repeatedConstruction() {
        let text = document(sections: 150)
        let clock = ContinuousClock()
        let cold = clock.measure { _ = MarkdownTextView(text: text) }
        let warm = clock.measure {
            for _ in 0..<50 { _ = MarkdownTextView(text: text) }
        }
        print("[transcript-render] bytes=\(text.utf8.count) cold=\(cold) warm_50=\(warm)")
        // Baseline was 523 ms; leave ample headroom over the sub-ms cache hit.
        #expect(warm < .milliseconds(50), "Unchanged construction must not normalize the source again")
    }

    @Test("Suggested actions remain bounded on long lists without a suggestion heading")
    func suggestedActionsLongList() {
        let blocks = (0..<3_000).map { index in
            MarkdownTextView.MarkdownBlock(kind: .listItem(depth: 0, marker: "•"),
                                          content: "Verify item \(index)")
        }
        let clock = ContinuousClock()
        var actions: [MarkdownTextView.SuggestedNextAction] = []
        let elapsed = clock.measure { actions = MarkdownTextView.suggestedNextActions(in: blocks) }
        print("[transcript-render] suggestion_blocks=\(blocks.count) elapsed=\(elapsed)")
        #expect(actions.isEmpty)
        // Baseline's backward scans took 252 ms; the forward pass is ~1 ms.
        #expect(elapsed < .milliseconds(100))
    }

    @Test("A 69-item transcript with four markdown answers can finish layout")
    func completedTranscriptLayout() {
        let answers = (0..<4).map { index in "# Answer \(index)\n\n" + document(sections: 5) }
        let root = ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<69, id: \.self) { index in
                    if index < answers.count {
                        MarkdownTextView(text: answers[index])
                    } else {
                        Text("Task status event \(index)")
                            .font(Stanford.chatSection())
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(width: 700, alignment: .leading)
        }
        .frame(width: 760, height: 700)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer {
            host.removeFromSuperview()
            window.contentView = nil
        }
        let elapsed = ContinuousClock().measure { host.layoutSubtreeIfNeeded() }
        print("[transcript-render] items=69 answers=4 layout=\(elapsed)")
        #expect(elapsed < .seconds(2))
    }
}
