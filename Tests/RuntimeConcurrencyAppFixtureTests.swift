import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Opt-in native QA setup only. The application creates every execution,
/// session and stop receipt; this fixture never launches a provider.
@Suite("Same account concurrency app fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_CONCURRENCY_QA_DIR"] != nil))
@MainActor
struct RuntimeConcurrencyAppFixtureTests {
    @Test("Seed two untouched Codex tasks with independent workspaces")
    func seed() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["ASTRA_CONCURRENCY_QA_DIR"]))
        let support = try #require(AppChannelStoragePaths.developmentApplicationSupportOverride(
            for: .development, environment: environment))
        let store = support.appendingPathComponent("Stores/g2/default.store")
        try #require(!FileManager.default.fileExists(atPath: store.path))
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: store))
        let context = container.mainContext
        for name in ["A", "B"] {
            let workspaceURL = root.appendingPathComponent("Workspaces/" + name)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try """
                import json
                import os
                import time
                from pathlib import Path

                progress = Path(__file__).with_name("progress.jsonl")
                with progress.open("a", buffering=1) as output:
                    for step in range(60):
                        output.write(json.dumps({"step": step, "pid": os.getpid(), "time": time.time()}) + "\\n")
                        time.sleep(1)
                """.write(to: workspaceURL.appendingPathComponent("pulse.py"), atomically: true, encoding: .utf8)
            let workspace = Workspace(name: "Concurrency QA " + name, primaryPath: workspaceURL.path)
            context.insert(workspace)
            let task = AgentTask(title: "Same account " + name,
                goal: "In this isolated QA workspace, run /usr/bin/python3 pulse.py exactly once and wait for it to finish. Do not edit the script or launch detached work. Then read progress.jsonl and report the number of recorded steps. Do not access another workspace.",
                workspace: workspace, tokenBudget: 60_000, model: "gpt-6.1-sol", runtime: .codexCLI)
            task.status = .draft
            task.runtimeExplicitlySelected = true
            task.maxTurns = 6
            task.executionRootPath = workspaceURL.path
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
            context.insert(task)
            try context.save()
            _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            TaskContextStateManager.refresh(task: task)
        }
        try context.save()
    }
}

/// Run only with the isolated QA app closed. Imports its real Ask history;
/// never edits the source execution receipt or manufactures a stop proof.
@Suite("Native session import app fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_CONCURRENCY_IMPORT_QA_DIR"] != nil))
@MainActor
struct RuntimeConcurrencyImportAppFixtureTests {
    @Test("Import the uncertain real-provider QA history into an independent workspace")
    func importHistory() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["ASTRA_CONCURRENCY_IMPORT_QA_DIR"]))
        let support = try #require(AppChannelStoragePaths.developmentApplicationSupportOverride(
            for: .development, environment: environment))
        let store = support.appendingPathComponent("Stores/g2/default.store")
        try #require(FileManager.default.fileExists(atPath: store.path))
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: store))
        let context = container.mainContext
        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        try #require(tasks.allSatisfy { !$0.runs.contains { $0.status == .running } })
        let source = try #require(tasks.first { $0.title.hasPrefix("QA B:") && $0.resolvedRuntimeID == .codexCLI })
        let workspace = try #require(source.workspace)
        try #require(URL(fileURLWithPath: workspace.primaryPath).resolvingSymlinksInPath().path
            == root.appendingPathComponent("Workspaces/B").resolvingSymlinksInPath().path)
        let owner = try #require(try RuntimeExecutionOwner.existing(task: source, context: context))
        try #require(owner.state == .unverified && owner.resourcesReleased != true)
        try #require(owner.providerProcess?.presence == .absent)
        let copyName = environment["ASTRA_CONCURRENCY_IMPORT_QA_COPY"] ?? "imported-b"
        try #require(copyName.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil)
        let path = root.appendingPathComponent("Workspaces/" + copyName)
        try #require(!FileManager.default.fileExists(atPath: path.path))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        for name in ["pulse.py", "progress.jsonl"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent("Workspaces/B/" + name),
                to: path.appendingPathComponent(name))
        }
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.id = UUID().uuidString
        config.name = "Concurrency QA " + copyName
        config.primaryPath = path.path
        config.tasks = config.tasks?.filter { $0.id == source.id.uuidString }
        try #require(config.tasks?.count == 1)
        config.tasks?[0].executionRootPath = nil
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: context)
        let copy = try #require(imported.tasks.first)
        copy.title = "Session conflict " + copyName
        try #require(copy.sessionId == source.sessionId && copy.id == source.id)
        try context.save()
        _ = try TaskWorkspaceAccess(task: copy).ensureTaskFolder()
        TaskContextStateManager.refresh(task: copy)
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: imported.id)
        let data = try JSONEncoder().encode(["taskID": copy.id.uuidString, "workspaceID": imported.id.uuidString])
        try data.write(to: root.appendingPathComponent("imported-b-task.json"))
        #expect(try RuntimeExecutionOwner.existing(task: source, context: context) == owner)
    }
}
