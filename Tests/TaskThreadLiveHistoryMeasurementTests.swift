import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import ASTRAModels
@testable import ASTRA

/// Run in a fresh test process on each revision. No app, workspace export,
/// provider or user store participates. The hosted eager selectable-text stack
/// isolates transcript row retention/layout; it is not the full TaskMainView.
@Suite("Live history measurement", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_MEASURE_LIVE_HISTORY"] == "1",
                "Set ASTRA_MEASURE_LIVE_HISTORY=1 for the isolated allocation probe"))
@MainActor
struct TaskThreadLiveHistoryMeasurementTests {
    @Test func selectedDiskBackedStream() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("history.store"))
        )
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = AgentTask(title: "Synthetic stream", goal: "Measure selected transcript")
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.status = .running
        context.insert(task)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .running
        run.setOutput("Synthetic active run")
        context.insert(run)
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        let host = NSHostingView(rootView: LiveHistoryMeasurementTranscript(vm: vm))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let baseline = MainThreadStallMonitor.memoryFootprint().footprintMegabytes
        var peak = baseline
        var maxEvents = 0
        var maxRows = 0
        // 6,000 independently persisted events, 600 incremental reads/builds
        // while this same view model and hosting view remain selected.
        for batch in 0..<600 {
            for offset in 0..<10 {
                let index = batch * 10 + offset
                let event = TaskEvent(task: task, type: "user.message",
                                      payload: "Synthetic message \(index): " + String(repeating: "transcript ", count: 24))
                event.timestamp = Date(timeIntervalSince1970: Double(index + 2))
                context.insert(event)
            }
            vm.refreshSnapshot(for: task)
            await vm.waitForPendingWorkForTesting()
            // Let Observation deliver changes, then force the same eager
            // layout as the production conversation ForEach.
            try await Task.sleep(for: .milliseconds(1))
            host.layoutSubtreeIfNeeded()
            maxEvents = max(maxEvents, vm.snapshot?.sortedEvents.count ?? 0)
            maxRows = max(maxRows, vm.snapshot?.conversationItems.count ?? 0)
            peak = max(peak, MainThreadStallMonitor.memoryFootprint().footprintMegabytes)
            if (batch + 1).isMultiple(of: 100) {
                print("[live-history] events=\((batch + 1) * 10) retained=\(vm.snapshot?.sortedEvents.count ?? 0) rows=\(vm.snapshot?.conversationItems.count ?? 0) footprint_mib=\(MainThreadStallMonitor.memoryFootprint().footprintMegabytes)")
            }
        }
        try await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded()
        let idle = MainThreadStallMonitor.memoryFootprint().footprintMegabytes
        let stored = try context.fetchCount(FetchDescriptor<TaskEvent>())
        #expect(stored == 6_000)
        print("[live-history] baseline_mib=\(baseline) sampled_peak_mib=\(peak) idle_mib=\(idle) max_retained_events=\(maxEvents) max_rendered_rows=\(maxRows) stored=\(stored)")
    }
}

private struct LiveHistoryMeasurementTranscript: View {
    let vm: TaskThreadViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(vm.snapshot?.conversationItems ?? []) { item in
                    Text(text(item)).font(Stanford.chatSection()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(width: 700, alignment: .leading)
        }.frame(width: 760, height: 700)
    }

    private func text(_ item: TaskConversationItem) -> String {
        switch item {
        case .userMessage(_, let text, _), .planUserMessage(let text, _),
             .planAssistantMessage(let text, _), .scheduleResult(let text, _),
             .systemInfo(let text, _, _), .recapResult(let text, _): text
        case .agentResponse(let run): run.output
        case .externalAction(let record): record.contextLine
        }
    }
}
