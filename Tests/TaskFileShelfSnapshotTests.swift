import Testing
import AppKit
import SwiftUI
import Darwin
@testable import ASTRA
import ASTRACore

extension TaskThreadSnapshotTests {
    @Test("Generated file scan excludes internal task files")
    func generatedFileScanExcludesInternalFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-generated-files-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        let outputs = root.appendingPathComponent("outputs")
        let runtimeBin = root.appendingPathComponent(".runtime-bin")
        let dockerClient = root
            .appendingPathComponent(".runtime", isDirectory: true)
            .appendingPathComponent("docker-client", isDirectory: true)
            .appendingPathComponent("client-1", isDirectory: true)
        let job = root
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent("job-1", isDirectory: true)

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dockerClient, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "# Plan".write(to: root.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try "# Guidelines".write(to: root.appendingPathComponent("guidelines.md"), atomically: true, encoding: .utf8)
        try "internal".write(to: root.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)
        try "output".write(to: outputs.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        try "shim".write(to: runtimeBin.appendingPathComponent("astra-browser"), atomically: true, encoding: .utf8)
        try "{}".write(to: dockerClient.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        for name in ["command.sh", "heartbeat.json", "job.json", "pid", "result.json", "stdout.log", "stderr.log", "timeout"] {
            try "diagnostic".write(to: job.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "nested".write(to: nested.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Set(TaskGeneratedFiles.files(in: root.path))

        #expect(paths.contains(root.appendingPathComponent("visible.txt").path))
        #expect(paths.contains(root.appendingPathComponent("plan.md").path))
        #expect(paths.contains(root.appendingPathComponent("guidelines.md").path))
        #expect(paths.contains(nested.appendingPathComponent("session_history.md").path))
        #expect(!paths.contains(root.appendingPathComponent("session_history.md").path))
        #expect(!paths.contains(outputs.appendingPathComponent("result.txt").path))
        #expect(!paths.contains(runtimeBin.appendingPathComponent("astra-browser").path))
        #expect(!paths.contains(dockerClient.appendingPathComponent("config.json").path))
        #expect(!paths.contains(job.appendingPathComponent("stdout.log").path))
    }

    @Test("Generated file scan can run asynchronously")
    func generatedFileScanRunsAsync() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-generated-files-async-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = await TaskGeneratedFiles.filesAsync(in: root.path)

        #expect(paths == [root.appendingPathComponent("visible.txt").path])
    }

    @Test("Task file index scans task folder with shelf destinations")
    func taskFileIndexScansTaskFolderWithShelfDestinations() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-file-index-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".runtime-bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".runtime/docker-client/client-1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("jobs/job-1"), withIntermediateDirectories: true)
        try "# Summary".write(to: root.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "<h1>Preview</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "select 1".write(to: root.appendingPathComponent("query.sql"), atomically: true, encoding: .utf8)
        try "shim".write(to: root.appendingPathComponent(".runtime-bin/astra-browser"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent(".runtime/docker-client/client-1/config.json"), atomically: true, encoding: .utf8)
        try "out".write(to: root.appendingPathComponent("jobs/job-1/stdout.log"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = TaskFileIndex.scanTaskFolder(root.path)
        let destinations = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.destination) })

        #expect(destinations["summary.md"] == .files)
        #expect(destinations["index.html"] == .browser)
        #expect(destinations["query.sql"] == .query)
        #expect(!files.contains { $0.path.hasSuffix(".runtime-bin/astra-browser") })
        #expect(!files.contains { $0.path.hasSuffix(".runtime/docker-client/client-1/config.json") })
        #expect(!files.contains { $0.path.hasSuffix("jobs/job-1/stdout.log") })
    }

    @Test("Task file header count excludes task-folder diagnostics")
    func taskFileHeaderCountExcludesTaskFolderDiagnostics() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-file-header-\(UUID().uuidString)")
        let report = root.appendingPathComponent("status_report.md")
        let config = root.appendingPathComponent(".runtime/docker-client/client-1/config.json")
        let stdout = root.appendingPathComponent("jobs/job-1/stdout.log")

        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stdout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Status".write(to: report, atomically: true, encoding: .utf8)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        try "log".write(to: stdout, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let run = TaskRunSnapshot(input: TaskRunSnapshotInput(run: {
            let task = makeTask()
            let run = TaskRun(task: task)
            run.appendFileChange(StoredFileChange(from: FileChange(
                path: report.path,
                changeType: .write,
                content: nil,
                oldString: nil,
                newString: nil,
                timestamp: Date()
            )))
            run.appendFileChange(StoredFileChange(from: FileChange(
                path: config.path,
                changeType: .write,
                content: nil,
                oldString: nil,
                newString: nil,
                timestamp: Date()
            )))
            run.appendFileChange(StoredFileChange(from: FileChange(
                path: stdout.path,
                changeType: .write,
                content: nil,
                oldString: nil,
                newString: nil,
                timestamp: Date()
            )))
            return run
        }()))

        let items = TaskFileIndex.headerItems(
            runs: [run],
            generatedFilePaths: [],
            inputs: [],
            taskFolder: root.path
        )

        #expect(items.map(\.path) == [report.path])
    }

    @Test("Task file header count excludes workspace-private diagnostics")
    func taskFileHeaderCountExcludesWorkspacePrivateDiagnostics() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-private-header-\(UUID().uuidString)")
        let taskFolder = workspace
            .appendingPathComponent(".astra", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("task-1", isDirectory: true)
        let report = workspace.appendingPathComponent("report.md")
        let privateState = workspace
            .appendingPathComponent(".astra", isDirectory: true)
            .appendingPathComponent("state.json")
        let privateClaude = workspace
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("session.json")

        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateState.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateClaude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Report".write(to: report, atomically: true, encoding: .utf8)
        try "{}".write(to: privateState, atomically: true, encoding: .utf8)
        try "{}".write(to: privateClaude, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let run = TaskRunSnapshot(input: TaskRunSnapshotInput(run: {
            let task = makeTask()
            let run = TaskRun(task: task)
            for path in [report.path, privateState.path, privateClaude.path] {
                run.appendFileChange(StoredFileChange(from: FileChange(
                    path: path,
                    changeType: .write,
                    content: nil,
                    oldString: nil,
                    newString: nil,
                    timestamp: Date()
                )))
            }
            return run
        }()))

        let items = TaskFileIndex.headerItems(
            runs: [run],
            generatedFilePaths: [],
            inputs: [],
            taskFolder: taskFolder.path,
            workspacePath: workspace.path
        )

        #expect(items.map(\.path) == [report.path])
    }

    @Test("Task file header keeps explicit inputs in workspace-private folders")
    func taskFileHeaderKeepsExplicitInputsInWorkspacePrivateFolders() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-private-input-\(UUID().uuidString)")
        let taskFolder = workspace
            .appendingPathComponent(".astra", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("task-1", isDirectory: true)
        let privateCommand = workspace
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
            .appendingPathComponent("deploy.md")
        let generatedPrivateState = workspace
            .appendingPathComponent(".astra", isDirectory: true)
            .appendingPathComponent("state.json")

        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateCommand.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generatedPrivateState.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Deploy".write(to: privateCommand, atomically: true, encoding: .utf8)
        try "{}".write(to: generatedPrivateState, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let run = TaskRunSnapshot(input: TaskRunSnapshotInput(run: {
            let task = makeTask()
            let run = TaskRun(task: task)
            run.appendFileChange(StoredFileChange(from: FileChange(
                path: generatedPrivateState.path,
                changeType: .write,
                content: nil,
                oldString: nil,
                newString: nil,
                timestamp: Date()
            )))
            return run
        }()))

        let items = TaskFileIndex.headerItems(
            runs: [run],
            generatedFilePaths: [],
            inputs: [privateCommand.path],
            taskFolder: taskFolder.path,
            workspacePath: workspace.path
        )

        #expect(items.map(\.path) == [privateCommand.path])
        #expect(items.map(\.source) == ["input"])
    }

    @Test("Task artifact relative path accepts resolved paths under symlinked roots")
    func taskArtifactRelativePathAcceptsResolvedPathsUnderSymlinkedRoots() throws {
        let realRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-real-root-\(UUID().uuidString)")
        let linkRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-linked-root-\(UUID().uuidString)")
        let output = realRoot.appendingPathComponent("outputs/result.md")
        let escapingTarget = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-escape-\(UUID().uuidString).txt")
        let escapeLink = realRoot.appendingPathComponent("escape.txt")

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Result".write(to: output, atomically: true, encoding: .utf8)
        try "secret".write(to: escapingTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: escapingTarget)
        defer {
            try? FileManager.default.removeItem(at: linkRoot)
            try? FileManager.default.removeItem(at: realRoot)
            try? FileManager.default.removeItem(at: escapingTarget)
        }

        #expect(TaskOutputArtifactPathPolicy.relativePath(output.path, under: linkRoot.path) == "outputs/result.md")
        #expect(TaskOutputArtifactPathPolicy.relativePath(escapeLink.path, under: realRoot.path) == nil)
    }

    @Test("Diagnostics index groups hidden runtime files")
    func diagnosticsIndexGroupsHiddenRuntimeFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-diagnostics-index-\(UUID().uuidString)")
        let config = root.appendingPathComponent(".runtime/docker-client/client-1/config.json")
        let stdout = root.appendingPathComponent("jobs/job-1/stdout.log")
        let state = root.appendingPathComponent("current_state.json")
        let plan = root.appendingPathComponent("plan.md")

        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stdout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        try "log".write(to: stdout, atomically: true, encoding: .utf8)
        try "{}".write(to: state, atomically: true, encoding: .utf8)
        try "# Plan".write(to: plan, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let groups = TaskDiagnosticsIndex.groups(in: root.path)
        let diagnosticPaths = Set(groups.flatMap(\.items).map(\.relativePath))

        #expect(diagnosticPaths.contains(".runtime/docker-client/client-1/config.json"))
        #expect(diagnosticPaths.contains("jobs/job-1/stdout.log"))
        #expect(diagnosticPaths.contains("current_state.json"))
        #expect(!diagnosticPaths.contains("plan.md"))
        #expect(groups.contains { $0.group == .runtimeEnvironment })
        #expect(groups.contains { $0.group == .jobLogs })
        #expect(groups.contains { $0.group == .runs })
    }

    @Test("Task file index ignores non-regular entries")
    func taskFileIndexIgnoresNonRegularEntries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-file-index-nonregular-\(UUID().uuidString)")
        let pipe = root.appendingPathComponent("stream.md")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(mkfifo(pipe.path, S_IRUSR | S_IWUSR) == 0)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = TaskFileIndex.scanTaskFolder(root.path)

        #expect(!files.contains { $0.path == pipe.path })
    }

    @Test("Task detail artifact scan ignores non-regular entries")
    func taskDetailArtifactScanIgnoresNonRegularEntries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-detail-artifacts-nonregular-\(UUID().uuidString)")
        let report = root.appendingPathComponent("report.md")
        let pipe = root.appendingPathComponent("stream.md")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Report".write(to: report, atomically: true, encoding: .utf8)
        #expect(mkfifo(pipe.path, S_IRUSR | S_IWUSR) == 0)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = TaskDetailArtifactScanner.scanTaskFolder(root.path)

        #expect(files.contains { $0.path == report.path })
        #expect(!files.contains { $0.path == pipe.path })
    }

    @Test("Task file index merges visible files without duplicates")
    func taskFileIndexMergesVisibleFilesWithoutDuplicates() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-file-merge-\(UUID().uuidString)")
        let report = root.appendingPathComponent("report.md")
        let data = root.appendingPathComponent("data.json")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Report".write(to: report, atomically: true, encoding: .utf8)
        try "{}".write(to: data, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let merged = TaskFileIndex.mergedItems(
            latestRun: nil,
            taskFolderFiles: [TaskFileIndex.fileItem(path: report.path, isDirectory: false, source: "output")],
            inputs: [report.path, data.path],
            outputPathFiles: [TaskFileIndex.fileItem(path: data.path, isDirectory: false, source: "referenced")]
        )

        #expect(merged.map(\.path) == [report.path, data.path])
        #expect(merged.map(\.source) == ["output", "input"])
    }

    @MainActor
    @Test("Workspace file roots include configured and task paths")
    func workspaceFileRootsIncludeConfiguredAndTaskPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-file-roots-\(UUID().uuidString)")
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        let inputFile = root.appendingPathComponent("input.md")

        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try "# Input".write(to: inputFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Files", primaryPath: root.path, additionalPaths: [extra.path])
        let task = AgentTask(title: "Browse", goal: "Browse files", workspace: workspace)
        task.inputs = [input.path, inputFile.path]
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()

        let roots = WorkspaceFileIndexService.roots(workspace: workspace, task: task)

        #expect(roots.map(\.kind) == [.primary, .additional, .taskFolder, .input, .input])
        #expect(roots.suffix(2).map(\.title) == ["Input 1", "Input 2"])
        #expect(roots.map(\.path).contains(root.standardizedFileURL.path))
        #expect(roots.map(\.path).contains(extra.standardizedFileURL.path))
        #expect(roots.map(\.path).contains(input.standardizedFileURL.path))
        #expect(roots.map(\.path).contains(inputFile.standardizedFileURL.path))
        #expect(roots.last?.isDirectory == false)

        let snapshot = WorkspaceFileIndexService.scanSync(roots: roots)
        let inputFileRoot = try #require(roots.last)
        #expect(snapshot.nodes.contains {
            $0.rootID == inputFileRoot.id
                && $0.path == inputFile.standardizedFileURL.path
                && !$0.isDirectory
        })
    }

    @MainActor
    @Test("Workspace file roots include task output folder referenced by task prompt")
    func workspaceFileRootsIncludePromptReferencedTaskOutputFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-prompt-output-\(UUID().uuidString)")
        let outputFolder = root.appendingPathComponent("tasks/945FF2B6", isDirectory: true)
        let report = outputFolder.appendingPathComponent("BRIE_Deid_Pilot_Report.md")

        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try "# Report".write(to: report, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "JSL", primaryPath: root.path)
        let task = AgentTask(
            title: "Check BRIE run",
            goal: """
            Task Output Folder: \(outputFolder.path)
            Goal: check the process status
            """,
            workspace: workspace
        )

        let roots = WorkspaceFileIndexService.roots(workspace: workspace, task: task)
        let outputRoot = try #require(roots.first { $0.path == outputFolder.standardizedFileURL.path })
        #expect(outputRoot.kind == .taskFolder)
        #expect(outputRoot.title == "Task Output 945FF2B6")

        let snapshot = WorkspaceFileIndexService.scanSync(roots: roots)
        #expect(snapshot.nodes.contains {
            $0.rootID == outputRoot.id
                && $0.relativePath == "BRIE_Deid_Pilot_Report.md"
                && $0.destination == .files
        })
    }

    @MainActor
    @Test("Workspace argument includes prompt output when task has no workspace")
    func workspaceArgumentIncludesPromptOutputWhenTaskHasNoWorkspace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-argument-output-\(UUID().uuidString)")
        let outputFolder = root.appendingPathComponent("tasks/945FF2B6", isDirectory: true)

        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "JSL", primaryPath: root.path)
        let task = AgentTask(
            title: "Check BRIE run",
            goal: """
            Task Output Folder: \(outputFolder.path)
            Goal: check the process status
            """
        )

        let roots = WorkspaceFileIndexService.roots(workspace: workspace, task: task)

        #expect(roots.contains {
            $0.kind == .taskFolder
                && $0.path == outputFolder.standardizedFileURL.path
                && $0.title == "Task Output 945FF2B6"
        })
    }

    @MainActor
    @Test("Prompt referenced task folders support workspace paths with spaces")
    func promptReferencedTaskFoldersSupportWorkspacePathsWithSpaces() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra workspace prompt output \(UUID().uuidString)")
        let outputFolder = root.appendingPathComponent("tasks/945FF2B6", isDirectory: true)

        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "JSL", primaryPath: root.path)
        let task = AgentTask(
            title: "Check BRIE run",
            goal: """
            Task Output Folder: \(outputFolder.path)
            Goal: check the process status
            """,
            workspace: workspace
        )

        #expect(TaskRelatedOutputFolders.legacyOutputFolders(for: task, workspace: workspace) == [
            outputFolder.standardizedFileURL.path
        ])
    }

    @MainActor
    @Test("Prompt referenced task folders require a containing workspace")
    func promptReferencedTaskFoldersRequireContainingWorkspace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-prompt-output-nil-\(UUID().uuidString)")
        let outputFolder = root.appendingPathComponent("tasks/945FF2B6", isDirectory: true)

        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let task = AgentTask(
            title: "Check mentioned output",
            goal: """
            Task Output Folder: \(outputFolder.path)
            Goal: check the process status
            """
        )

        #expect(TaskRelatedOutputFolders.legacyOutputFolders(for: task, workspace: nil).isEmpty)
    }

    @MainActor
    @Test("Prompt referenced symlinked task folders stay inside workspace")
    func promptReferencedSymlinkedTaskFoldersStayInsideWorkspace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-prompt-symlink-\(UUID().uuidString)")
        let tasksRoot = root.appendingPathComponent("tasks", isDirectory: true)
        let linkedOutputFolder = tasksRoot.appendingPathComponent("945FF2B6", isDirectory: true)
        let outsideFolder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-outside-task-output-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: tasksRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedOutputFolder, withDestinationURL: outsideFolder)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideFolder)
        }

        let workspace = Workspace(name: "JSL", primaryPath: root.path)
        let task = AgentTask(
            title: "Check mentioned output",
            goal: """
            Task Output Folder: \(linkedOutputFolder.path)
            Goal: check the process status
            """
        )

        #expect(TaskRelatedOutputFolders.legacyOutputFolders(for: task, workspace: workspace).isEmpty)
    }

    @MainActor
    @Test("Prompt referenced symlinked task folders reject internal storage")
    func promptReferencedSymlinkedTaskFoldersRejectInternalStorage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-prompt-internal-symlink-\(UUID().uuidString)")
        let tasksRoot = root.appendingPathComponent("tasks", isDirectory: true)
        let linkedOutputFolder = tasksRoot.appendingPathComponent("945FF2B6", isDirectory: true)
        let internalFolder = root.appendingPathComponent(".astra/tasks/945FF2B6", isDirectory: true)

        try FileManager.default.createDirectory(at: tasksRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: internalFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedOutputFolder, withDestinationURL: internalFolder)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "JSL", primaryPath: root.path)
        let task = AgentTask(
            title: "Check mentioned output",
            goal: """
            Task Output Folder: \(linkedOutputFolder.path)
            Goal: check the process status
            """
        )

        #expect(TaskRelatedOutputFolders.legacyOutputFolders(for: task, workspace: workspace).isEmpty)
    }

    @Test("File provenance distinguishes generated user and other task files")
    func fileProvenanceDistinguishesGeneratedUserAndOtherTaskFiles() {
        let generatedRoot = WorkspaceFileRoot(
            id: "task:/tmp/tasks/945FF2B6",
            kind: .taskFolder,
            title: "Task Output 945FF2B6",
            path: "/tmp/tasks/945FF2B6",
            isDirectory: true
        )
        let inputRoot = WorkspaceFileRoot(
            id: "input:/tmp/privacy.zip",
            kind: .input,
            title: "Input 1",
            path: "/tmp/privacy.zip",
            isDirectory: false
        )
        let workspaceRoot = WorkspaceFileRoot(
            id: "primary:/tmp/ws",
            kind: .primary,
            title: "Primary",
            path: "/tmp/ws",
            isDirectory: true
        )
        let currentTaskNode = WorkspaceFileNode(
            id: "current",
            rootID: workspaceRoot.id,
            path: "/tmp/ws/tasks/945FF2B6/report.md",
            relativePath: "tasks/945FF2B6/report.md",
            name: "report.md",
            isDirectory: false,
            depth: 2,
            size: 10,
            modifiedAt: nil,
            destination: .files
        )
        let otherTaskNode = WorkspaceFileNode(
            id: "other",
            rootID: workspaceRoot.id,
            path: "/tmp/ws/tasks/ABC12345/report.md",
            relativePath: "tasks/ABC12345/report.md",
            name: "report.md",
            isDirectory: false,
            depth: 2,
            size: 10,
            modifiedAt: nil,
            destination: .files
        )

        #expect(ShelfFileProvenanceResolver.provenance(for: generatedRoot) == .taskGenerated)
        #expect(ShelfFileProvenanceResolver.provenance(for: inputRoot) == .userProvided)
        #expect(ShelfFileProvenanceResolver.provenance(
            for: workspaceRoot,
            node: currentTaskNode,
            currentTaskOutputFolderNames: ["945FF2B6"]
        ) == .currentTaskOutput)
        #expect(ShelfFileProvenanceResolver.provenance(
            for: workspaceRoot,
            node: otherTaskNode,
            currentTaskOutputFolderNames: ["945FF2B6"]
        ) == .otherTaskOutput)
    }

    @Test("File provenance current task folders come from task ID only")
    func fileProvenanceCurrentTaskFoldersComeFromTaskIDOnly() {
        let workspace = Workspace(name: "JSL", primaryPath: "/tmp/ws")
        let task = AgentTask(title: "Current", goal: "Review outputs", workspace: workspace)
        task.id = UUID(uuidString: "945FF2B6-0000-0000-0000-000000000000")!
        let workspaceRoot = WorkspaceFileRoot(
            id: "primary:/tmp/ws",
            kind: .primary,
            title: "Primary",
            path: "/tmp/ws",
            isDirectory: true
        )
        let promptReferencedOtherTaskNode = WorkspaceFileNode(
            id: "other",
            rootID: workspaceRoot.id,
            path: "/tmp/ws/tasks/ABC12345/report.md",
            relativePath: "tasks/ABC12345/report.md",
            name: "report.md",
            isDirectory: false,
            depth: 2,
            size: 10,
            modifiedAt: nil,
            destination: .files
        )
        let currentTaskNode = WorkspaceFileNode(
            id: "current",
            rootID: workspaceRoot.id,
            path: "/tmp/ws/tasks/945FF2B6/report.md",
            relativePath: "tasks/945FF2B6/report.md",
            name: "report.md",
            isDirectory: false,
            depth: 2,
            size: 10,
            modifiedAt: nil,
            destination: .files
        )

        let folderNames = ShelfFileProvenanceResolver.currentTaskOutputFolderNames(for: task)

        #expect(folderNames == ["945FF2B6"])
        #expect(ShelfFileProvenanceResolver.provenance(
            for: workspaceRoot,
            node: promptReferencedOtherTaskNode,
            currentTaskOutputFolderNames: folderNames
        ) == .otherTaskOutput)
        #expect(ShelfFileProvenanceResolver.provenance(
            for: workspaceRoot,
            node: currentTaskNode,
            currentTaskOutputFolderNames: folderNames
        ) == .currentTaskOutput)
    }

    @Test("Workspace file scan skips heavy internal folders and symlink escapes")
    func workspaceFileScanSkipsInternalFoldersAndSymlinkEscapes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-file-scan-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let nodeModules = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        let legacyTasks = root.appendingPathComponent("tasks/ABC12345", isDirectory: true)
        let legacyTaskCli = legacyTasks.appendingPathComponent("cli", isDirectory: true)
        let taskInternals = root.appendingPathComponent(".astra/tasks/ABC12345", isDirectory: true)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-file-outside-\(UUID().uuidString).txt")

        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTasks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTaskCli, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskInternals, withIntermediateDirectories: true)
        try "swift".write(to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try "ignored".write(to: nodeModules.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "# Report".write(to: legacyTasks.appendingPathComponent("BRIE_Deid_Report.md"), atomically: true, encoding: .utf8)
        try "print('run')".write(to: legacyTaskCli.appendingPathComponent("run_deid.py"), atomically: true, encoding: .utf8)
        try "ignored".write(to: legacyTasks.appendingPathComponent("current_state.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: legacyTasks.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: taskInternals.appendingPathComponent("current_state.md"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside.txt"),
            withDestinationURL: outside
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let rootModel = WorkspaceFileRoot(
            id: "primary:\(root.standardizedFileURL.path)",
            kind: .primary,
            title: "Primary",
            path: root.standardizedFileURL.path,
            isDirectory: true
        )
        let snapshot = WorkspaceFileIndexService.scanSync(roots: [rootModel])
        let paths = Set(snapshot.nodes.map(\.relativePath))

        #expect(paths.contains("Sources"))
        #expect(paths.contains("Sources/App.swift"))
        #expect(!paths.contains("node_modules"))
        #expect(!paths.contains("node_modules/pkg/index.js"))
        #expect(paths.contains("tasks"))
        #expect(paths.contains("tasks/ABC12345"))
        #expect(paths.contains("tasks/ABC12345/BRIE_Deid_Report.md"))
        #expect(paths.contains("tasks/ABC12345/cli/run_deid.py"))
        #expect(!paths.contains("tasks/ABC12345/current_state.md"))
        #expect(!paths.contains("tasks/ABC12345/session_history.md"))
        #expect(!paths.contains(".astra/tasks/ABC12345/current_state.md"))
        #expect(!paths.contains("outside.txt"))
        #expect(snapshot.nodes.first { $0.relativePath == "Sources/App.swift" }?.destination == .files)
        #expect(snapshot.nodes.first { $0.relativePath == "tasks/ABC12345/BRIE_Deid_Report.md" }?.destination == .files)
    }

    @Test("Workspace file scan hides dot paths unless requested")
    func workspaceFileScanHidesDotPathsUnlessRequested() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-hidden-paths-\(UUID().uuidString)")
        let astraSupport = root.appendingPathComponent(".astra", isDirectory: true)
        let codexSupport = root.appendingPathComponent(".codex", isDirectory: true)
        let claudeSupport = root.appendingPathComponent(".claude", isDirectory: true)
        let taskInternals = astraSupport.appendingPathComponent("tasks/ABC12345", isDirectory: true)

        try FileManager.default.createDirectory(at: astraSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskInternals, withIntermediateDirectories: true)
        try "swift".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent(".astra-workspace.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: astraSupport.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "state".write(to: codexSupport.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        try "settings".write(to: claudeSupport.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try "internal".write(to: taskInternals.appendingPathComponent("current_state.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootModel = WorkspaceFileRoot(
            id: "primary:\(root.standardizedFileURL.path)",
            kind: .primary,
            title: "Primary",
            path: root.standardizedFileURL.path,
            isDirectory: true
        )

        let defaultPaths = Set(WorkspaceFileIndexService.scanSync(roots: [rootModel]).nodes.map(\.relativePath))
        #expect(defaultPaths == ["App.swift"])

        let hiddenPaths = Set(WorkspaceFileIndexService.scanSync(
            roots: [rootModel],
            includeHidden: true
        ).nodes.map(\.relativePath))

        #expect(hiddenPaths.contains("App.swift"))
        #expect(hiddenPaths.contains(".astra"))
        #expect(hiddenPaths.contains(".astra/config.json"))
        #expect(hiddenPaths.contains(".astra-workspace.json"))
        #expect(hiddenPaths.contains(".codex/state.json"))
        #expect(hiddenPaths.contains(".claude/settings.json"))
        #expect(!hiddenPaths.contains(".astra/tasks"))
        #expect(!hiddenPaths.contains(".astra/tasks/ABC12345/current_state.md"))
    }

    @Test("Workspace file scan skips privacy-sensitive user media folders")
    func workspaceFileScanSkipsPrivacySensitiveUserMediaFolders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-workspace-privacy-folders-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let pictures = root.appendingPathComponent("Pictures", isDirectory: true)
        let music = root.appendingPathComponent("Music", isDirectory: true)

        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try "swift".write(to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try "photo-metadata".write(to: pictures.appendingPathComponent("library.txt"), atomically: true, encoding: .utf8)
        try "music-metadata".write(to: music.appendingPathComponent("library.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootModel = WorkspaceFileRoot(
            id: "primary:\(root.standardizedFileURL.path)",
            kind: .primary,
            title: "Primary",
            path: root.standardizedFileURL.path,
            isDirectory: true
        )

        let paths = Set(WorkspaceFileIndexService.scanSync(
            roots: [rootModel],
            privacyHomeDirectory: root
        ).nodes.map(\.relativePath))

        #expect(paths.contains("Sources/App.swift"))
        #expect(!paths.contains("Pictures"))
        #expect(!paths.contains("Pictures/library.txt"))
        #expect(!paths.contains("Music"))
        #expect(!paths.contains("Music/library.txt"))
    }

    @Test("Workspace file scan hides task folder runtime documents")
    func workspaceFileScanHidesTaskFolderRuntimeDocuments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-folder-runtime-files-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let outputs = root.appendingPathComponent("outputs", isDirectory: true)
        let turns = root.appendingPathComponent("turns", isDirectory: true)
        let runtimeBin = root.appendingPathComponent(".runtime-bin", isDirectory: true)
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try "# Report".write(to: root.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try "details".write(to: nested.appendingPathComponent("details.txt"), atomically: true, encoding: .utf8)
        try "provider log".write(to: diagnostics.appendingPathComponent("antigravity.log"), atomically: true, encoding: .utf8)
        try "state".write(to: root.appendingPathComponent("current_state.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("current_state.json"), atomically: true, encoding: .utf8)
        try "history".write(to: root.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)
        try "turn".write(to: root.appendingPathComponent("turn_001.md"), atomically: true, encoding: .utf8)
        try "output".write(to: outputs.appendingPathComponent("turn_001.md"), atomically: true, encoding: .utf8)
        try "turn".write(to: turns.appendingPathComponent("turn_002.md"), atomically: true, encoding: .utf8)
        try "shim".write(to: runtimeBin.appendingPathComponent("astra-browser"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootModel = WorkspaceFileRoot(
            id: "taskFolder:\(root.standardizedFileURL.path)",
            kind: .taskFolder,
            title: "Task Folder",
            path: root.standardizedFileURL.path,
            isDirectory: true
        )

        let paths = Set(WorkspaceFileIndexService.scanSync(
            roots: [rootModel],
            includeHidden: true
        ).nodes.map(\.relativePath))

        #expect(paths.contains("report.md"))
        #expect(paths.contains("nested"))
        #expect(paths.contains("nested/details.txt"))
        #expect(!paths.contains("current_state.md"))
        #expect(!paths.contains("current_state.json"))
        #expect(!paths.contains("session_history.md"))
        #expect(!paths.contains("turn_001.md"))
        #expect(!paths.contains("outputs"))
        #expect(!paths.contains("outputs/turn_001.md"))
        #expect(!paths.contains("turns"))
        #expect(!paths.contains("turns/turn_002.md"))
        #expect(!paths.contains(".runtime-bin/astra-browser"))
        #expect(!paths.contains("diagnostics"))
        #expect(!paths.contains("diagnostics/antigravity.log"))
    }

    @Test("Generated file preview prefers task index HTML")
    func generatedFilePreviewPrefersTaskIndexHTML() {
        let root = URL(fileURLWithPath: "/tmp/astra-generated-files-preview")
        let paths = [
            root.appendingPathComponent("nested/page.html").path,
            root.appendingPathComponent("preview.htm").path,
            root.appendingPathComponent("index.html").path,
            root.appendingPathComponent("notes.txt").path
        ]

        #expect(TaskGeneratedFiles.preferredHTMLFile(in: paths, taskFolder: root.path) == root.appendingPathComponent("index.html").path)
    }

    @Test("Generated file preview ignores non HTML files")
    func generatedFilePreviewIgnoresNonHTMLFiles() {
        let paths = [
            "/tmp/result.md",
            "/tmp/styles.css",
            "/tmp/script.js"
        ]

        #expect(TaskGeneratedFiles.preferredHTMLFile(in: paths) == nil)
    }

    @Test("Generated HTML user-open guard does not replace a user navigated page")
    func generatedHTMLUserOpenGuardDoesNotReplaceUserNavigatedPage() {
        let root = URL(fileURLWithPath: "/tmp/astra-generated-user-open")
        let index = root.appendingPathComponent("index.html").path
        let about = root.appendingPathComponent("about.html").path

        #expect(TaskGeneratedFiles.shouldLoadGeneratedHTMLOnUserOpen(currentBrowserURL: "", targetPath: index))
        #expect(TaskGeneratedFiles.shouldLoadGeneratedHTMLOnUserOpen(currentBrowserURL: "about:blank", targetPath: index))
        #expect(TaskGeneratedFiles.shouldLoadGeneratedHTMLOnUserOpen(
            currentBrowserURL: URL(fileURLWithPath: index).absoluteString,
            targetPath: index
        ))
        #expect(!TaskGeneratedFiles.shouldLoadGeneratedHTMLOnUserOpen(
            currentBrowserURL: URL(fileURLWithPath: about).absoluteString,
            targetPath: index
        ))
        #expect(!TaskGeneratedFiles.shouldLoadGeneratedHTMLOnUserOpen(
            currentBrowserURL: "https://example.com/current-page",
            targetPath: index
        ))
    }

    @Test("Generated file preview prefers task README Markdown")
    func generatedFilePreviewPrefersTaskReadmeMarkdown() {
        let root = URL(fileURLWithPath: "/tmp/astra-generated-files-markdown-preview")
        let paths = [
            root.appendingPathComponent("nested/report.md").path,
            root.appendingPathComponent("docs/starr_common.qmd").path,
            root.appendingPathComponent("summary.markdown").path,
            root.appendingPathComponent("README.md").path,
            root.appendingPathComponent("index.html").path
        ]

        #expect(TaskGeneratedFiles.preferredMarkdownFile(in: paths, taskFolder: root.path) == root.appendingPathComponent("README.md").path)
    }

    @Test("Generated file preview ignores non Markdown files")
    func generatedFilePreviewIgnoresNonMarkdownFiles() {
        let paths = [
            "/tmp/index.html",
            "/tmp/styles.css",
            "/tmp/result.txt"
        ]

        #expect(TaskGeneratedFiles.preferredMarkdownFile(in: paths) == nil)
    }

    @Test("Generated file shelf destination routes web and text artifacts")
    func generatedFileShelfDestinationRoutesPreviewableArtifacts() {
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/index.html") == .browser)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/preview.htm") == .browser)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/README.md") == .files)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/report.markdown") == .files)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/docs/starr_common.qmd") == .files)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/query.sql") == .query)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/script.py") == .files)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/data.json") == .files)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/session.log") == .files)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/image.png") == nil)
    }

    @Test("Generated file shelf recognition covers common source and config files")
    func generatedFileFilesShelfRecognitionCoversCommonSourceAndConfigFiles() {
        let textPaths = [
            "/tmp/Sources/App.swift",
            "/tmp/scripts/run.sh",
            "/tmp/styles/site.css",
            "/tmp/data/results.jsonl",
            "/tmp/config/settings.yaml",
            "/tmp/config/.env.local",
            "/tmp/project/.gitignore",
            "/tmp/project/Dockerfile",
            "/tmp/project/Makefile",
            "/tmp/project/LICENSE",
            "/tmp/project/README"
        ]

        for path in textPaths {
            #expect(TaskGeneratedFiles.isFilesShelfFile(path), "Expected \(path) to be recognized as a Files shelf file")
            #expect(TaskGeneratedFiles.shelfDestination(for: path) == .files, "Expected \(path) to route to the Files shelf")
        }
    }

    @Test("Generated file shelf keeps HTML in browser even though it is text")
    func generatedFileShelfKeepsHTMLInBrowserEvenThoughItIsText() {
        #expect(TaskGeneratedFiles.isFilesShelfFile("/tmp/index.html") == true)
        #expect(TaskGeneratedFiles.isFilesShelfFile("/tmp/preview.htm") == true)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/index.html") == .browser)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/preview.htm") == .browser)
    }

    @Test("Generated file shelf rejects unknown binary and arbitrary extensionless files")
    func generatedFileFilesShelfRejectsUnknownBinaryAndArbitraryExtensionlessFiles() {
        #expect(TaskGeneratedFiles.isFilesShelfFile("/tmp/image.png") == false)
        #expect(TaskGeneratedFiles.isFilesShelfFile("/tmp/archive.zip") == false)
        #expect(TaskGeneratedFiles.isFilesShelfFile("/tmp/random-output") == false)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/image.png") == nil)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/archive.zip") == nil)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/random-output") == nil)
    }
}
