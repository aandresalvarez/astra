import Testing
import Foundation
import CoreGraphics
import ASTRAModels
@testable import ASTRA

/// Stress tests for pure layout math and search-overlay filtering: extreme and
/// non-finite geometry inputs (window transitions and split-view drags produce
/// strange numbers), exhaustive mode-derivation grids, and search filtering
/// over thousands of tasks. Layout math that lets NaN/∞ escape eventually
/// lands in a SwiftUI `frame(width:)`, which is a runtime error.
@Suite("UI stress: layout and search")
struct UIStressLayoutAndSearchTests {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static let saneWidths: [CGFloat] = [
        -1_000_000, -1, 0, 0.001, 1, 120, 480, 789, 790, 1_279, 1_280, 1_281,
        2_000, 5_000, 100_000, 10_000_000
    ]

    // MARK: - Sidebar mode derivation grid

    @Test("sidebar mode derivation is consistent across the full input grid")
    func sidebarModeGridConsistency() {
        for width in Self.saneWidths {
            for hasPanel in [false, true] {
                for wantsDock in [false, true] {
                    for overlayOpen in [false, true] {
                        let canDock = PanelLayoutGeometry.canDockSidebar(width: width, hasRightSidePanel: hasPanel)
                        let mode = PanelLayoutGeometry.sidebarMode(
                            width: width,
                            hasRightSidePanel: hasPanel,
                            wantsDock: wantsDock,
                            overlayOpen: overlayOpen
                        )
                        switch mode {
                        case .docked:
                            #expect(canDock && wantsDock,
                                    "docked at width \(width), panel \(hasPanel), wantsDock \(wantsDock)")
                        case .overlay:
                            #expect(!canDock && overlayOpen,
                                    "overlay at width \(width), panel \(hasPanel), overlayOpen \(overlayOpen)")
                        case .collapsed:
                            #expect(!(canDock && wantsDock) && !(!canDock && overlayOpen),
                                    "collapsed despite an active presentation request at width \(width)")
                        }
                    }
                }
            }
        }
    }

    @Test("dock thresholds are exact at their boundaries")
    func dockThresholdBoundaries() {
        #expect(PanelLayoutGeometry.canDockSidebar(width: 1_280, hasRightSidePanel: true))
        #expect(!PanelLayoutGeometry.canDockSidebar(width: 1_279.999, hasRightSidePanel: true))
        let bare = SidebarColumnLayout.expandedMinimumWidth + PanelLayoutGeometry.detailMinWidth
        #expect(PanelLayoutGeometry.canDockSidebar(width: bare, hasRightSidePanel: false))
        #expect(!PanelLayoutGeometry.canDockSidebar(width: bare - 0.001, hasRightSidePanel: false))
    }

    // MARK: - Clamp invariants under seeded extremes

    @Test("shelf clamping respects bounds and monotonicity across seeded extremes")
    func shelfClampInvariants() {
        var rng = SplitMix64(state: 0xA57A_0006)
        for step in 0..<5_000 {
            let shelfMin = CGFloat(200 + rng.next() % 200)
            let shelfMax = shelfMin + CGFloat(rng.next() % 600)
            let available = CGFloat(rng.next() % 4_000)
            let minimumDetail = CGFloat(300 + rng.next() % 400)
            let candidateA = CGFloat(Int64(bitPattern: rng.next()) % 5_000)
            let candidateB = candidateA + CGFloat(rng.next() % 500)

            let clampedA = PanelLayoutGeometry.clampedShelfWidth(
                candidateA,
                shelfMinWidth: shelfMin,
                shelfMaxWidth: shelfMax,
                minimumDetailWidth: minimumDetail,
                availableWidth: available
            )
            let clampedB = PanelLayoutGeometry.clampedShelfWidth(
                candidateB,
                shelfMinWidth: shelfMin,
                shelfMaxWidth: shelfMax,
                minimumDetailWidth: minimumDetail,
                availableWidth: available
            )

            #expect(clampedA >= shelfMin, "step \(step): clamp fell below the shelf minimum")
            #expect(clampedA <= max(shelfMin, shelfMax), "step \(step): clamp exceeded the shelf maximum")
            #expect(clampedA <= clampedB, "step \(step): clamp is not monotone in the candidate")
            #expect(PanelLayoutGeometry.detailWidthAfterShelf(
                availableWidth: available,
                clampedShelfWidth: clampedA
            ) >= 0)
        }
    }

    @Test("inspector widths stay inside their documented bounds for sane inputs")
    func inspectorWidthBounds() {
        for width in Self.saneWidths where width > 0 {
            let docked = PanelLayoutGeometry.inspectorDockedColumnWidth(for: width)
            #expect(docked >= PanelLayoutGeometry.inspectorMinColumnWidth)
            #expect(docked <= PanelLayoutGeometry.inspectorDefaultMaxColumnWidth)

            let overlay = PanelLayoutGeometry.inspectorOverlayWidth(for: width)
            #expect(overlay.isFinite && overlay > 0)

            let resizable = PanelLayoutGeometry.inspectorResizableColumnWidth(
                10_000,
                detailAreaWidth: width,
                minimumDetailWidth: PanelLayoutGeometry.detailMinWidth
            )
            #expect(resizable >= PanelLayoutGeometry.inspectorMinColumnWidth)
            #expect(resizable <= PanelLayoutGeometry.inspectorMaxColumnWidth)
        }
    }

    // MARK: - Non-finite geometry inputs

    @Test("layout math does not launder NaN into layout-bound values")
    func nanInputsDoNotEscape() {
        // A NaN width can only come from upstream layout pathology, but once
        // it enters, min/max ordering quirks carry it straight into a
        // frame(width:) somewhere downstream.
        let clamped = PanelLayoutGeometry.clampedShelfWidth(
            .nan,
            shelfMinWidth: 320,
            shelfMaxWidth: 560,
            minimumDetailWidth: 480,
            availableWidth: 1_400
        )
        let resizable = PanelLayoutGeometry.inspectorResizableColumnWidth(
            .nan,
            detailAreaWidth: 1_400,
            minimumDetailWidth: 480
        )
        withKnownIssue(
            "clampedShelfWidth and inspectorResizableColumnWidth clamp via min/max, and Swift's min/max return NaN when the NaN is the first argument — a NaN drag candidate escapes the clamp fully formed"
        ) {
            #expect(clamped.isFinite, "clampedShelfWidth returned \(clamped)")
            #expect(resizable.isFinite, "inspectorResizableColumnWidth returned \(resizable)")
        }
    }

    @Test("infinite widths produce either safe fallbacks or clamped values")
    func infiniteInputsAreContained() {
        // Positive infinity models a not-yet-measured geometry reading.
        #expect(PanelLayoutGeometry.inspectorDockedColumnWidth(for: .infinity).isFinite)
        #expect(PanelLayoutGeometry.inspectorResizableColumnWidth(
            .infinity,
            detailAreaWidth: 1_400,
            minimumDetailWidth: 480
        ).isFinite)
        #expect(PanelLayoutGeometry.detailWidthAfterShelf(
            availableWidth: .infinity,
            clampedShelfWidth: .infinity
        ) >= 0)
        #expect(!PanelLayoutGeometry.shouldDismissShelfResize(proposedWidth: .infinity, shelfMinWidth: 320))

        let preview = PanelLayoutGeometry.filesShelfPreviewWidth(shelfWidth: .infinity)
        withKnownIssue(
            "filesShelfPreviewWidth subtracts fixed chrome from the shelf width with no finiteness guard, so an infinite reading propagates into the preview pane width"
        ) {
            #expect(preview.isFinite, "filesShelfPreviewWidth returned \(preview)")
        }
    }

    // MARK: - Chat scroll metrics extremes

    @Test("parked always implies at-bottom across the value spectrum")
    func parkedImpliesAtBottom() {
        let readings: [CGFloat] = [
            -.infinity, -1_000_000, -5_000, -600, -40, -4.01, -4, -3.99, 0,
            1, 120, 600, 100_000, .infinity, .nan
        ]
        for reading in readings {
            let parked = ChatScrollMetrics.isParkedPastContent(bottomMinY: reading)
            let atBottom = ChatScrollMetrics.isAtBottom(bottomMinY: reading, viewportHeight: 600)
            if parked {
                #expect(atBottom, "reading \(reading): parked without reading as at-bottom")
            }
        }
        // Non-finite readings are "no measurement yet": never parked, treated
        // as at-bottom so the jump pill does not flash in.
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: .nan))
        #expect(ChatScrollMetrics.isAtBottom(bottomMinY: .nan, viewportHeight: 600))
        #expect(!ChatScrollMetrics.isParkedPastContent(bottomMinY: -.infinity))
    }

    // MARK: - Search overlay at scale

    private static func searchFixture() -> (tasks: [AgentTask], workspaces: [Workspace]) {
        var workspaces: [Workspace] = []
        for index in 0..<1_500 {
            workspaces.append(makeWorkspace(name: "workspace-\(index)-\(index.isMultiple(of: 3) ? "alpha" : "beta")"))
        }
        var tasks: [AgentTask] = []
        for index in 0..<6_000 {
            let task = makeTask(
                title: "Task \(index) \(index.isMultiple(of: 2) ? "deploy" : "review") run",
                goal: "Goal body \(index) mentioning service-\(index % 97) and café-\(index % 13)",
                workspace: workspaces[index % workspaces.count]
            )
            task.updatedAt = Date(timeIntervalSince1970: Double(index))
            tasks.append(task)
        }
        return (tasks, workspaces)
    }

    @Test("search filtering over 6k tasks respects caps and stays within budget")
    func searchFilteringAtScale() {
        let (tasks, workspaces) = Self.searchFixture()
        let queries = ["deploy", "review", "alpha", "service-13", "café", "zzz-no-match", "Task 59", "beta", "run", "workspace-1"]

        var totalResults = 0
        let elapsed = ContinuousClock().measure {
            for query in queries {
                let filtered = SearchPanelOverlayResults.filteredTasks(
                    searchText: query,
                    tasks: tasks,
                    workspaces: workspaces
                )
                #expect(filtered.count <= 12, "task results must stay capped for query \(query)")
                totalResults += filtered.count
            }
        }
        #expect(totalResults > 0)
        #expect(SearchPanelOverlayResults.recentTasks(tasks, workspaces: workspaces).count == 9)
        // Ten keystrokes' worth of filtering; locally ~1s. This is main-thread
        // work in production, so a blowup here is directly visible latency —
        // see the findings report for the per-keystroke numbers.
        #expect(elapsed < .seconds(12), "10 filter passes took \(elapsed) across \(tasks.count) tasks")
    }

    @Test("workspace search results are returned without any cap")
    func workspaceSearchResultsAreUncapped() {
        // Documents that filteredWorkspaces has no prefix() bound, unlike the
        // task variants: a broad query returns every matching workspace row.
        let (tasks, workspaces) = Self.searchFixture()
        let matches = SearchPanelOverlayResults.filteredWorkspaces(
            searchText: "workspace-",
            workspaces: workspaces,
            taskCount: tasks.count
        )
        #expect(matches.count == workspaces.count,
                "expected the unbounded result set; add a cap and update this expectation")
    }

    @Test("empty and whitespace queries fall back to bounded recents")
    func emptyQueriesStayBounded() {
        let (tasks, workspaces) = Self.searchFixture()
        for query in ["", "   ", "\n\t"] {
            #expect(SearchPanelOverlayResults.filteredTasks(
                searchText: query,
                tasks: tasks,
                workspaces: workspaces
            ).count <= 9)
            #expect(SearchPanelOverlayResults.filteredWorkspaces(
                searchText: query,
                workspaces: workspaces,
                taskCount: tasks.count
            ).isEmpty)
        }
    }
}
