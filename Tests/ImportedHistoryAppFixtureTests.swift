import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Opt-in isolated native QA. The second copy is imported through the app UI.
@Suite("Imported history app fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_HISTORY_QA_DIR"] != nil))
@MainActor
struct ImportedHistoryAppFixtureTests {
    @Test("Seed a large original history and an importable divergent copy")
    func seed() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ASTRA_HISTORY_QA_DIR"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("default.store")))
        let context = container.mainContext
        context.autosaveEnabled = false
        try #require(try context.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        let workspace = Workspace(name: "History Original A", primaryPath: root.appendingPathComponent("Original A").path)
        let task = AgentTask(title: "History ALPHA", goal: "Synthetic ALPHA history. Answer only the requested marker.", workspace: workspace,
            tokenBudget: 25_000, model: "gpt-6.1-sol", runtime: .codexCLI)
        task.status = .completed; task.runtimeExplicitlySelected = true
        task.createdAt = Date().addingTimeInterval(-86_400)
        context.insert(workspace); context.insert(task)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        for offset in 0..<1305 {
            let event = TaskEvent(task: task, type: "user.message", payload: "ALPHA history message \(offset). Synthetic isolated data.")
            event.timestamp = task.createdAt.addingTimeInterval(Double(offset))
            context.insert(event)
        }
        task.updatedAt = task.createdAt.addingTimeInterval(1305)
        task.completedAt = task.updatedAt
        try context.save()
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try TaskContextStateManager.refresh(task: task)
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let importedRoot = root.appendingPathComponent("Imported B")
        try FileManager.default.createDirectory(at: importedRoot, withIntermediateDirectories: true)
        config.id = UUID().uuidString
        config.name = "History Imported B"; config.primaryPath = importedRoot.path
        config.tasks?[0].title = "History BRAVO"
        config.tasks?[0].goal = "Synthetic BRAVO history. Answer only the requested marker."
        config.tasks?[0].events = task.events.map {
            .init(id: $0.id.uuidString, type: $0.type, payload: $0.payload.replacingOccurrences(of: "ALPHA", with: "BRAVO"),
                timestamp: $0.timestamp, category: $0.category)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: importedRoot.appendingPathComponent(".astra-workspace.json"))
        try String(task.id.uuidString).write(to: root.appendingPathComponent("synthetic-task-id.txt"), atomically: true, encoding: .utf8)
    }
}
