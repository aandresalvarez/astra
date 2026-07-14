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

    @Test("Transcript rows stay grouped below the outer lazy stack")
    func transcriptRowsStayGroupedBelowOuterLazyStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let summaryStart = try #require(taskMainView.range(of: "private func summaryContent(decisionDockVisible: Bool)"))
        let summaryEnd = try #require(
            taskMainView[summaryStart.upperBound...].range(of: "private func recordTranscriptReadinessIfAvailable()")
        )
        let summarySource = String(taskMainView[summaryStart.lowerBound..<summaryEnd.lowerBound])

        #expect(summarySource.contains("LazyVStack(alignment: .leading, spacing: 10) {"))
        #expect(summarySource.contains("chatThreadContent(decisionDockVisible: decisionDockVisible)"))
        #expect(!summarySource.contains("ForEach(currentThreadSnapshot.conversationItems)"))
        #expect(taskMainView.contains("private func chatThreadContentBody(decisionDockVisible: Bool)"))
        #expect(taskMainView.contains("ForEach(currentThreadSnapshot.conversationItems) { item in"))
    }

    @Test("Task-wide decision policy is resolved once outside transcript rows")
    func taskWideDecisionPolicyIsResolvedOnceOutsideTranscriptRows() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let taskMainView = try source("Astra/Views/TaskMainView.swift", root: root)
        let agentBubbleStart = try #require(taskMainView.range(of: "private func chatAgentBubble("))
        let agentBubbleEnd = try #require(
            taskMainView[agentBubbleStart.upperBound...].range(of: "private func completedEmptyRunNotice()")
        )
        let agentBubbleSource = String(taskMainView[agentBubbleStart.lowerBound..<agentBubbleEnd.lowerBound])

        #expect(taskMainView.contains("let dockPresentation = taskDecisionDockPresentation"))
        #expect(taskMainView.components(separatedBy: "taskDecisionDockPresentation").count - 1 == 2)
        #expect(agentBubbleSource.contains("decisionDockVisible: Bool"))
        #expect(!agentBubbleSource.contains("taskDecisionDockPresentation"))
        #expect(!agentBubbleSource.contains("shouldShowTaskDecisionDock"))
    }

    private func source(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
