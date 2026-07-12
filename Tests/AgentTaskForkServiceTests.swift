import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

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

        let forked = try AgentTask.fork(from: source, upToRun: firstRun, in: context)
        try context.save()

        #expect(forked.forkedFromID == source.id)
        #expect(forked.forkedAtRunIndex == 0)
        #expect(forked.testCommand == source.testCommand)
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

        let forked = try AgentTask.fork(from: source, upToRun: firstRun, in: context)
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

        let forked = try AgentTask.fork(from: source, upToRun: run, in: context)
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

    @Test("independent fork snapshots explicit files and rewrites attachment references")
    func independentForkSnapshotsExplicitFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let inputPath = (root as NSString).appendingPathComponent("report.md")
        let attachmentPath = (root as NSString).appendingPathComponent("evidence.txt")
        let providerSuggestedPath = (root as NSString).appendingPathComponent("provider-secret.txt")
        let directoryPath = (root as NSString).appendingPathComponent("shared-folder")
        try "checkpoint report".write(toFile: inputPath, atomically: true, encoding: .utf8)
        try "checkpoint evidence".write(toFile: attachmentPath, atomically: true, encoding: .utf8)
        try "not user attached".write(toFile: providerSuggestedPath, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)

        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Independent Files", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Revise the report", workspace: workspace)
        source.inputs = [inputPath, directoryPath]
        source.goal = "Revise \(inputPath)"
        source.constraints = ["Preserve \(inputPath)"]
        source.acceptanceCriteria = ["Verify \(inputPath)"]
        source.teamInstructions = "Review \(inputPath)"
        context.insert(workspace)
        context.insert(source)
        let sourceFolder = try TaskWorkspaceAccess(task: source).ensureTaskFolder()
        let outputFolder = (sourceFolder as NSString).appendingPathComponent("outputs")
        try FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)
        let turnOutput = (outputFolder as NSString).appendingPathComponent("turn_001.md")
        try "Generated from \(inputPath)".write(toFile: turnOutput, atomically: true, encoding: .utf8)
        let run = TaskRun(task: source)
        run.status = .completed
        run.startedAt = Date(timeIntervalSince1970: 100)
        run.completedAt = Date(timeIntervalSince1970: 110)
        run.output = "Use \(inputPath), but preserve the distinct \(inputPath).bak reference."
        run.fileChangesJSON = TaskEvent.payloadString([
            StoredFileChange(path: inputPath, changeType: "Write", content: "checkpoint report")
        ])
        context.insert(run)
        let attachmentEvent = TaskEvent(
            task: source,
            type: "user.message",
            payload: "Review this.\n\nAttached files:\n- \(attachmentPath)",
            run: run
        )
        attachmentEvent.timestamp = Date(timeIntervalSince1970: 105)
        context.insert(attachmentEvent)
        let providerEvent = TaskEvent(
            task: source,
            type: "assistant.message",
            payload: "Attached files:\n- \(providerSuggestedPath)",
            run: run
        )
        providerEvent.timestamp = Date(timeIntervalSince1970: 106)
        context.insert(providerEvent)

        let forked = try AgentTask.fork(
            from: source,
            upToRun: run,
            options: TaskForkOptions(mode: .conversationWithFileCopies),
            in: context
        )
        try context.save()

        let manifest = try #require(TaskForkManifestService.load(for: forked))
        #expect(manifest.resolvedForkMode == .conversationWithFileCopies)
        let copiedInput = try #require(manifest.sourceInputs?.first { $0.sourcePath == inputPath }?.localCopyPath)
        let copiedAttachment = try #require(manifest.sourceAttachments?.first { $0.sourcePath == attachmentPath }?.localCopyPath)
        #expect(manifest.sourceInputs?.first { $0.sourcePath == inputPath }?.sha256 != nil)
        #expect(manifest.sourceAttachments?.contains { $0.sourcePath == providerSuggestedPath } == false)
        #expect(forked.inputs.contains(copiedInput))
        #expect(forked.inputs.contains(directoryPath))
        #expect(forked.goal.contains(copiedInput))
        #expect(forked.constraints.first?.contains(copiedInput) == true)
        #expect(forked.acceptanceCriteria.first?.contains(copiedInput) == true)
        #expect(forked.teamInstructions.contains(copiedInput))
        #expect(forked.events.contains { $0.payload.contains(copiedAttachment) && !$0.payload.contains(attachmentPath) })
        let forkedRun = try #require(forked.runs.first)
        #expect(forkedRun.output.contains("Use \(copiedInput)"))
        #expect(forkedRun.output.contains("\(inputPath).bak"))
        #expect(!forkedRun.output.contains("\(copiedInput).bak"))
        #expect(forkedRun.fileChanges.first?.path == copiedInput)
        let copiedTurnOutput = try #require(manifest.sourceOutputFiles.first?.localCopyPath)
        #expect(try String(contentsOfFile: copiedTurnOutput, encoding: .utf8).contains(copiedInput))

        try "changed source".write(toFile: inputPath, atomically: true, encoding: .utf8)
        try "changed evidence".write(toFile: attachmentPath, atomically: true, encoding: .utf8)
        #expect(try String(contentsOfFile: copiedInput, encoding: .utf8) == "checkpoint report")
        #expect(try String(contentsOfFile: copiedAttachment, encoding: .utf8) == "checkpoint evidence")
    }

    @Test("Git-backed fork rejects file-copy mode before creating state")
    func gitBackedForkRejectsFileCopyMode() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Repository", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Continue", workspace: workspace)
        context.insert(workspace)
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)

        #expect(throws: AgentTaskForkError.repositoryFileCopyDenied) {
            try AgentTask.fork(
                from: source,
                upToRun: run,
                options: TaskForkOptions(
                    mode: .conversationWithFileCopies,
                    repository: TaskForkRepositorySnapshot(
                        rootPath: root,
                        branch: "main",
                        headSHA: "12345678",
                        isDirty: false
                    )
                ),
                in: context
            )
        }
        #expect(workspace.tasks.count == 1)
    }

    @Test("Git fork becomes read-only while another task owns the shared worktree")
    func gitForkBecomesReadOnlyDuringSharedWorktreeRun() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Repository", primaryPath: root)
        let source = AgentTask(title: "Original conversation", goal: "Continue", workspace: workspace)
        context.insert(workspace)
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)
        let forked = try AgentTask.fork(
            from: source,
            upToRun: run,
            options: TaskForkOptions(
                repository: TaskForkRepositorySnapshot(
                    rootPath: root,
                    branch: "main",
                    headSHA: "12345678",
                    isDirty: false
                )
            ),
            in: context
        )
        try context.save()

        #expect(TaskForkPolicyService.readOnlyReason(for: forked) == nil)
        #expect(forked.isolationStrategy == .sameDirectory)
        let forkPin = (root as NSString).appendingPathComponent("packages/api")
        let sourcePin = (root as NSString).appendingPathComponent("packages/web")
        try FileManager.default.createDirectory(atPath: forkPin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sourcePin, withIntermediateDirectories: true)
        forked.executionRootPath = forkPin
        source.executionRootPath = sourcePin
        source.status = .running
        let cachedRoot = try #require(TaskForkPolicyService.sharedWorktreeReadOnlyRoot(
            for: forked,
            manifest: TaskForkManifestService.load(for: forked)
        ))
        // Different subdirectory pins of the same recorded repository root
        // still count as the shared worktree.
        let blocker = TaskForkPolicyService.activeSharedWorktreeBlocker(
            for: forked,
            sharedWorktreeRoot: cachedRoot
        )
        #expect(blocker?.id == source.id)
        // The cached render path agrees with the uncached enforcement path.
        #expect(TaskForkPolicyService.readOnlyReason(for: forked)
            == TaskForkPolicyService.readOnlyReason(for: forked, sharedWorktreeRoot: cachedRoot))
        source.status = .completed
        #expect(TaskForkPolicyService.readOnlyReason(for: forked, sharedWorktreeRoot: cachedRoot) == nil)
    }

    @Test("workspace-less conversation still forks history without a manifest")
    func workspaceLessConversationForksHistory() throws {
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let source = AgentTask(title: "Standalone", goal: "Discuss an idea")
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        run.output = "Checkpoint answer"
        context.insert(run)

        let forked = try AgentTask.fork(from: source, upToRun: run, in: context)

        #expect(forked.workspace == nil)
        #expect(forked.runs.first?.output == "Checkpoint answer")
        #expect(forked.events.contains { $0.type == TaskEventTypes.Task.checkpoint.rawValue })
        #expect(!forked.events.contains { $0.type == "task.fork_manifest.created" })
        #expect(throws: AgentTaskForkError.fileCopiesRequireWorkspace) {
            try AgentTask.fork(
                from: source,
                upToRun: run,
                options: TaskForkOptions(mode: .conversationWithFileCopies),
                in: context
            )
        }
    }

    @Test("workspace-less conversations reject independent copies instead of silently sharing")
    func workspaceLessForkRejectsIndependentCopies() throws {
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let source = AgentTask(title: "Standalone", goal: "Discuss an idea")
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)

        #expect(throws: AgentTaskForkError.fileCopiesRequireWorkspace) {
            try AgentTask.fork(
                from: source,
                upToRun: run,
                options: TaskForkOptions(mode: .conversationWithFileCopies),
                in: context
            )
        }
    }

    @Test("shared-files forks record references without content hashes")
    func sharedFilesForkSkipsContentHashing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let inputPath = (root as NSString).appendingPathComponent("report.md")
        try "checkpoint report".write(toFile: inputPath, atomically: true, encoding: .utf8)

        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Shared Files", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Revise the report", workspace: workspace)
        source.inputs = [inputPath]
        context.insert(workspace)
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)

        let forked = try AgentTask.fork(from: source, upToRun: run, in: context)
        try context.save()

        let manifest = try #require(TaskForkManifestService.load(for: forked))
        let reference = try #require(manifest.sourceInputs?.first { $0.sourcePath == inputPath })
        #expect(reference.localCopyPath == nil)
        #expect(reference.sha256 == nil)
    }

    @Test("file-copy forks rewrite tilde spellings, task text, and fork-local text, sharing one copy per source")
    func fileCopyForkRewritesAllSpellingsAndForkLocalText() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tildePath = "~/astra-fork-tilde-\(UUID().uuidString).md"
        let expandedPath = (tildePath as NSString).expandingTildeInPath
        defer { try? FileManager.default.removeItem(atPath: expandedPath) }
        try "tilde doc".write(toFile: expandedPath, atomically: true, encoding: .utf8)
        let planAttachmentPath = (root as NSString).appendingPathComponent("plan-notes.md")
        try "plan notes".write(toFile: planAttachmentPath, atomically: true, encoding: .utf8)

        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Rewrite Fidelity", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Edit \(tildePath) carefully", workspace: workspace)
        source.inputs = [tildePath]
        source.constraints = ["Keep \(expandedPath) intact"]
        source.acceptanceCriteria = ["\(expandedPath) reviewed"]
        source.teamInstructions = "Split work on \(expandedPath)"
        context.insert(workspace)
        context.insert(source)

        let sourceFolder = try TaskWorkspaceAccess(task: source).ensureTaskFolder()
        let turnOutputPath = ((sourceFolder as NSString).appendingPathComponent("outputs") as NSString)
            .appendingPathComponent("turn_001.md")
        try "Edited \(expandedPath), also spelled \(tildePath)".write(
            toFile: turnOutputPath, atomically: true, encoding: .utf8
        )
        try """
        # Session History

        ## Turn 1
        touched \(expandedPath) in the first turn
        """.write(
            toFile: SessionHistoryManager.historyPath(taskFolder: sourceFolder),
            atomically: true,
            encoding: .utf8
        )

        let run = TaskRun(task: source)
        run.status = .completed
        run.startedAt = Date(timeIntervalSince1970: 100)
        run.completedAt = Date(timeIntervalSince1970: 110)
        run.output = "Read \(expandedPath) then wrote \(expandedPath) again, or \(tildePath)"
        context.insert(run)
        let attachmentEvent = TaskEvent(
            task: source,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "Check this.\n\nAttached files:\n- \(expandedPath)",
            run: run
        )
        attachmentEvent.timestamp = Date(timeIntervalSince1970: 104)
        context.insert(attachmentEvent)
        let planAttachmentEvent = TaskEvent(
            task: source,
            type: TaskPlanConversationEventTypes.userMessage,
            payload: "Plan around this.\n\nAttached files:\n- \(planAttachmentPath)",
            run: run
        )
        planAttachmentEvent.timestamp = Date(timeIntervalSince1970: 105)
        context.insert(planAttachmentEvent)

        let forked = try AgentTask.fork(
            from: source,
            upToRun: run,
            options: TaskForkOptions(mode: .conversationWithFileCopies),
            in: context
        )
        try context.save()

        let manifest = try #require(TaskForkManifestService.load(for: forked))
        // Inputs record the user's raw spelling; attachments record the
        // absolute path parsed from the message text.
        let inputCopy = try #require(manifest.sourceInputs?.first { $0.sourcePath == tildePath }?.localCopyPath)
        let attachmentCopy = try #require(manifest.sourceAttachments?.first { $0.sourcePath == expandedPath }?.localCopyPath)
        // One local copy per distinct source file, shared across classes.
        #expect(inputCopy == attachmentCopy)
        #expect(forked.inputs == [inputCopy])

        // Plan-mode attachments are discovered and copied too.
        let planCopy = try #require(manifest.sourceAttachments?.first { $0.sourcePath == planAttachmentPath }?.localCopyPath)
        #expect(forked.events.contains { $0.payload.contains(planCopy) && !$0.payload.contains(planAttachmentPath) })

        // Task text is rewritten, including the original tilde spelling.
        #expect(forked.goal == "Edit \(inputCopy) carefully")
        #expect(forked.constraints == ["Keep \(inputCopy) intact"])
        #expect(forked.acceptanceCriteria == ["\(inputCopy) reviewed"])
        #expect(forked.teamInstructions == "Split work on \(inputCopy)")

        // Copied run output: both absolute occurrences and the tilde spelling.
        let forkedRun = try #require(forked.runs.first)
        #expect(forkedRun.output == "Read \(inputCopy) then wrote \(inputCopy) again, or \(inputCopy)")

        // Fork-local ASTRA-generated text is rewritten on disk.
        let outputCopy = try #require(manifest.sourceOutputFiles.first?.localCopyPath)
        let outputContents = try String(contentsOfFile: outputCopy, encoding: .utf8)
        #expect(outputContents.contains(inputCopy))
        #expect(!outputContents.contains(expandedPath))
        #expect(!outputContents.contains(tildePath))
        let historyPath = try #require(manifest.checkpointSessionHistoryPath)
        let historyContents = try String(contentsOfFile: historyPath, encoding: .utf8)
        #expect(historyContents.contains(inputCopy))
        #expect(!historyContents.contains(expandedPath))
    }

    @Test("manifest records declared inputs that are already missing so the warning can fire")
    func manifestRecordsMissingDeclaredInputs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let missingPath = (root as NSString).appendingPathComponent("missing.md")

        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Missing Input", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Revise", workspace: workspace)
        source.inputs = [missingPath]
        context.insert(workspace)
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)

        let forked = try AgentTask.fork(from: source, upToRun: run, in: context)
        try context.save()

        let manifest = try #require(TaskForkManifestService.load(for: forked))
        let reference = try #require(manifest.sourceInputs?.first { $0.sourcePath == missingPath })
        #expect(reference.localCopyPath == nil)
        #expect(TaskForkManifestService.sourceAvailabilityWarning(for: forked) != nil)
    }

    @Test("running sibling pinned to a subdirectory of the shared worktree blocks the fork")
    func subdirectoryPinnedSiblingBlocksGitFork() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let subdirectory = (root as NSString).appendingPathComponent("packages/api")
        try FileManager.default.createDirectory(atPath: subdirectory, withIntermediateDirectories: true)
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Repository", primaryPath: root)
        let source = AgentTask(title: "Original conversation", goal: "Continue", workspace: workspace)
        context.insert(workspace)
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)
        let forked = try AgentTask.fork(
            from: source,
            upToRun: run,
            options: TaskForkOptions(
                repository: TaskForkRepositorySnapshot(
                    rootPath: root,
                    branch: "main",
                    headSHA: "12345678",
                    isDirty: false
                )
            ),
            in: context
        )
        try context.save()

        let sibling = AgentTask(title: "Subdirectory task", goal: "Work", workspace: workspace)
        sibling.executionRootPath = subdirectory
        context.insert(sibling)
        #expect(TaskForkPolicyService.readOnlyReason(for: forked) == nil)
        sibling.status = .running
        let reason = try #require(TaskForkPolicyService.readOnlyReason(for: forked))
        #expect(reason.contains("Subdirectory task"))
    }

    @Test("independent copies snapshot symlinked file content instead of aliasing the original")
    func independentCopiesResolveSymlinkedInputs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let targetPath = (root as NSString).appendingPathComponent("target.md")
        let linkPath = (root as NSString).appendingPathComponent("linked.md")
        try "checkpoint content".write(toFile: targetPath, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)

        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Symlinked", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Revise", workspace: workspace)
        source.inputs = [linkPath]
        context.insert(workspace)
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)

        let forked = try AgentTask.fork(
            from: source,
            upToRun: run,
            options: TaskForkOptions(mode: .conversationWithFileCopies),
            in: context
        )
        try context.save()

        let copiedPath = try #require(forked.inputs.first)
        let copyAttributes = try FileManager.default.attributesOfItem(atPath: copiedPath)
        #expect(copyAttributes[.type] as? FileAttributeType == .typeRegular)
        try "changed after fork".write(toFile: targetPath, atomically: true, encoding: .utf8)
        #expect(try String(contentsOfFile: copiedPath, encoding: .utf8) == "checkpoint content")
    }

    @Test("historical checkpoints reject file copies whose earlier bytes cannot be reconstructed")
    func historicalCheckpointRejectsIndependentCopies() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Documents", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Revise", workspace: workspace)
        context.insert(workspace)
        context.insert(source)
        let checkpoint = TaskRun(task: source)
        checkpoint.status = .completed
        checkpoint.startedAt = Date(timeIntervalSince1970: 100)
        let later = TaskRun(task: source)
        later.status = .completed
        later.startedAt = Date(timeIntervalSince1970: 200)
        context.insert(checkpoint)
        context.insert(later)

        #expect(throws: AgentTaskForkError.historicalFileCopyUnavailable) {
            try AgentTask.fork(
                from: source,
                upToRun: checkpoint,
                options: TaskForkOptions(mode: .conversationWithFileCopies),
                in: context
            )
        }
        #expect(workspace.tasks.count == 1)
    }

    @Test("independent copies expand tilde input paths")
    func independentCopiesExpandTildeInputs() throws {
        let relativeName = "astra-fork-input-\(UUID().uuidString).md"
        let tildePath = "~/\(relativeName)"
        let expandedPath = (tildePath as NSString).expandingTildeInPath
        defer { try? FileManager.default.removeItem(atPath: expandedPath) }
        try "home input".write(toFile: expandedPath, atomically: true, encoding: .utf8)

        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Home", primaryPath: NSHomeDirectory())
        let source = AgentTask(title: "Source", goal: "Copy input", workspace: workspace)
        source.inputs = [tildePath]
        context.insert(workspace)
        context.insert(source)
        let run = TaskRun(task: source)
        run.status = .completed
        run.output = "Read \(tildePath)"
        context.insert(run)
        let event = TaskEvent(task: source, type: "user.message", payload: "Open \(tildePath)", run: run)
        context.insert(event)

        let forked = try AgentTask.fork(
            from: source,
            upToRun: run,
            options: TaskForkOptions(mode: .conversationWithFileCopies),
            in: context
        )
        let copiedPath = try #require(forked.inputs.first)
        #expect(copiedPath != tildePath)
        #expect(copiedPath != expandedPath)
        #expect(try String(contentsOfFile: copiedPath, encoding: .utf8) == "home input")
        #expect(forked.runs.first?.output.contains(copiedPath) == true)
        #expect(forked.events.contains { $0.payload.contains(copiedPath) })
        #expect(!forked.events.contains { $0.payload.contains(tildePath) })
    }

    @Test("tied run timestamps replay the selected checkpoint deterministically")
    func tiedRunTimestampsReplaySelectedCheckpoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Ordering", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Compare", workspace: workspace)
        context.insert(workspace)
        context.insert(source)
        let first = TaskRun(task: source)
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        first.startedAt = Date(timeIntervalSince1970: 100)
        first.status = .completed
        first.output = "FIRST-TIED-RUN"
        let checkpoint = TaskRun(task: source)
        checkpoint.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        checkpoint.startedAt = first.startedAt
        checkpoint.status = .completed
        checkpoint.output = "SELECTED-TIED-CHECKPOINT"
        context.insert(first)
        context.insert(checkpoint)

        let forked = try AgentTask.fork(from: source, upToRun: checkpoint, in: context)
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: forked)

        #expect(prompt.contains("SELECTED-TIED-CHECKPOINT"))
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-fork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
