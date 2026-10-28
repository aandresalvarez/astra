import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Opt-in native QA: synthetic data, local files and harmless missing-CLI
/// repairs. The normal development and production stores are never read.
@Suite("Right rail app fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ASTRA_RAIL_QA_DIR"] != nil))
@MainActor
struct RightRailAppFixtureTests {
    @Test("Seed worktrees, imported owners, inputs, outputs and repair rows")
    func seed() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ASTRA_RAIL_QA_DIR"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("default.store")))
        let context = container.mainContext
        context.autosaveEnabled = false
        try #require(try context.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        let workspaces = root.deletingLastPathComponent().appendingPathComponent("Workspaces")
        let workspace = Workspace(name: "Rail QA", primaryPath: workspaces.appendingPathComponent("Rail QA").path,
            additionalPaths: ["Folder One", "Folder Two"].map { workspaces.appendingPathComponent($0).path })
        let docker = WorkspaceExecutionEnvironment(id: "rail-qa", kind: .dockerImage,
            displayName: "Rail QA container", image: "astra-rail-qa:latest")
        workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encode(docker)
        context.insert(workspace)
        let first = try task("ALPHA outputs", workspace: workspace, root: workspace.primaryPath,
            runs: 2, environment: .host, context: context)
        let second = try task("BRAVO inputs only", workspace: workspace,
            root: workspaces.appendingPathComponent("Rail Bravo").path, runs: 0, environment: docker, context: context)
        let imported = Workspace(name: "Rail Imported", primaryPath: workspaces.appendingPathComponent("Rail Imported").path)
        context.insert(imported)
        let copy = try task("IMPORTED outputs", workspace: imported, root: imported.primaryPath,
            runs: 7, environment: .host, context: context)
        copy.id = first.id; copy.updatedAt = first.updatedAt
        try context.save()

        for task in [first, second, copy] {
            let inputs = URL(fileURLWithPath: task.workspace!.primaryPath).appendingPathComponent("inputs")
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            let input = inputs.appendingPathComponent("initial-\(task.title).txt")
            let followup = inputs.appendingPathComponent("followup-\(task.title).md")
            try "Synthetic initial input".write(to: input, atomically: true, encoding: .utf8)
            try "Synthetic follow-up input".write(to: followup, atomically: true, encoding: .utf8)
            task.inputs = [input.path]
            let event = TaskEvent(task: task, type: "user.message", payload: "Inspect these synthetic files for \(task.title)")
            TaskEventInsertionService.insert(event, attachmentPaths: [followup.path], into: context)
            let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            if task !== second {
                let html = URL(fileURLWithPath: folder).appendingPathComponent("result.html")
                let markdown = URL(fileURLWithPath: folder).appendingPathComponent("report.md")
                try "<!doctype html><title>\(task.title)</title><h1>Rail output: \(task.title)</h1>".write(to: html, atomically: true, encoding: .utf8)
                try "# Rail output\n\(task.title) — synthetic QA only.".write(to: markdown, atomically: true, encoding: .utf8)
                let run = try #require(task.runs.first)
                run.appendHostFileChanges([.init(path: html.path, changeType: "Write"), .init(path: markdown.path, changeType: "Write")])
            }
            try TaskContextStateManager.refresh(task: task)
        }
        for index in 0..<1305 {
            let event = TaskEvent(task: first, type: "user.message", payload: "ALPHA history \(index): synthetic isolated data.")
            event.timestamp = Date(timeIntervalSince1970: 1_790_000_000 + Double(index))
            context.insert(event)
        }
        try seedCapabilities(root: root, workspace: workspace)
        try context.save()
        try workspace.id.uuidString.write(to: root.appendingPathComponent("workspace-id.txt"), atomically: true, encoding: .utf8)
    }

    private func task(_ title: String, workspace: Workspace, root: String, runs: Int,
                      environment: WorkspaceExecutionEnvironment, context: ModelContext) throws -> AgentTask {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let task = AgentTask(title: title, goal: "Synthetic UI QA; no provider execution requested.", workspace: workspace,
            tokenBudget: 25_000, model: "gpt-6.1-sol", runtime: .codexCLI)
        task.status = .completed; task.runtimeExplicitlySelected = true
        task.executionRootPath = root
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        task.completedAt = Date(); context.insert(task)
        for index in 0..<runs {
            let run = TaskRun(task: task)
            run.status = .completed; run.completedAt = Date()
            run.startedAt = Date().addingTimeInterval(Double(index - runs))
            run.setOutput("Synthetic completed run \(index) for \(title)")
            context.insert(run)
        }
        return task
    }

    private func seedCapabilities(root: URL, workspace: Workspace) throws {
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities"), publishesChanges: false)
        let approvals = CapabilityApprovalStore(directory: root.appendingPathComponent("CapabilityApprovals"), publishesChanges: false)
        let binaries = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        for name in ["Alpha", "Bravo", "Charlie"] {
            let id = "rail-qa-" + name.lowercased()
            let package = PluginPackage(id: id, name: "QA " + name, icon: "terminal",
                description: "Synthetic rail repair fixture; no account or credentials.", author: "ASTRA QA",
                category: "QA", tags: [], version: "1.0.0", skills: [], connectors: [], localTools: [], templates: [],
                prerequisites: [.init(binary: binaries.appendingPathComponent(id).path, livenessArgs: [], displayName: "QA " + name,
                    purpose: "Synthetic readiness signal", installHint: "Run `/usr/bin/printf QA_\(name.uppercased())_ONLY`.")])
            try library.install(package)
            let stored = try #require(library.installedPackage(id: id))
            let approval = try approvals.save(package: stored, status: .approved, approvedBy: "Isolated QA fixture")
            WorkspaceCapabilityActivation.updateActivation(for: id, in: workspace) { $0.isEnabled = true }
            WorkspaceCapabilityActivation.recordAccepted(pluginID: id, version: stored.version, digest: approval.sourceDigest, in: workspace)
        }
    }
}
