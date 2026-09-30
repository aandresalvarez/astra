import AppKit
import SwiftData
import SwiftUI
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Sidebar task activity liveness")
@MainActor
struct SidebarTaskActivityLivenessTests {
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<600 {
            if condition() { return }
            _ = await MainActor.run {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func spinnerCount(in view: NSView) -> Int {
        let own = (view as? NSProgressIndicator)?.style == .spinning ? 1 : 0
        return own + view.subviews.reduce(0) { $0 + spinnerCount(in: $1) }
    }

    private func host(_ row: SidebarThreadRow) -> (NSHostingView<some View>, NSWindow) {
        let host = NSHostingView(rootView: row.frame(width: 280, height: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("A retained row removes its native spinner when the request finishes",
          arguments: [TaskTurnRequestState.completed, .failed, .cancelled])
    func terminalRequestClearsSpinner(terminalState: TaskTurnRequestState) async throws {
        let container = try container()
        let context = container.mainContext
        let task = AgentTask(title: "Finished task", goal: "sidebar activity")
        task.status = .running
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, state: .running)
        context.insert(request)
        try context.save()

        // Keep the original row and request array throughout. There is no
        // parent query or replacement root view to rescue a stale row.
        let row = SidebarThreadRow(task: task, isSelected: true, isHovered: false, requests: [request])
        let (host, window) = host(row)
        defer { window.contentView = nil; window.orderOut(nil) }
        await settle { spinnerCount(in: host) == 1 }
        #expect(spinnerCount(in: host) == 1, "The row must first render a real native spinner.")

        // Production completed the task before finishing the request.
        task.status = terminalState == .failed ? .failed : terminalState == .cancelled ? .cancelled : .completed
        try context.save()
        #expect(row.activity.kind == .running, "A live request still owns activity during finalization.")
        request.state = terminalState
        request.terminalAt = Date()
        try context.save()
        await settle { spinnerCount(in: host) == 0 }
        #expect(row.activity.kind == .idle)
        #expect(spinnerCount(in: host) == 0, "The completed request left a native spinner in the retained row.")
    }

    @Test("A retained row continues to show a genuine running follow-up")
    func followUpRemainsLive() async throws {
        let container = try container()
        let context = container.mainContext
        let task = AgentTask(title: "Follow-up task", goal: "sidebar activity")
        task.status = .completed
        context.insert(task)
        let finished = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, state: .completed)
        let followUp = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, state: .waitingForWorker)
        context.insert(finished)
        context.insert(followUp)
        try context.save()

        let row = SidebarThreadRow(task: task, isSelected: true, isHovered: false, requests: [finished, followUp])
        let (host, window) = host(row)
        defer { window.contentView = nil; window.orderOut(nil) }
        #expect(row.activity.kind == .waitingForWorker)
        #expect(spinnerCount(in: host) == 0)

        // A completed task status alone must not hide an executing follow-up.
        followUp.state = .running
        try context.save()
        await settle { spinnerCount(in: host) == 1 }
        #expect(row.activity.kind == .running)
        #expect(spinnerCount(in: host) == 1)

        followUp.state = .completed
        followUp.terminalAt = Date()
        try context.save()
        await settle { spinnerCount(in: host) == 0 }
        #expect(row.activity.kind == .idle)
        #expect(spinnerCount(in: host) == 0)
    }
}
