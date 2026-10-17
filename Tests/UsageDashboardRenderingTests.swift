import AppKit
import SwiftUI
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Usage dashboard rendering", .serialized)
@MainActor
struct UsageDashboardRenderingTests {
    @Test("A large history constructs only visible rows", arguments: [0, 2180])
    func offscreenRowsStayUnconstructed(count: Int) {
        let rows = (0..<count).map { index in
            UsageDashboardSummary.TaskRow(id: UUID(), title: "Chat \(index)", status: .completed,
                                          tokensUsed: index, costUSD: 0, budgetProgress: 0.1)
        }
        let summary = UsageDashboardSummary(tasks: rows, totalTokens: 0, totalCost: 0,
                                             completedCount: count, failedCount: 0, totalRuns: count)
        let measurement = measureUsageRendering(summary)
        if count == 0 {
            #expect(measurement.rows == 0)
        } else {
            #expect(measurement.rows > 0, "Exercise the actual rendered list")
            #expect(measurement.rows < 100, "Do not build every archived row during layout")
        }
    }
}

@MainActor
func measureUsageRendering(_ summary: UsageDashboardSummary) -> (rows: Int, elapsed: Duration) {
    // A plain counter observes row construction without adding render state or
    // exposing a production-only testing hook in the dashboard.
    final class Counter { var rows = 0 }
    let counter = Counter()
    let content = UsageDashboardContent(summary: summary, timeFilter: .constant(.allTime)) { task in
        counter.rows += 1
        return Text(task.title).frame(height: 40)
    }
    let host = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                          styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = host
    defer { window.contentView = nil; host.removeFromSuperview() }
    let elapsed = ContinuousClock().measure { host.layoutSubtreeIfNeeded() }
    return (counter.rows, elapsed)
}
