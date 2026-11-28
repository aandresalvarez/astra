import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

// The context state keeps a task's last 30 artifact references and last 50
// changed files. It used to build and merge an entry for every artifact and
// folder file first, 45,000 on one task, and keep 30; it now builds only the
// entries that survive. These pin which ones survive and what they hold.
@Suite("Context state references")
@MainActor
struct TaskContextStateReferencesTests {
    @Test("The last 30 artifact keys survive, in first-appearance order, with every merge into them")
    func lastArtifactKeysSurviveWithTheirMerges() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-context-references-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let workspace = Workspace(name: "Many Artifacts", primaryPath: root)
        let task = AgentTask(title: "Many artifacts", goal: "Keep the newest references", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        func path(_ index: Int) -> String {
            (root as NSString).appendingPathComponent(String(format: "page-%02d.html", index))
        }
        var clock = 0.0
        func artifact(_ index: Int, version: Int) {
            clock += 1
            let row = Artifact(task: task, type: "html", path: path(index), version: version)
            row.createdAt = Date(timeIntervalSince1970: clock)
            context.insert(row)
        }
        for index in 0..<40 {
            try "<html>\(index)</html>".write(toFile: path(index), atomically: true, encoding: .utf8)
            artifact(index, version: 1)
        }
        // A later version of a key that first appeared too early to be kept,
        // and of one that is kept: only the second shows up, merged.
        artifact(5, version: 2)
        artifact(35, version: 2)

        TaskContextStateManager.refresh(task: task)
        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let artifacts = state.artifacts.filter { $0.path.hasPrefix(root) || $0.path.contains("page-") }
        #expect(artifacts.map(\.path) == (10..<40).map(path))
        let merged = try #require(artifacts.first { $0.path == path(35) })
        #expect(merged.version == 2)
        #expect(merged.sourcePointers.filter { $0.kind == "artifact" }.count == 2)
        #expect(!artifacts.contains { $0.path == path(5) })
        #expect(artifacts.allSatisfy { !$0.isStale })
    }
}
