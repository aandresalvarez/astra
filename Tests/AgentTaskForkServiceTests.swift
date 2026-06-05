import Foundation
import SwiftData
import Testing
@testable import ASTRA

private func makeAgentTaskForkContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Agent task fork checkpoints")
@MainActor
struct AgentTaskForkServiceTests {
    @Test("fork preserves run-scoped events and records a checkpoint")
    func forkPreservesRunScopedEventsAndRecordsCheckpoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Fork Checkpoint", primaryPath: root)
        let source = AgentTask(
            title: "Source",
            goal: "Try two implementation branches",
            workspace: workspace,
            validationStrategy: .runTests
        )
        source.testCommand = "swift test --filter ForkCheckpointTests"
        context.insert(workspace)
        context.insert(source)

        let firstRun = TaskRun(task: source)
        firstRun.startedAt = Date(timeIntervalSince1970: 100)
        firstRun.completedAt = Date(timeIntervalSince1970: 110)
        firstRun.status = RunStatus.completed
        firstRun.output = "First branch result"
        firstRun.stopReason = "completed"
        context.insert(firstRun)

        let firstEvent = TaskEvent(
            task: source,
            type: "tool.use",
            payload: "Using tool: Bash: swift test --filter FirstBranchTests",
            run: firstRun
        )
        firstEvent.timestamp = Date(timeIntervalSince1970: 105)
        context.insert(firstEvent)

        let secondRun = TaskRun(task: source)
        secondRun.startedAt = Date(timeIntervalSince1970: 200)
        secondRun.completedAt = Date(timeIntervalSince1970: 210)
        secondRun.status = RunStatus.completed
        secondRun.output = "Second branch result"
        secondRun.stopReason = "completed"
        context.insert(secondRun)

        let secondEvent = TaskEvent(
            task: source,
            type: "tool.use",
            payload: "Using tool: Bash: swift test --filter SecondBranchTests",
            run: secondRun
        )
        secondEvent.timestamp = Date(timeIntervalSince1970: 205)
        context.insert(secondEvent)

        let forked = AgentTask.fork(from: source, upToRun: firstRun, in: context)
        try context.save()

        #expect(forked.forkedFromID == source.id)
        #expect(forked.forkedAtRunIndex == 0)
        #expect(forked.runs.count == 1)
        let forkedRun = try #require(forked.runs.first)
        let copiedFirstEvent = try #require(forked.events.first { $0.payload.contains("FirstBranchTests") })
        #expect(copiedFirstEvent.run?.id == forkedRun.id)
        #expect(!forked.events.contains { $0.payload.contains("SecondBranchTests") })

        let checkpointEvent = try #require(forked.events.first { $0.type == "task.checkpoint" })
        #expect(checkpointEvent.run?.id == forkedRun.id)
        #expect(checkpointEvent.payload.contains(source.id.uuidString))
        #expect(checkpointEvent.payload.contains("Later source runs are not authoritative"))

        TaskContextStateManager.refresh(task: forked)
        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: forked).taskFolder))
        #expect(state.decisionFacts.contains { $0.text.contains("Forked checkpoint from task \(source.id.uuidString)") })
        #expect(state.sourcePointers.contains { $0.kind == "checkpoint" && $0.id == source.id.uuidString })

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue from checkpoint", task: forked)
        #expect(prompt.contains("Checkpoint:"))
        #expect(prompt.contains("source runs after the checkpoint are not authoritative"))
        #expect(prompt.contains("after source run 1"))
    }

    @Test("fork writes provenance manifest and keeps artifacts lazy")
    func forkWritesProvenanceManifestAndKeepsArtifactsLazy() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Fork Provenance", primaryPath: root)
        let source = AgentTask(
            title: "Source",
            goal: "Create a preview then try another branch",
            workspace: workspace
        )
        context.insert(workspace)
        context.insert(source)

        let sourceFolder = try TaskWorkspaceAccess(task: source).ensureTaskFolder()
        let sourceOutputs = (sourceFolder as NSString).appendingPathComponent("outputs")
        let firstOutput = (sourceOutputs as NSString).appendingPathComponent("turn_001.md")
        let secondOutput = (sourceOutputs as NSString).appendingPathComponent("turn_002.md")
        let artifactPath = (sourceFolder as NSString).appendingPathComponent("index.html")
        try "first exact output".write(toFile: firstOutput, atomically: true, encoding: .utf8)
        try "second later output".write(toFile: secondOutput, atomically: true, encoding: .utf8)
        try "<html>checkpoint</html>".write(toFile: artifactPath, atomically: true, encoding: .utf8)
        try """
        # Session History

        ## Turn 1
        first exact source turn

        ## Turn 2
        later source turn that must stay out of the fork checkpoint
        """.write(
            toFile: SessionHistoryManager.historyPath(taskFolder: sourceFolder),
            atomically: true,
            encoding: .utf8
        )

        let firstRun = TaskRun(task: source)
        firstRun.startedAt = Date(timeIntervalSince1970: 100)
        firstRun.completedAt = Date(timeIntervalSince1970: 110)
        firstRun.status = .completed
        firstRun.output = "First branch result"
        context.insert(firstRun)

        let artifact = Artifact(task: source, type: "html", path: artifactPath)
        artifact.createdAt = Date(timeIntervalSince1970: 105)
        context.insert(artifact)

        let secondRun = TaskRun(task: source)
        secondRun.startedAt = Date(timeIntervalSince1970: 200)
        secondRun.completedAt = Date(timeIntervalSince1970: 210)
        secondRun.status = .completed
        secondRun.output = "Second branch result"
        context.insert(secondRun)

        let forked = AgentTask.fork(from: source, upToRun: firstRun, in: context)
        try context.save()

        let forkFolder = TaskWorkspaceAccess(task: forked).taskFolder
        let manifestPath = TaskForkManifestService.manifestPath(taskFolder: forkFolder)
        let manifest = try #require(TaskForkManifestService.load(for: forked))
        #expect(FileManager.default.fileExists(atPath: manifestPath))
        #expect(manifest.sourceTaskID == source.id)
        #expect(manifest.forkedTaskID == forked.id)
        #expect(manifest.checkpointRunID == firstRun.id)
        #expect(manifest.copiedRunIDs == [firstRun.id])
        #expect(manifest.sourceTaskFolder == sourceFolder)
        #expect(manifest.sourceSessionHistoryPath == SessionHistoryManager.historyPath(taskFolder: sourceFolder))
        let checkpointHistoryPath = try #require(manifest.checkpointSessionHistoryPath)
        #expect(checkpointHistoryPath.hasPrefix((forkFolder as NSString).appendingPathComponent("fork_sources/history")))
        let checkpointHistory = try String(contentsOfFile: checkpointHistoryPath, encoding: .utf8)
        #expect(checkpointHistory.contains("first exact source turn"))
        #expect(!checkpointHistory.contains("later source turn"))
        #expect(manifest.sourceOutputFiles.map(\.sourcePath) == [firstOutput])
        #expect(manifest.sourceArtifacts.contains { $0.sourcePath == artifactPath })
        #expect(!FileManager.default.fileExists(atPath: (forkFolder as NSString).appendingPathComponent("index.html")))
        #expect(forked.events.contains { event in
            event.type == "task.fork_manifest.created" &&
                event.payload.contains(source.id.uuidString) &&
                event.payload.contains(firstRun.id.uuidString)
        })

        TaskContextStateManager.refresh(task: forked)
        let state = try #require(TaskContextStateManager.load(taskFolder: forkFolder))
        #expect(state.sourcePointers.contains { $0.kind == "fork_manifest" && $0.path == manifestPath })
        #expect(state.sourcePointers.contains { $0.kind == "fork_checkpoint_history" && $0.path == checkpointHistoryPath })
        #expect(state.sourcePointers.contains { $0.kind == "fork_source_output" && $0.path == firstOutput })
        #expect(state.sourcePointers.contains { $0.kind == "fork_source_artifact" && $0.path == artifactPath })

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "continue from checkpoint", task: forked)
        #expect(prompt.contains("Fork manifest: \(manifestPath)"))
        #expect(prompt.contains("Fork-local checkpoint history: \(checkpointHistoryPath)"))
        #expect(prompt.contains("Source checkpoint outputs:"))
        #expect(prompt.contains(firstOutput))
        #expect(prompt.contains(artifactPath))

        let roots = WorkspaceFileIndexService.roots(workspace: workspace, task: forked)
        #expect(roots.contains { $0.title == "Fork Checkpoint File" && $0.path == firstOutput && $0.kind == .input })
        #expect(roots.contains { $0.title == "Fork Checkpoint File" && $0.path == artifactPath && $0.kind == .input })

        let materializedPath = try TaskForkManifestService.materializeSourceFile(sourcePath: artifactPath, for: forked)
        let localCopy = try #require(materializedPath)
        #expect(localCopy.hasPrefix((forkFolder as NSString).appendingPathComponent("fork_sources/artifact")))
        #expect(FileManager.default.fileExists(atPath: localCopy))
        let updatedManifest = try #require(TaskForkManifestService.load(for: forked))
        #expect(updatedManifest.sourceArtifacts.contains { $0.sourcePath == artifactPath && $0.localCopyPath == localCopy })
    }

    @Test("fork warning appears only when source checkpoint files are missing")
    func forkWarningAppearsOnlyWhenSourceCheckpointFilesAreMissing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Fork Missing Source", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Create artifact", workspace: workspace)
        context.insert(workspace)
        context.insert(source)

        let sourceFolder = try TaskWorkspaceAccess(task: source).ensureTaskFolder()
        let artifactPath = (sourceFolder as NSString).appendingPathComponent("report.md")
        let secondArtifactPath = (sourceFolder as NSString).appendingPathComponent("notes.md")
        try "checkpoint report".write(toFile: artifactPath, atomically: true, encoding: .utf8)
        try "checkpoint notes".write(toFile: secondArtifactPath, atomically: true, encoding: .utf8)

        let run = TaskRun(task: source)
        run.startedAt = Date(timeIntervalSince1970: 100)
        run.completedAt = Date(timeIntervalSince1970: 110)
        run.status = .completed
        context.insert(run)
        let artifact = Artifact(task: source, type: "markdown", path: artifactPath)
        artifact.createdAt = Date(timeIntervalSince1970: 105)
        context.insert(artifact)
        let secondArtifact = Artifact(task: source, type: "markdown", path: secondArtifactPath)
        secondArtifact.createdAt = Date(timeIntervalSince1970: 106)
        context.insert(secondArtifact)

        let forked = AgentTask.fork(from: source, upToRun: run, in: context)
        try context.save()

        #expect(TaskForkManifestService.sourceAvailabilityWarning(for: forked) == nil)
        let localCopy = try #require(try TaskForkManifestService.materializeSourceFile(sourcePath: artifactPath, for: forked))
        let secondLocalCopy = try #require(try TaskForkManifestService.materializeSourceFile(sourcePath: secondArtifactPath, for: forked))
        try FileManager.default.removeItem(atPath: sourceFolder)
        #expect(TaskForkManifestService.sourceAvailabilityWarning(for: forked) == nil)
        #expect(FileManager.default.fileExists(atPath: localCopy))
        try FileManager.default.removeItem(atPath: secondLocalCopy)
        let warning = try #require(TaskForkManifestService.sourceAvailabilityWarning(for: forked))
        #expect(warning.contains("Checkpoint files are unavailable"))

        TaskContextStateManager.refresh(task: forked)
        let prompt = try #require(TaskContextStateManager.promptContext(for: forked))
        #expect(prompt.contains("Checkpoint files are unavailable"))
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-fork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
