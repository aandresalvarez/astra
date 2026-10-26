import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Repeatable disk-backed measurements. Retained fixtures contain synthetic
/// data only and can also be opened by the isolated development app.
@Suite("Context derivation performance", .serialized,
       .enabled(if: uiStressSuitesEnabled, "Set RUN_UI_STRESS=1 to run UI stress suites"))
@MainActor
struct TaskContextDerivationPerformanceTests {
    @Test("Context refresh at 2610 and 30000 events", arguments: [2610, 30000])
    func measureContextRefresh(eventCount: Int) async throws {
        let env = ProcessInfo.processInfo.environment
        let retained = env["ASTRA_CONTEXT_BENCHMARK_DIR"]
        let root = retained.map { URL(fileURLWithPath: $0).appendingPathComponent("events-\(eventCount)") }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("context-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if retained == nil { try? FileManager.default.removeItem(at: root) } }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))])
        container.mainContext.autosaveEnabled = false
        if try container.mainContext.fetchCount(FetchDescriptor<AgentTask>()) == 0 {
            try seed(container.mainContext, root: root, count: eventCount)
        }
        // A new context makes the first sample include the model faults.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let task = try #require(context.fetch(FetchDescriptor<AgentTask>()).first { $0.title == "History \(eventCount)" })
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        var samples: [Double] = []
        var expected: TaskContextState?
        for _ in 0..<13 {
            var timing: [TaskContextStateManager.RefreshTiming] = []
            await TaskContextStateManager.refreshLoadingOffMainActor(task: task) { timing.append($0) }
            samples.append(timing.reduce(0) { $0 + $1.applyMilliseconds })
            var state = try #require(TaskContextStateManager.load(taskFolder: folder))
            state.updatedAt = ""
            if let expected { #expect(state == expected) } else { expected = state }
        }
        let state = try #require(expected)
        #expect(state.startingRequest == "Build a synthetic history report")
        #expect(state.standingInstructions?.contains { $0.text.contains("Keep the CSV columns") } == true)
        #expect(state.filesChanged.contains { $0.hasSuffix("report-49.md") })
        let phase = env["ASTRA_CONTEXT_BENCHMARK_PHASE"] ?? "sample"
        let warm = Array(samples.dropFirst()).sorted()
        let record: [String: Any] = ["phase": phase, "events": eventCount, "cold_apply_ms": samples[0],
            "warm_median_ms": (warm[5] + warm[6]) / 2, "warm_p90_ms": warm[10], "samples_ms": samples]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        print("[context-benchmark] \(String(decoding: data, as: UTF8.self))")
        if retained != nil {
            try data.write(to: root.appendingPathComponent("\(phase)-timing.json"), options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let stateData = try encoder.encode(state)
            let baseline = root.appendingPathComponent("baseline-state.json")
            if phase == "baseline" { try stateData.write(to: baseline, options: .atomic) }
            else if FileManager.default.fileExists(atPath: baseline.path) {
                #expect(try Data(contentsOf: baseline) == stateData, "Derived state changed from the current-main baseline")
            }
        }
    }

    private func seed(_ context: ModelContext, root: URL, count: Int) throws {
        let workspace = Workspace(name: "Context QA \(count)", primaryPath: root.appendingPathComponent("Workspace").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        let task = AgentTask(title: "History \(count)", goal: "Build a synthetic history report", workspace: workspace)
        task.status = .completed
        task.tokenBudget = 50_000
        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = TaskRunStopReason.completed.rawValue
        run.startedAt = Date(timeIntervalSince1970: 1_000)
        run.completedAt = Date(timeIntervalSince1970: Double(count + 2_000))
        run.tokensUsed = 12_000
        task.tokensUsed = 12_000
        run.setOutput("Synthetic history ready. Inspect the files and local browser page.")
        var events: [TaskEvent] = []
        for index in 0..<count {
            let kind: String
            let payload: String
            switch index % 100 {
            case 0: kind = "user.message"; payload = index == 0 ? task.goal : "Keep the CSV columns in order for batch \(index)"
            case 1: kind = "agent.response"; payload = "Synthetic response \(index). Which report should be inspected?"
            case 2: kind = "error"; payload = "Synthetic historical diagnostic \(index)"
            default: kind = "tool.result"; payload = "Synthetic completed tool output \(index)"
            }
            let event = TaskEvent(task: task, type: kind, payload: payload, run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(index + 1_000))
            events.append(event)
        }
        task.events = events
        task.runs = [run]
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        for event in events { context.insert(event) }
        let short = AgentTask(title: "Independent short task", goal: "An independent synthetic task", workspace: workspace)
        short.status = .completed
        context.insert(short)
        try context.save()
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        for index in 0..<50 {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("report-\(index).md")
            try "# Synthetic report \(index)\n\nQA only.".write(to: url, atomically: true, encoding: .utf8)
        }
        let input = root.appendingPathComponent("Workspace/input.csv")
        try "name,value\nsynthetic,533\n".write(to: input, atomically: true, encoding: .utf8)
        task.inputs = [input.path]
        try "<!doctype html><title>ASTRA Context QA</title><h1>Local browser QA 533</h1><p>Synthetic content only.</p><a href='/second.html'>Next page</a>".write(to: root.appendingPathComponent("Workspace/index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>QA second page</title><h1>Navigation preserved</h1>".write(to: root.appendingPathComponent("Workspace/second.html"), atomically: true, encoding: .utf8)
        try context.save()
    }
}
