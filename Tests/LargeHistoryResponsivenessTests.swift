import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Synthetic scale from the October reports; never opens a user's store.
@Suite("Large history responsiveness", .serialized,
       .enabled(if: uiStressSuitesEnabled, "Set RUN_UI_STRESS=1 to run UI stress suites"))
@MainActor
struct LargeHistoryResponsivenessTests {
    @Test("Usage remains responsive with 2180 chats and 5541 runs")
    func usageLayoutAtReportedScale() async throws {
        let retainedPath = ProcessInfo.processInfo.environment["ASTRA_STRESS_FIXTURE_DIR"]
        let root = retainedPath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("astra-large-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if retainedPath == nil { try? FileManager.default.removeItem(at: root) } }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))]
        )
        let context = container.mainContext
        context.autosaveEnabled = false
        try #require(context.fetchCount(FetchDescriptor<AgentTask>()) == 0, "Use a new fixture directory")
        let workspaces = (0..<22).map { index in
            let workspace = Workspace(name: String(format: "History %02d", index), primaryPath: root.appendingPathComponent("workspace-\(index)").path)
            context.insert(workspace)
            return workspace
        }
        var tasks: [AgentTask] = []
        for index in 0..<2180 {
            let task = AgentTask(title: String(format: "Chat %04d", index), goal: String(repeating: "Synthetic history. ", count: 100), workspace: workspaces[index % 22])
            task.status = .completed
            task.tokensUsed = 100 + index
            context.insert(task)
            tasks.append(task)
        }
        for index in 0..<5541 {
            let run = TaskRun(task: index < 24 ? tasks[0] : tasks[1 + ((index - 24) % (tasks.count - 1))])
            run.status = .completed
            run.completedAt = Date()
            run.appendOutput("## Answer \(index)\n\n" + String(repeating: "Synthetic output. ", count: 100))
            context.insert(run)
        }
        for index in 0..<794 {
            let event = TaskEvent(task: tasks[0], type: index.isMultiple(of: 20) ? "user.message" : "agent.response", payload: "Synthetic event \(index)")
            context.insert(event)
        }
        try context.save()
        let summary = try await UsageDashboardReader(container: container).read(timeFilter: .allTime)
        #expect(summary.tasks.count == 2180)
        #expect(summary.totalRuns == 5541)
        let measurement = measureUsageRendering(summary)
        print("[large-history] tasks=2180 runs=5541 workspaces=22 usage_layout=\(measurement.elapsed) rendered_rows=\(measurement.rows) unique_rows=\(measurement.uniqueRows) fixture=\(root.path)")
        #expect(measurement.rows > 0)
        #expect(measurement.uniqueRows < summary.tasks.count / 2)
        #expect(measurement.elapsed < .seconds(2))
        // Finalizing the largest chat must not inherit the former 33 s stall.
        let run = try #require(tasks[0].runs.first)
        let folder = try TaskWorkspaceAccess(task: tasks[0]).ensureTaskFolder()
        for previous in tasks[0].runs {
            #expect(SessionHistoryManager.recordTurn(taskFolder: folder, taskTitle: tasks[0].title,
                turnMessage: "Synthetic previous turn", output: String(repeating: "Synthetic transcript text. ", count: 4_000),
                tokensUsed: 0, costUSD: 0, fileChanges: [], runID: previous.id))
        }
        let started = ContinuousClock.now
        let sessionSaved = AgentRuntimeRunPersistence.recordSessionTurn(task: tasks[0], run: run, message: "Synthetic scale validation")
        let finalized = await AgentRuntimeRunPersistence.finalizeAndPersist(task: tasks[0], run: run,
            modelContext: context, phase: .run, autoExport: false)
        let finalizationElapsed = ContinuousClock.now - started
        print("[large-history] finalize=\(finalizationElapsed) events=794 turns=24 session_saved=\(sessionSaved) finalized=\(finalized)")
        #expect(sessionSaved)
        #expect(finalized)
        #expect(finalizationElapsed < .seconds(2))

    }
}
