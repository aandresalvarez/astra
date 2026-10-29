import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Opt-in seed for real native Stop/continuation QA. No provider is executed
/// here and no execution receipt is fabricated; the app creates all attempts.
@Suite("Stop continuation app fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_STOP_QA_DIR"] != nil))
@MainActor
struct RuntimeStopContinuationAppFixtureTests {
    @Test("Seed isolated workspaces and untouched task drafts")
    func seed() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ASTRA_STOP_QA_DIR"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("default.store")))
        let context = container.mainContext
        try #require(try context.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        for (runtime, model) in [(AgentRuntimeID.antigravityCLI, "gemini-3.5-flash"), (.codexCLI, "gpt-6.1-sol")] {
            let path = root.deletingLastPathComponent().appendingPathComponent("Workspaces/\(runtime.rawValue)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try "ASTRA_STOP_QA_PRESERVED_566\n".write(to: path.appendingPathComponent("preserved.txt"), atomically: true, encoding: .utf8)
            let workspace = Workspace(name: "Stop QA \(runtime.rawValue)", primaryPath: path.path)
            context.insert(workspace)
            let task = AgentTask(title: "Stop and continue \(runtime.rawValue)",
                goal: "Isolated QA: preserve preserved.txt and follow the next human instruction.",
                workspace: workspace, tokenBudget: 80_000, model: model, runtime: runtime)
            task.status = .draft; task.runtimeExplicitlySelected = true
            task.maxTurns = 10
            task.executionRootPath = path.path
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
            context.insert(task)
            try context.save()
            _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            try TaskContextStateManager.refresh(task: task)
        }
        try context.save()
    }
}
