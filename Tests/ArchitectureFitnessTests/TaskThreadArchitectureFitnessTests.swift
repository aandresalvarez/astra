import Foundation
import Testing

@Suite("Task thread architecture fitness")
struct TaskThreadArchitectureFitnessTests {
    @Test("Production reads stay storage paged and event driven")
    func productionReadsStayStoragePagedAndEventDriven() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let planTelemetry = try source("Astra/Views/TaskMainViewPerformanceTelemetry.swift", root: root)
        let historyReader = try source("Astra/Services/Tasks/TaskThreadHistoryReader.swift", root: root)
        let viewModel = try source("Astra/Views/TaskThreadViewModel.swift", root: root)

        #expect(!taskMainView.contains("pollSnapshotTriggerWhileLive"))
        #expect(!taskMainView.contains("livePollIntervalNanoseconds"))
        #expect(!taskMainView.contains("task.events.count"))
        #expect(!taskMainView.contains("task.runs.count"))
        #expect(!planTelemetry.contains("task.events"))
        #expect(!planTelemetry.contains("task.runs"))
        #expect(taskMainView.contains("requestSnapshotRefresh(for: task)"))
        #expect(taskMainView.contains("modelContext: modelContext"))
        #expect(historyReader.contains("descriptor.fetchLimit = limit + 1"))
        #expect(!viewModel.contains("loadedHistoryRuns.values.min"))
        #expect(!viewModel.contains("loadedHistoryEvents.values.min"))
    }

    private func source(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
