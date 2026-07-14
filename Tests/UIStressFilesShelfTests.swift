import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

/// Opt-in stress coverage for the Files shelf's 5,000-node index limit and
/// repeated search path. Budgets are intentionally generous enough for CI;
/// they catch accidental main-path quadratic work, not machine-to-machine noise.
@Suite(
    "UI stress: Files shelf",
    .enabled(if: uiStressSuitesEnabled, "Set RUN_UI_STRESS=1 to run the UI stress suites")
)
struct UIStressFilesShelfTests {
    @Test("Repeated docked shelf toggles never select a transcript-width animation")
    func largeTranscriptShelfTogglePolicy() {
        // The exact production repro had 270 conversation items. Exercise far
        // more toggle decisions here so a future animation-policy regression
        // is caught without relying on machine-specific render timing.
        for _ in 0..<10_000 {
            let opening = WorkspaceRightPanelTransitionMode.resolve(usesInspectorOverlay: false)
            let closing = WorkspaceRightPanelTransitionMode.resolve(usesInspectorOverlay: false)
            #expect(opening == .immediateDocked)
            #expect(closing == .immediateDocked)
            #expect(!opening.animatesPanel)
            #expect(!closing.animatesPanel)
        }
    }

    @Test("Five-thousand-node scan and repeated search stay within guardrail budgets")
    func largeTreeIndexAndSearchBudgets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for group in 0..<100 {
            let child = directory.appendingPathComponent("group-\(group)", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            for item in 0..<50 {
                FileManager.default.createFile(
                    atPath: child.appendingPathComponent("report-\(item).json").path,
                    contents: Data()
                )
            }
        }
        let root = WorkspaceFileRoot(
            id: "stress",
            kind: .primary,
            title: "Stress",
            path: directory.path,
            isDirectory: true
        )

        let scanStart = ContinuousClock.now
        let snapshot = WorkspaceFileIndexService.scanSync(roots: [root], maxNodes: 5_000)
        let scanDuration = ContinuousClock.now - scanStart
        #expect(snapshot.nodes.count == 5_000)
        #expect(snapshot.isTruncated)
        #expect(scanDuration < .seconds(15), "Large-tree scan took \(scanDuration)")

        let searchStart = ContinuousClock.now
        var resultCount = 0
        for query in ["report-1", "group-25", ".json", "no-match"] {
            resultCount += snapshot.nodes.lazy
                .filter { $0.normalizedSearchText.contains(query) }
                .count
        }
        let searchDuration = ContinuousClock.now - searchStart
        #expect(resultCount > 0)
        #expect(searchDuration < .seconds(2), "Repeated large-tree search took \(searchDuration)")
    }
}
