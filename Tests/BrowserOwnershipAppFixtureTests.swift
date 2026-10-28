import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Opt-in native QA fixture. All data and files are synthetic; no profile or
/// credentials are copied from a user's normal ASTRA installation.
@Suite("Browser ownership app fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_BROWSER_QA_DIR"] != nil))
@MainActor
struct BrowserOwnershipAppFixtureTests {
    @Test("Seed two imported owners and an independent task")
    func seed() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ASTRA_BROWSER_QA_DIR"])
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("default.store")))
        let context = container.mainContext
        context.autosaveEnabled = false
        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        let taskID = UUID()
        for name in ["Original A", "Imported B", "Independent C"] {
            let workspace = Workspace(name: "Browser QA " + name, primaryPath: root.appendingPathComponent(name).path)
            try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
            let task = AgentTask(title: name, goal: "Inspect the synthetic local Browser page for " + name, workspace: workspace)
            if name != "Independent C" { task.id = taskID }
            task.status = .completed
            task.runtimeID = "codex_cli"
            task.model = "gpt-5.4"
            task.tokenBudget = 25_000
            context.insert(workspace); context.insert(task)
            try context.save()
            let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            let html = "<!doctype html><title>\(name)</title><h1>Browser owner \(name)</h1><p>Synthetic isolated QA.</p><input id='value' value='\(name)'/><button onclick=\"document.querySelector('#value').value='clicked \(name)'\">Mark \(name)</button>"
            try html.write(to: URL(fileURLWithPath: folder).appendingPathComponent("owner.html"), atomically: true, encoding: .utf8)
            try html.write(to: root.appendingPathComponent(name + ".html"), atomically: true, encoding: .utf8)
            try TaskContextStateManager.refresh(task: task)
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == 3)
    }
}
