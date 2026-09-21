import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// `hasArtifact` runs at run finalize and classifies every artifact the task
/// owns. Each classification used to re-derive the task-folder and workspace
/// roots and resolve their symlinks — a `getattrlist` per path component, per
/// artifact, on the main actor, against a relationship that reached 13,295 rows
/// in production (`run_finalize_persist` p90 2.7 s, max 11.9 s).
///
/// The roots are now resolved once per call. These pin the classification
/// results that refactor had to preserve, including the symlink cases the
/// resolution exists for.
@Suite("Deliverable artifact scan")
@MainActor
struct TaskDeliverableArtifactScanCostTests {
    private func makeTask() throws -> (
        task: AgentTask,
        container: ModelContainer,
        root: URL,
        workspace: URL
    ) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-artifact-scan-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Scan", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let task = AgentTask(
            title: "Scan", goal: "Produce a report", workspace: workspace, runtime: .claudeCode
        )
        context.insert(task)
        try context.save()
        return (task, container, root, workspaceURL)
    }

    private func write(_ name: String, under folder: String) throws -> String {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "content".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("A deliverable written into the task folder is found")
    func deliverableInTaskFolderIsFound() throws {
        let environment = try makeTask()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let folder = try TaskWorkspaceAccess(task: environment.task).ensureTaskFolder()
        let path = try write("report.md", under: folder)

        let artifact = Artifact(task: environment.task, type: "markdown", path: path)
        environment.task.artifacts = [artifact]

        let run = TaskRun(task: environment.task)
        #expect(TaskDeliverableExpectation.hasArtifact(for: environment.task, run: run))
    }

    /// The resolution the hoisting must not lose: a task folder reached through
    /// a symlink still has to classify its contents as inside the folder.
    @Test("A task folder reached through a symlink still classifies its artifacts")
    func symlinkedTaskFolderStillClassifiesArtifacts() throws {
        let environment = try makeTask()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let folder = try TaskWorkspaceAccess(task: environment.task).ensureTaskFolder()
        _ = try write("report.md", under: folder)

        // Reach the same file through a symlinked parent.
        let alias = environment.root.appendingPathComponent("alias", isDirectory: true)
        try? FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: URL(fileURLWithPath: folder)
        )
        let aliasedPath = alias.appendingPathComponent("report.md").path

        let artifact = Artifact(task: environment.task, type: "markdown", path: aliasedPath)
        environment.task.artifacts = [artifact]

        let run = TaskRun(task: environment.task)
        #expect(TaskDeliverableExpectation.hasArtifact(for: environment.task, run: run))
    }

    /// A runtime diagnostic is not a deliverable, and the folder scan must not
    /// promote it into one.
    @Test("A runtime diagnostic file is not counted as a deliverable")
    func runtimeDiagnosticIsNotADeliverable() throws {
        let environment = try makeTask()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let folder = try TaskWorkspaceAccess(task: environment.task).ensureTaskFolder()
        let path = try write("jobs/job-1/stdout.log", under: folder)

        let artifact = Artifact(task: environment.task, type: "log", path: path)
        environment.task.artifacts = [artifact]

        let run = TaskRun(task: environment.task)
        #expect(!TaskDeliverableExpectation.hasArtifact(for: environment.task, run: run))
    }

    /// A stale row — the file is gone — is not evidence of a deliverable.
    @Test("An artifact whose file no longer exists is not a deliverable")
    func staleArtifactIsNotADeliverable() throws {
        let environment = try makeTask()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let folder = try TaskWorkspaceAccess(task: environment.task).ensureTaskFolder()
        let path = (folder as NSString).appendingPathComponent("never-written.md")

        let artifact = Artifact(task: environment.task, type: "markdown", path: path)
        environment.task.artifacts = [artifact]

        let run = TaskRun(task: environment.task)
        #expect(!TaskDeliverableExpectation.hasArtifact(for: environment.task, run: run))
    }
}
