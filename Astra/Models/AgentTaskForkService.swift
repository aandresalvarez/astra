import Foundation
import SwiftData
import ASTRACore

public enum TaskForkMode: String, Codable, CaseIterable, Sendable, Equatable {
    case conversationSharedFiles = "conversation_shared_files"
    case conversationWithFileCopies = "conversation_with_file_copies"
}

public struct TaskForkRepositorySnapshot: Codable, Sendable, Equatable {
    public let rootPath: String
    public let branch: String
    public let headSHA: String
    public let isDirty: Bool

    public init(rootPath: String, branch: String, headSHA: String, isDirty: Bool) {
        self.rootPath = rootPath
        self.branch = branch
        self.headSHA = headSHA
        self.isDirty = isDirty
    }
}

public struct TaskForkOptions: Sendable, Equatable {
    public let mode: TaskForkMode
    public let repository: TaskForkRepositorySnapshot?

    public init(
        mode: TaskForkMode = .conversationSharedFiles,
        repository: TaskForkRepositorySnapshot? = nil
    ) {
        self.mode = mode
        self.repository = repository
    }
}

public enum AgentTaskForkError: LocalizedError, Equatable {
    case targetRunMissing
    case targetRunStillRunning
    case repositoryFileCopyDenied
    case historicalFileCopyUnavailable
    case fileCopiesRequireWorkspace
    case manifestWriteFailed

    public var errorDescription: String? {
        switch self {
        case .targetRunMissing:
            "The selected checkpoint no longer belongs to this conversation. Refresh and try again."
        case .targetRunStillRunning:
            "Wait for this step to finish before forking the conversation."
        case .repositoryFileCopyDenied:
            "Git repository files cannot be copied by conversation forking. Use the Git workspace controls for code isolation."
        case .historicalFileCopyUnavailable:
            "Independent file copies are only available from the latest checkpoint because ASTRA cannot reconstruct earlier versions of files that were later changed. Use shared files or fork from the latest step."
        case .fileCopiesRequireWorkspace:
            "Independent file copies need a workspace folder to copy into. Use shared files for this conversation."
        case .manifestWriteFailed:
            "ASTRA could not prepare the conversation checkpoint. No fork was created."
        }
    }
}

public enum AgentTaskForkService {
    private struct ForkManifestEventPayload: Encodable {
        public var sourceTaskID: String
        public var checkpointRunID: String
        public var checkpointRunIndex: Int
        public var manifestPath: String
        public var forkMode: String
    }

    @MainActor
    public static func fork(
        from source: AgentTask,
        upToRun targetRun: TaskRun,
        options: TaskForkOptions = TaskForkOptions(),
        in context: ModelContext
    ) throws -> AgentTask {
        if options.repository != nil, options.mode == .conversationWithFileCopies {
            throw AgentTaskForkError.repositoryFileCopyDenied
        }
        // Without a workspace folder there is nowhere to copy into: the
        // manifest-writing branch below is skipped and `sourceToLocalPaths`
        // stays empty, so file-copy mode would silently degrade to shared
        // references. Fail instead of pretending to isolate.
        if options.mode == .conversationWithFileCopies,
           (source.workspace?.primaryPath ?? "").isEmpty {
            throw AgentTaskForkError.fileCopiesRequireWorkspace
        }

        let sortedRuns = source.runs.sorted(by: runOrdering)
        guard let cutoffIndex = sortedRuns.firstIndex(where: { $0.id == targetRun.id }) else {
            throw AgentTaskForkError.targetRunMissing
        }
        guard targetRun.status != .running else {
            throw AgentTaskForkError.targetRunStillRunning
        }
        if options.mode == .conversationWithFileCopies, cutoffIndex != sortedRuns.indices.last {
            throw AgentTaskForkError.historicalFileCopyUnavailable
        }

        let forked = AgentTask(
            title: "Fork of \(source.title)",
            goal: source.goal,
            workspace: source.workspace,
            tokenBudget: source.tokenBudget,
            model: source.model,
            runtime: source.resolvedRuntimeID,
            isolationStrategy: options.repository == nil ? source.isolationStrategy : .sameDirectory,
            validationStrategy: source.validationStrategy
        )
        forked.inputs = source.inputs
        forked.constraints = source.constraints
        forked.acceptanceCriteria = source.acceptanceCriteria
        forked.forkedFromID = source.id
        forked.skills = source.skills
        forked.skillSnapshotsJSON = source.skillSnapshotsJSON
        forked.runtimeID = source.runtimeID
        forked.runtimeExplicitlySelected = source.runtimeExplicitlySelected
        forked.testCommand = source.testCommand
        forked.maxTurns = source.maxTurns
        forked.useAgentTeam = source.useAgentTeam
        forked.teamSize = source.teamSize
        forked.teamInstructions = source.teamInstructions
        forked.templateID = source.templateID
        forked.templateHooksJSON = source.templateHooksJSON
        // Provider sessions and permission grants intentionally reset with the
        // newly constructed task. A conversation fork must never share an
        // operational provider session or task-scoped authorization.
        // A fork continues the source's line of work, so it stays in the same
        // worktree the source was pinned to.
        forked.executionRootPath = source.executionRootPath
        forked.executionEnvironmentSnapshotJSON = source.executionEnvironmentSnapshotJSON
        forked.forkedAtRunIndex = cutoffIndex

        let stateInit = TaskForkStateInitializingSeam.required.initializeForkAsCompleted(
            taskID: forked.id,
            statusRawValue: forked.status.rawValue,
            at: Date()
        )
        if stateInit.applied,
           let newStatus = TaskStatus(rawValue: stateInit.statusRawValue),
           let updatedAt = stateInit.updatedAt {
            forked.status = newStatus
            forked.updatedAt = updatedAt
        }

        let runsToFork = Array(sortedRuns.prefix(through: cutoffIndex))
        var forkedRunsBySourceID: [UUID: TaskRun] = [:]
        var copiedRuns: [TaskRun] = []
        var totalTokens = 0
        var totalCost = 0.0

        for sourceRun in runsToFork {
            let newRun = TaskRun(task: forked)
            newRun.status = sourceRun.status
            newRun.startedAt = sourceRun.startedAt
            newRun.completedAt = sourceRun.completedAt
            newRun.tokensUsed = sourceRun.tokensUsed
            newRun.inputTokens = sourceRun.inputTokens
            newRun.outputTokens = sourceRun.outputTokens
            newRun.runtimeID = sourceRun.runtimeID
            newRun.providerVersion = sourceRun.providerVersion
            newRun.providerLaunchSignatureJSON = sourceRun.providerLaunchSignatureJSON
            newRun.output = sourceRun.output
            newRun.costUSD = sourceRun.costUSD
            newRun.fileChangesJSON = sourceRun.fileChangesJSON
            newRun.executionEnvironmentSnapshotJSON = sourceRun.executionEnvironmentSnapshotJSON
            newRun.stopReason = sourceRun.stopReason
            newRun.exitCode = sourceRun.exitCode
            forkedRunsBySourceID[sourceRun.id] = newRun
            copiedRuns.append(newRun)
            totalTokens += sourceRun.tokensUsed
            totalCost += sourceRun.costUSD
        }
        forked.tokensUsed = totalTokens
        forked.costUSD = totalCost

        let copiedRunIDs = runsToFork.map(\.id)
        let copiedRunIDSet = Set(copiedRunIDs)
        let cutoffDate = targetRun.completedAt ?? targetRun.startedAt
        let eventsToFork = source.events
            .filter { event in
                if let runID = event.run?.id {
                    return copiedRunIDSet.contains(runID)
                }
                return event.timestamp <= cutoffDate
            }
            .sorted(by: eventOrdering)
        let attachments = attachmentPaths(in: eventsToFork.filter {
            $0.type == TaskEventTypes.Conversation.userMessage.rawValue
        })
        let forkedWorkspacePath = forked.workspace?.primaryPath ?? ""
        let forkFolder = TaskFolderResolvingSeam.required.taskFolder(
            workspacePath: forkedWorkspacePath,
            taskID: forked.id
        )

        let manifest: TaskForkManifestSummary
        if forkedWorkspacePath.isEmpty {
            manifest = TaskForkManifestSummary(
                sourceTaskID: source.id,
                checkpointRunID: targetRun.id,
                checkpointRunIndex: cutoffIndex
            )
        } else {
            do {
                manifest = try TaskForkManifestWritingSeam.required.writeManifest(TaskForkManifestRequest(
                sourceTaskID: source.id,
                sourceWorkspacePath: source.workspace?.primaryPath ?? "",
                sourceArtifacts: source.artifacts.map { TaskForkArtifactFacts(createdAt: $0.createdAt, path: $0.path) },
                sourceInputs: source.inputs.map(normalizedInputPath),
                sourceAttachments: attachments,
                forkedTaskID: forked.id,
                forkedWorkspacePath: forkedWorkspacePath,
                checkpointRunID: targetRun.id,
                checkpointRunStartedAt: targetRun.startedAt,
                checkpointRunCompletedAt: targetRun.completedAt,
                checkpointRunIndex: cutoffIndex,
                copiedRunIDs: copiedRunIDs,
                forkModeRawValue: options.mode.rawValue,
                repository: options.repository.map {
                    TaskForkRepositoryFacts(
                        rootPath: $0.rootPath,
                        branch: $0.branch,
                        headSHA: $0.headSHA,
                        isDirty: $0.isDirty
                    )
                }
                ))
            } catch {
                TaskForkManifestWritingSeam.required.removePreparedFork(taskFolder: forkFolder)
                AuditLoggingSeam.required.audit(.taskFailed, category: "Persistence", taskID: forked.id, fields: [
                    "reason": "fork_manifest_write_failed",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
                throw AgentTaskForkError.manifestWriteFailed
            }
        }

        if options.mode == .conversationWithFileCopies {
            forked.inputs = source.inputs.map {
                let normalized = normalizedInputPath($0)
                return manifest.sourceToLocalPaths[normalized] ?? normalized
            }
            for run in copiedRuns {
                run.output = replacingPaths(in: run.output, using: manifest.sourceToLocalPaths)
                rewriteFileChanges(in: run, using: manifest.sourceToLocalPaths)
            }
        }

        var copiedEvents: [TaskEvent] = eventsToFork.map { sourceEvent in
            let copiedRun = sourceEvent.run.flatMap { forkedRunsBySourceID[$0.id] }
            let rewrittenPayload = replacingPaths(in: sourceEvent.payload, using: manifest.sourceToLocalPaths)
            let newEvent = TaskEvent(
                task: forked,
                type: sourceEvent.type,
                payload: rewrittenPayload,
                run: copiedRun
            )
            newEvent.timestamp = sourceEvent.timestamp
            newEvent.agentName = sourceEvent.agentName
            newEvent.agentId = sourceEvent.agentId
            newEvent.teamName = sourceEvent.teamName
            return newEvent
        }

        copiedEvents.append(TaskEvent(
            task: forked,
            eventType: TaskEventTypes.Task.checkpoint,
            payload: "Forked conversation from task \(source.id.uuidString) after source run \(cutoffIndex + 1). Later source runs are not authoritative for this conversation.",
            run: forkedRunsBySourceID[targetRun.id]
        ))

        if !forkFolder.isEmpty {
            let manifestPath = TaskForkManifestWritingSeam.required.manifestPath(taskFolder: forkFolder)
            let payload = ForkManifestEventPayload(
                sourceTaskID: manifest.sourceTaskID.uuidString,
                checkpointRunID: manifest.checkpointRunID.uuidString,
                checkpointRunIndex: manifest.checkpointRunIndex,
                manifestPath: manifestPath,
                forkMode: options.mode.rawValue
            )
            let eventPayload = (try? String(
                data: JSONEncoder().encode(payload),
                encoding: .utf8
            )) ?? ""
            copiedEvents.append(TaskEvent(
                task: forked,
                type: "task.fork_manifest.created",
                payload: eventPayload,
                run: forkedRunsBySourceID[targetRun.id]
            ))
        }

        context.insert(forked)
        copiedRuns.forEach(context.insert)
        copiedEvents.forEach(context.insert)
        return forked
    }

    private static func runOrdering(_ lhs: TaskRun, _ rhs: TaskRun) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func eventOrdering(_ lhs: TaskEvent, _ rhs: TaskEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func attachmentPaths(in events: [TaskEvent]) -> [String] {
        var seen: Set<String> = []
        return events.flatMap { event -> [String] in
            guard let markerRange = event.payload.range(of: "Attached files:\n") else { return [] }
            return event.payload[markerRange.upperBound...]
                .split(separator: "\n")
                .compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("- ") else { return nil }
                    let path = String(trimmed.dropFirst(2))
                    guard !path.isEmpty, seen.insert(path).inserted else { return nil }
                    return path
                }
        }
    }

    private static func replacingPaths(in payload: String, using mapping: [String: String]) -> String {
        mapping.keys.sorted { $0.count > $1.count }.reduce(payload) { value, sourcePath in
            guard let replacement = mapping[sourcePath], !sourcePath.isEmpty else { return value }
            var result = value
            var searchStart = result.startIndex
            while let range = result.range(of: sourcePath, range: searchStart..<result.endIndex) {
                let beforeIsBoundary = range.lowerBound == result.startIndex
                    || !isPathTokenCharacter(result[result.index(before: range.lowerBound)])
                let afterIsBoundary = range.upperBound == result.endIndex
                    || !isPathTokenCharacter(result[range.upperBound])
                if beforeIsBoundary && afterIsBoundary {
                    result.replaceSubrange(range, with: replacement)
                    searchStart = result.index(range.lowerBound, offsetBy: replacement.count)
                } else {
                    searchStart = range.upperBound
                }
            }
            return result
        }
    }

    private static func isPathTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "._-/~".contains(character)
    }

    private static func normalizedInputPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func rewriteFileChanges(in run: TaskRun, using mapping: [String: String]) {
        guard case .success(let changes) = run.fileChangesDecodeResult else { return }
        let rewritten = changes.map { change in
            StoredFileChange(
                id: change.id,
                path: mapping[change.path] ?? change.path,
                changeType: change.changeType,
                content: change.content,
                oldString: change.oldString,
                newString: change.newString,
                timestamp: change.timestamp
            )
        }
        run.fileChangesJSON = TaskEvent.payloadString(rewritten, fallback: run.fileChangesJSON)
    }
}
