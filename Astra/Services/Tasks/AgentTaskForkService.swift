import Foundation
import SwiftData
import ASTRACore

enum AgentTaskForkService {
    private struct ForkManifestEventPayload: Encodable {
        var sourceTaskID: String
        var checkpointRunID: String
        var checkpointRunIndex: Int
        var manifestPath: String
    }

    @MainActor
    static func fork(from source: AgentTask, upToRun targetRun: TaskRun, in context: ModelContext) -> AgentTask {
        let forked = AgentTask(
            title: "Fork of \(source.title)",
            goal: source.goal,
            workspace: source.workspace,
            tokenBudget: source.tokenBudget,
            model: source.model,
            runtime: source.resolvedRuntimeID,
            isolationStrategy: source.isolationStrategy,
            validationStrategy: source.validationStrategy
        )
        forked.inputs = source.inputs
        forked.constraints = source.constraints
        forked.acceptanceCriteria = source.acceptanceCriteria
        forked.forkedFromID = source.id
        forked.skills = source.skills
        forked.skillSnapshotsJSON = source.skillSnapshotsJSON
        forked.runtimeID = source.runtimeID
        // A fork continues the source's line of work, so it stays in the same
        // worktree the source was pinned to.
        forked.executionRootPath = source.executionRootPath
        forked.executionEnvironmentSnapshotJSON = source.executionEnvironmentSnapshotJSON

        let sortedRuns = source.runs.sorted { $0.startedAt < $1.startedAt }
        guard let cutoffIndex = sortedRuns.firstIndex(where: { $0.id == targetRun.id }) else {
            context.insert(forked)
            return forked
        }

        forked.forkedAtRunIndex = cutoffIndex
        let stateInit = TaskForkStateInitializingSeam.required.initializeForkAsCompleted(
            taskID: forked.id,
            statusRawValue: forked.status.rawValue,
            at: Date()
        )
        // Apply atomically: status and updatedAt must both be valid, or
        // neither is applied, so a future adapter bug can't leave forked in
        // a partially-transitioned state (new status, stale updatedAt or
        // vice versa).
        if stateInit.applied,
           let newStatus = TaskStatus(rawValue: stateInit.statusRawValue),
           let updatedAt = stateInit.updatedAt {
            forked.status = newStatus
            forked.updatedAt = updatedAt
        }

        let runsToFork = sortedRuns.prefix(through: cutoffIndex)
        var forkedRunsBySourceID: [UUID: TaskRun] = [:]
        var copiedRunIDs: [UUID] = []
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
            newRun.output = sourceRun.output
            newRun.costUSD = sourceRun.costUSD
            newRun.fileChangesJSON = sourceRun.fileChangesJSON
            newRun.executionEnvironmentSnapshotJSON = sourceRun.executionEnvironmentSnapshotJSON
            newRun.stopReason = sourceRun.stopReason
            newRun.exitCode = sourceRun.exitCode
            context.insert(newRun)
            forkedRunsBySourceID[sourceRun.id] = newRun
            copiedRunIDs.append(sourceRun.id)
            totalTokens += sourceRun.tokensUsed
            totalCost += sourceRun.costUSD
        }

        forked.tokensUsed = totalTokens
        forked.costUSD = totalCost

        let cutoffDate = targetRun.completedAt ?? targetRun.startedAt
        let eventsToFork = source.events
            .filter { $0.timestamp <= cutoffDate }
            .sorted { $0.timestamp < $1.timestamp }

        for sourceEvent in eventsToFork {
            let copiedRun = sourceEvent.run.flatMap { forkedRunsBySourceID[$0.id] }
            let newEvent = TaskEvent(
                task: forked,
                type: sourceEvent.type,
                payload: sourceEvent.payload,
                run: copiedRun
            )
            newEvent.timestamp = sourceEvent.timestamp
            newEvent.agentName = sourceEvent.agentName
            newEvent.agentId = sourceEvent.agentId
            newEvent.teamName = sourceEvent.teamName
            context.insert(newEvent)
        }

        let checkpointEvent = TaskEvent(
            task: forked,
            eventType: TaskEventTypes.Task.checkpoint,
            payload: "Forked checkpoint from task \(source.id.uuidString) after source run \(cutoffIndex + 1). Later source runs are not authoritative for this branch.",
            run: forkedRunsBySourceID[targetRun.id]
        )
        context.insert(checkpointEvent)

        context.insert(forked)
        do {
            let forkedWorkspacePath = forked.workspace?.primaryPath ?? ""
            let request = TaskForkManifestRequest(
                sourceTaskID: source.id,
                sourceWorkspacePath: source.workspace?.primaryPath ?? "",
                sourceArtifacts: source.artifacts.map { TaskForkArtifactFacts(createdAt: $0.createdAt, path: $0.path) },
                forkedTaskID: forked.id,
                forkedWorkspacePath: forkedWorkspacePath,
                checkpointRunID: targetRun.id,
                checkpointRunStartedAt: targetRun.startedAt,
                checkpointRunCompletedAt: targetRun.completedAt,
                checkpointRunIndex: cutoffIndex,
                copiedRunIDs: copiedRunIDs
            )
            let manifest = try TaskForkManifestWritingSeam.required.writeManifest(request)
            let manifestPath = TaskForkManifestWritingSeam.required.manifestPath(
                taskFolder: TaskFolderResolvingSeam.required.taskFolder(
                    workspacePath: forkedWorkspacePath,
                    taskID: forked.id
                )
            )
            let payload = ForkManifestEventPayload(
                sourceTaskID: manifest.sourceTaskID.uuidString,
                checkpointRunID: manifest.checkpointRunID.uuidString,
                checkpointRunIndex: manifest.checkpointRunIndex,
                manifestPath: manifestPath
            )
            let eventPayload = (try? String(
                data: JSONEncoder().encode(payload),
                encoding: .utf8
            )) ?? ""
            context.insert(TaskEvent(
                task: forked,
                type: "task.fork_manifest.created",
                payload: eventPayload,
                run: forkedRunsBySourceID[targetRun.id]
            ))
        } catch {
            AuditLoggingSeam.required.audit(.taskFailed, category: "Persistence", taskID: forked.id, fields: [
                "reason": "fork_manifest_write_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
        return forked
    }
}
