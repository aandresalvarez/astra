import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Opt-in native QA seed. Creates drafts only; the real app owns all runs,
/// provider launches, cancellation receipts and resource-release evidence.
@Suite("Provider identity app fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_PROVIDER_IDENTITY_QA_DIR"] != nil))
@MainActor
struct ProviderReservationAppFixtureTests {
    @Test("Seed isolated tasks for equivalent provider routes")
    func seed() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ASTRA_PROVIDER_IDENTITY_QA_DIR"]))
        let store = root.appendingPathComponent("Library/Application Support/AstraDev/Stores/g2/default.store")
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: store))
        let context = container.mainContext
        try #require(try context.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        for name in ["Alias reservation", "Legacy reservation", "Independent profile"] {
            let path = root.appendingPathComponent("Workspaces/" + name.replacingOccurrences(of: " ", with: "-"))
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try "QA_CONTROL_UNCHANGED\n".write(to: path.appendingPathComponent("control.txt"), atomically: true, encoding: .utf8)
            let workspace = Workspace(name: name, primaryPath: path.path)
            context.insert(workspace)
            let task = AgentTask(title: name, goal: "Reply exactly IDENTITY_GREEN.", workspace: workspace,
                tokenBudget: 50_000, model: "gemini-3.8-flash", runtime: .antigravityCLI)
            task.status = .draft; task.runtimeExplicitlySelected = true; task.maxTurns = 8
            task.executionRootPath = path.path
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
            context.insert(task)
            try context.save()
            _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            TaskContextStateManager.refresh(task: task)
        }
        try context.save()
    }
}
