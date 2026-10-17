import AppKit
import SwiftUI
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Usage dashboard rendering", .serialized)
@MainActor
struct UsageDashboardRenderingTests {
    @Test("Empty usage constructs no task rows")
    func emptyHistory() {
        #expect(measureUsageRendering(summary(count: 0)).rows == 0)
    }

    @Test("Ten times more history does not multiply native row construction")
    func archiveGrowthDoesNotExpandTheRenderGraph() {
        let smaller = measureUsageRendering(summary(count: 2180))
        let larger = measureUsageRendering(summary(count: 21_800))
        print("[usage-native-render] small_rows=\(smaller.rows) small_unique=\(smaller.uniqueRows) large_rows=\(larger.rows) large_unique=\(larger.uniqueRows)")
        #expect(smaller.uniqueRows > 0, "Exercise actual native rows")
        #expect(smaller.uniqueRows < 1090, "Do not materialize the archive")
        // AppKit can preflight rows beyond the viewport. Compare growth rather
        // than asserting a private framework's particular prefetch constant.
        #expect(larger.uniqueRows <= smaller.uniqueRows + 64)
        #expect(larger.rows <= smaller.rows * 2 + 64)
    }

    private func summary(count: Int) -> UsageDashboardSummary {
        let rows = (0..<count).map { index in
            UsageDashboardSummary.TaskRow(id: UUID(), title: "Chat \(index)", status: .completed,
                                          tokensUsed: index, costUSD: 0, budgetProgress: 0.1)
        }
        return UsageDashboardSummary(tasks: rows, totalTokens: 0, totalCost: 0,
                                     completedCount: count, failedCount: 0, totalRuns: count)
    }

}

@MainActor
func measureUsageRendering(_ summary: UsageDashboardSummary) -> (rows: Int, uniqueRows: Int, elapsed: Duration) {
    // A plain counter observes row construction without adding render state or
    // exposing a production-only testing hook in the dashboard.
    final class Counter { var rows = 0; var ids = Set<UUID>() }
    let counter = Counter()
    let content = UsageDashboardContent(summary: summary, timeFilter: .constant(.allTime)) { task in
        counter.rows += 1
        counter.ids.insert(task.id)
        return Text(task.title).frame(height: 40)
    }
    let host = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                          styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = host
    defer { window.contentView = nil; host.removeFromSuperview() }
    let elapsed = ContinuousClock().measure { host.layoutSubtreeIfNeeded() }
    return (counter.rows, counter.ids.count, elapsed)
}
