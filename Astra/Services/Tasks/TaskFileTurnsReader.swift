import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Reads a task's whole history into `TaskFileTurnsInput`: every run, not the
/// thread's window of recent ones, because turn numbers count the whole task.
enum TaskFileTurnsReader {
    /// A run as the main context holds it, unsaved: a streaming run records
    /// tool changes there and saves only when it finalizes.
    struct PendingRun: Sendable {
        let id: UUID
        let startedAt: Date
        let completedAt: Date?
        let isRunning: Bool
        let fileChangesJSON: String

        @MainActor
        init(_ run: TaskRun) {
            id = run.id
            startedAt = run.startedAt
            completedAt = run.completedAt
            isRunning = run.status == .running
            fileChangesJSON = run.fileChangesJSON
        }
    }

    static func input(
        taskID: UUID,
        taskFolder: String,
        workspacePath: String,
        executionPath: String? = nil,
        additionalRoots: [String] = [],
        pendingRuns: [PendingRun] = [],
        modelContext: ModelContext
    ) throws -> TaskFileTurnsInput? {
        var taskDescriptor = FetchDescriptor<AgentTask>(predicate: #Predicate<AgentTask> { $0.id == taskID })
        taskDescriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(taskDescriptor).first else { return nil }

        let runs = try modelContext.fetch(FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.task?.id == taskID }
        ))
        let userMessage = TaskEventTypes.Conversation.userMessage.rawValue
        let planUserMessage = TaskPlanConversationEventTypes.userMessage
        let messages = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && ($0.type == userMessage || $0.type == planUserMessage)
            }
        ))
        var artifactDescriptor = FetchDescriptor<Artifact>(
            predicate: #Predicate<Artifact> { $0.task?.id == taskID }
        )
        // A tool write stores the file's whole content on its row; only the
        // path and time are needed, and one task has over 13,000 rows.
        artifactDescriptor.propertiesToFetch = [\.path, \.createdAt]
        var artifacts = try modelContext.fetch(artifactDescriptor)

        // A fork copies its source's runs but not their artifact rows or,
        // unless asked to, their files: each source's rows up to the fork
        // stand in for its older runs, and its files open where they are.
        var inheritedTaskFolders: [String] = []
        var forkCopies: [[String: String]] = []
        var visited: Set<UUID> = [taskID]
        var fork = (folder: taskFolder, createdAt: task.createdAt)
        var ancestorID = task.forkedFromID
        while let id = ancestorID, visited.insert(id).inserted {
            forkCopies.append(copiedFiles(inForkFolder: fork.folder))
            let ancestorFolder = WorkspaceFileLayout.readableTaskFolder(workspacePath: workspacePath, taskID: id)
            inheritedTaskFolders.append(ancestorFolder)
            let forkedAt = fork.createdAt
            var ancestorArtifacts = FetchDescriptor<Artifact>(
                predicate: #Predicate<Artifact> { $0.task?.id == id && $0.createdAt <= forkedAt }
            )
            ancestorArtifacts.propertiesToFetch = [\.path, \.createdAt]
            artifacts += try modelContext.fetch(ancestorArtifacts)
            var ancestorDescriptor = FetchDescriptor<AgentTask>(predicate: #Predicate<AgentTask> { $0.id == id })
            ancestorDescriptor.fetchLimit = 1
            let ancestor = try modelContext.fetch(ancestorDescriptor).first
            fork = (ancestorFolder, ancestor?.createdAt ?? .distantPast)
            ancestorID = ancestor?.forkedFromID
        }

        return TaskFileTurnsInput(
            goal: task.goal,
            createdAt: task.createdAt,
            requests: messages.map {
                TaskFileTurnsInput.Request(
                    text: $0.payload,
                    requestedAt: $0.timestamp,
                    runID: $0.run?.id,
                    isPlanMessage: $0.type == planUserMessage
                )
            },
            runs: overlaying(pendingRuns, on: runs.map { run in
                TaskFileTurnsInput.Run(
                    id: run.id,
                    startedAt: run.startedAt,
                    completedAt: run.completedAt,
                    isRunning: run.status == .running,
                    changes: run.allFileChanges.map {
                        TaskFileTurnsInput.Change(path: $0.path, kind: $0.kind, timestamp: $0.timestamp)
                    }
                )
            }),
            indexedFiles: artifacts.map { TaskFileTurnsInput.IndexedFile(path: $0.path, indexedAt: $0.createdAt) },
            taskFolder: taskFolder,
            workspacePath: workspacePath,
            executionPath: executionPath,
            inheritedTaskFolders: inheritedTaskFolders,
            forkCopies: forkCopies.reversed(),
            additionalRoots: additionalRoots
        )
    }

    /// The files a fork copied from its source, source path to copy, spelled
    /// as the ledger spells a run's paths.
    private static func copiedFiles(inForkFolder folder: String) -> [String: String] {
        guard let manifest = TaskForkManifestService.load(taskFolder: folder) else { return [:] }
        func normalized(_ path: String) -> String {
            TaskArtifactPathNormalizer.normalizedPath(
                (path as NSString).expandingTildeInPath,
                workspacePath: "",
                taskFolder: ""
            )
        }
        var copies: [String: String] = [:]
        for reference in manifest.allFileReferences {
            guard let copy = reference.localCopyPath, !copy.isEmpty else { continue }
            copies[normalized(reference.sourcePath)] = normalized(copy)
        }
        return copies
    }

    /// The store's runs, with each unsaved run in place of its stored copy.
    private static func overlaying(_ pending: [PendingRun], on stored: [TaskFileTurnsInput.Run]) -> [TaskFileTurnsInput.Run] {
        guard !pending.isEmpty else { return stored }
        let replacements = Dictionary(pending.map { run in
            (run.id, TaskFileTurnsInput.Run(
                id: run.id,
                startedAt: run.startedAt,
                completedAt: run.completedAt,
                isRunning: run.isRunning,
                changes: ((try? TaskRun.decodedFileChanges(from: run.fileChangesJSON).get()) ?? []).map {
                    TaskFileTurnsInput.Change(path: $0.path, kind: $0.kind, timestamp: $0.timestamp)
                }
            ))
        }, uniquingKeysWith: { _, latest in latest })
        let storedIDs = Set(stored.map(\.id))
        return stored.map { replacements[$0.id] ?? $0 }
            + replacements.values.filter { !storedIDs.contains($0.id) }
    }
}
