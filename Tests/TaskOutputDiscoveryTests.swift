import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private func makeTaskOutputDiscoveryContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task output discovery")
@MainActor
struct TaskOutputDiscoveryTests {
    // reads the TaskGeneratedFileQuerySeam — see RuntimeSeamRegistration.swift.
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll()

    @Test("run-scoped workspace scan finds unrecorded workspace-root artifacts")
    func runScopedWorkspaceScanFindsUnrecordedWorkspaceRootArtifacts() throws {
        let fixture = try makeFixture(goal: "Create ./test_results.txt")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let results = (fixture.root as NSString).appendingPathComponent("test_results.txt")
        try "8 passed, 0 failed".write(toFile: results, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.run.startedAt.addingTimeInterval(10)],
            ofItemAtPath: results
        )

        let files = TaskOutputDiscovery.files(for: fixture.task, run: fixture.run)

        #expect(files.contains { $0.path == results && $0.relativePath == "test_results.txt" })
    }

    @Test("run-scoped workspace scan ignores stale workspace files")
    func runScopedWorkspaceScanIgnoresStaleWorkspaceFiles() throws {
        let fixture = try makeFixture(goal: "Create ./fresh.txt")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let stale = (fixture.root as NSString).appendingPathComponent("stale.txt")
        try "old".write(toFile: stale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.run.startedAt.addingTimeInterval(-30)],
            ofItemAtPath: stale
        )

        let files = TaskOutputDiscovery.files(for: fixture.task, run: fixture.run)

        #expect(!files.contains { $0.path == stale })
    }

    @Test("run file changes ignore workspace runtime diagnostics")
    func runFileChangesIgnoreWorkspaceRuntimeDiagnostics() throws {
        let fixture = try makeFixture(goal: "Create ./summary.md")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let cacheURL = URL(fileURLWithPath: fixture.root)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: cacheURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.run.startedAt.addingTimeInterval(-30)],
            ofItemAtPath: cacheURL.path
        )
        fixture.run.appendFileChange(StoredFileChange(
            path: cacheURL.path,
            changeType: StoredFileChangeKind.write.rawValue,
            content: "{}",
            oldString: nil,
            newString: nil,
            timestamp: fixture.run.startedAt.addingTimeInterval(5)
        ))

        let summary = try writeWorkspaceFile("summary.md", contents: "# Summary\n", fixture: fixture)
        fixture.run.appendFileChange(StoredFileChange(
            path: summary,
            changeType: StoredFileChangeKind.write.rawValue,
            content: "# Summary\n",
            oldString: nil,
            newString: nil,
            timestamp: fixture.run.startedAt.addingTimeInterval(5)
        ))

        let files = TaskOutputDiscovery.files(for: fixture.task, run: fixture.run)

        #expect(files.contains { $0.path == summary && $0.relativePath == "summary.md" })
        #expect(!files.contains { $0.path == cacheURL.path || $0.relativePath == "cache/projects.json" })
    }

    @Test("workspace scan ignores runtime diagnostics")
    func workspaceScanIgnoresRuntimeDiagnostics() throws {
        let fixture = try makeFixture(goal: "Create ./report.md")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let cacheURL = URL(fileURLWithPath: fixture.root)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: cacheURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.run.startedAt.addingTimeInterval(5)],
            ofItemAtPath: cacheURL.path
        )

        let report = try writeWorkspaceFile("report.md", contents: "# Report\n", fixture: fixture)
        let files = TaskOutputWorkspaceDiscovery.filesChangedDuringRun(
            workspacePath: fixture.root,
            taskFolder: TaskWorkspaceAccess(task: fixture.task).taskFolder,
            run: fixture.run
        )

        #expect(files.map(\.path) == [report])
    }

    @Test("task-folder scan ignores runtime and job diagnostics")
    func taskFolderScanIgnoresRuntimeAndJobDiagnostics() throws {
        let fixture = try makeFixture(goal: "Create task docs")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let taskFolder = try TaskWorkspaceAccess(task: fixture.task).ensureTaskFolder()
        let folderURL = URL(fileURLWithPath: taskFolder, isDirectory: true)
        let deliverables = ["plan.md", "guidelines.md", "status_report.md", "pr_review_analysis.md", "pr_description.md"]
        for name in deliverables {
            try "# \(name)".write(to: folderURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let runtimeConfig = folderURL.appendingPathComponent(".runtime/docker-client/client-1/config.json")
        let jobFolder = folderURL.appendingPathComponent("jobs/job-1", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobFolder, withIntermediateDirectories: true)
        try "{}".write(to: runtimeConfig, atomically: true, encoding: .utf8)
        for name in ["command.sh", "heartbeat.json", "job.json", "pid", "result.json", "stdout.log", "stderr.log", "timeout"] {
            try "diagnostic".write(to: jobFolder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let files = TaskOutputDiscovery.files(for: fixture.task)
        let relativePaths = Set(files.map(\.relativePath))

        for name in deliverables {
            #expect(relativePaths.contains(name))
        }
        #expect(!relativePaths.contains(".runtime/docker-client/client-1/config.json"))
        #expect(!relativePaths.contains("jobs/job-1/command.sh"))
        #expect(!relativePaths.contains("jobs/job-1/stdout.log"))
    }

    @Test("workspace scan includes artifacts at shared depth boundary")
    func workspaceScanIncludesArtifactsAtSharedDepthBoundary() throws {
        let fixture = try makeFixture(goal: "Create ./a/b/c/d/e.txt")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let relativePath = "a/b/c/d/e.txt"
        let artifactPath = (fixture.root as NSString).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: artifactPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "depth boundary\n".write(toFile: artifactPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.run.startedAt.addingTimeInterval(5)],
            ofItemAtPath: artifactPath
        )

        let files = TaskOutputWorkspaceDiscovery.filesChangedDuringRun(
            workspacePath: fixture.root,
            taskFolder: TaskWorkspaceAccess(task: fixture.task).taskFolder,
            run: fixture.run
        )

        #expect(files.contains { $0.path == artifactPath && $0.relativePath == relativePath })
    }

    @Test("deliverable verification finds unrecorded workspace-root required file")
    func deliverableVerificationFindsUnrecordedWorkspaceRootRequiredFile() async throws {
        let fixture = try makeFixture(goal: """
        Create these deliverables in the current working directory:
        - ./regex.js
        - ./test.js
        - ./test_results.txt
        """)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let regex = try writeWorkspaceFile("regex.js", contents: "export function extractEmails() { return [] }\n", fixture: fixture)
        let test = try writeWorkspaceFile("test.js", contents: "console.log('ok')\n", fixture: fixture)
        _ = try writeWorkspaceFile("test_results.txt", contents: "8 passed, 0 failed\n", fixture: fixture)

        for path in [regex, test] {
            fixture.run.appendFileChange(StoredFileChange(
                path: path,
                changeType: StoredFileChangeKind.write.rawValue,
                content: try String(contentsOfFile: path, encoding: .utf8),
                oldString: nil,
                newString: nil,
                timestamp: fixture.run.startedAt.addingTimeInterval(5)
            ))
        }

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: .init(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(result.canComplete)
        #expect(result.checks.contains { check in
            check.id == "artifact.required_files" && check.status == .passed
        })
        #expect(result.evidencePaths.contains { $0.hasSuffix("test_results.txt") })
    }

    private func writeWorkspaceFile(
        _ name: String,
        contents: String,
        fixture: (
            root: String,
            container: ModelContainer,
            task: AgentTask,
            run: TaskRun
        )
    ) throws -> String {
        let path = (fixture.root as NSString).appendingPathComponent(name)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.run.startedAt.addingTimeInterval(5)],
            ofItemAtPath: path
        )
        return path
    }

    private func makeFixture(goal: String) throws -> (
        root: String,
        container: ModelContainer,
        task: AgentTask,
        run: TaskRun
    ) {
        let root = try temporaryRoot()
        let container = try makeTaskOutputDiscoveryContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Task Output Discovery", primaryPath: root)
        let task = AgentTask(title: "Task Output Discovery", goal: goal, workspace: workspace)
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-60)
        run.completedAt = Date().addingTimeInterval(-5)
        run.status = .completed
        run.stopReason = "completed"
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        return (root, container, task, run)
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-task-output-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
